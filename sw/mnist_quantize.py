#!/usr/bin/env python3
"""
mnist_quantize.py — Train, quantize, and export MNIST MLP for CIM SoC.

This script does everything needed to go from "raw MNIST data" to
"files ready to load onto FPGA":

  1. Train a 784→128→10 MLP on MNIST (or load pretrained)
  2. Post-Training Quantize (PTQ) to INT8 matching CIM hardware:
     - Weights: signed INT8 (symmetric, zp=0)
     - Activations: unsigned UINT8 (asymmetric, zp configurable)
     - Bias: INT32 (folded with activation scale)
     - Requantize: multiply-shift (same as cim_pkg::requantize)
  3. Run bit-accurate INT8 inference in Python, verify accuracy
  4. Export hex files in the EXACT format the FPGA expects
  5. Optionally export multiple test images for batch testing

Usage:
  python mnist_quantize.py                      # Train + quantize + export
  python mnist_quantize.py --pretrained model.pt # Load existing model
  python mnist_quantize.py --num-test 100        # Export 100 test images
  python mnist_quantize.py --output-dir mnist_real_data

  # NEW: only (re)export the raw INT8 matrices needed by the SW baseline,
  # from an existing checkpoint, WITHOUT retraining or touching the hex files:
  python mnist_quantize.py --export-npz-only --pretrained mnist_mlp.pt \
                           --output-dir mnist_real_data

Output files (per test image):
  mnist_real_data/
    model_info.txt          — model summary + accuracy
    fc1_weight_tiles.hex    — FC1 weights (shared across all images)
    fc2_weight_tiles.hex    — FC2 weights
    fc1_bias.hex            — FC1 bias INT32
    fc2_bias.hex            — FC2 bias INT32
    quant_params.hex        — fc1_mult, fc1_shift, fc2_mult, fc2_shift
    zero_points.hex         — fc1 input zp, fc2 input zp (both 0 for this model)
    mlp_qparams.npz         — raw INT8 weight matrices (for SW baseline GEMV)
    test_images/
      img_0000.hex          — test image UINT8
      img_0000_label.txt    — true label
      img_0000_pred.txt     — python INT8 prediction
      ...
"""

import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms
import numpy as np
import argparse
import os
import sys


def _apply_seed(seed):
    """If seed is not None, fix numpy+torch RNG for reproducibility; otherwise fully random."""
    if seed is not None:
        np.random.seed(seed)
        torch.manual_seed(seed)


# ============================================================================
# Hardware parameters (must match cim_pkg.sv)
# ============================================================================
TILE_ROWS = 16
TILE_COLS = 16
WEIGHT_W = 8
ELEMS_PER_CHUNK = 32 // WEIGHT_W  # 4
CHUNKS_PER_TILE = (TILE_ROWS * TILE_COLS) // ELEMS_PER_CHUNK  # 64


# ============================================================================
# 1. Model Definition
# ============================================================================
class MnistMLP(nn.Module):
    """Simple 784→128→10 MLP matching CIM hardware topology."""

    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(784, 128)
        self.relu = nn.ReLU()
        self.fc2 = nn.Linear(128, 10)

    def forward(self, x):
        x = x.view(-1, 784)
        x = self.relu(self.fc1(x))
        x = self.fc2(x)
        return x


# ============================================================================
# 2. Training
# ============================================================================
def train_model(epochs=10, lr=0.001, device="cpu", seed=None):
    """Train MNIST MLP from scratch."""
    _apply_seed(seed)

    print("=" * 60)
    print("Training MNIST MLP (784→128→10)")
    print(f"Seed: {seed if seed is not None else 'None (fully random)'}")
    print("=" * 60)

    # NO Normalize — train on raw [0,1] pixels so weights match hardware input domain
    transform = transforms.Compose([transforms.ToTensor()])
    train_set = datasets.MNIST("./data", train=True, download=True, transform=transform)
    test_set = datasets.MNIST("./data", train=False, download=True, transform=transform)
    train_loader = torch.utils.data.DataLoader(train_set, batch_size=128, shuffle=True)
    test_loader = torch.utils.data.DataLoader(test_set, batch_size=1000)

    model = MnistMLP().to(device)
    optimizer = optim.Adam(model.parameters(), lr=lr)
    criterion = nn.CrossEntropyLoss()

    for epoch in range(epochs):
        model.train()
        total_loss = 0
        for data, target in train_loader:
            data, target = data.to(device), target.to(device)
            optimizer.zero_grad()
            output = model(data)
            loss = criterion(output, target)
            loss.backward()
            optimizer.step()
            total_loss += loss.item()

        # Test accuracy
        model.eval()
        correct = 0
        total = 0
        with torch.no_grad():
            for data, target in test_loader:
                data, target = data.to(device), target.to(device)
                output = model(data)
                pred = output.argmax(dim=1)
                correct += pred.eq(target).sum().item()
                total += target.size(0)

        acc = 100.0 * correct / total
        print(
            f"  Epoch {epoch + 1}/{epochs}: loss={total_loss / len(train_loader):.4f}, acc={acc:.2f}%"
        )

    print(f"\nFinal float32 accuracy: {acc:.2f}%")
    return model, test_set, acc


# ============================================================================
# 3. Post-Training Quantization (PTQ)
# ============================================================================
def compute_scale_zp_symmetric(tensor, num_bits=8):
    """
    Symmetric quantization: zp=0, scale = max(|tensor|) / 127
    Used for weights.
    """
    max_val = tensor.abs().max().item()
    if max_val == 0:
        return 1.0, 0
    scale = max_val / 127.0
    return scale, 0


def compute_scale_zp_asymmetric(min_val, max_val, num_bits=8):
    """
    Asymmetric quantization for activations.
    Maps [min_val, max_val] → [0, 255] for UINT8.
    """
    qmin, qmax = 0, 255
    scale = (max_val - min_val) / (qmax - qmin)
    if scale == 0:
        scale = 1e-8
    zp = qmin - round(min_val / scale)
    zp = max(qmin, min(qmax, zp))
    return scale, int(zp)


def quantize_weight_symmetric(weight_float, scale):
    """Quantize float weight → INT8 (symmetric, zp=0)."""
    w_q = torch.clamp(torch.round(weight_float / scale), -128, 127)
    return w_q.to(torch.int8)


def compute_requant_params(s_input, s_weight, s_output, shift=16):
    """
    Compute (mult, shift) for requantization.
    M = (s_input * s_weight) / s_output
    Fixed-point: mult = round(M * 2^shift)
    """
    M = (s_input * s_weight) / s_output
    mult = max(1, int(round(M * (1 << shift))))
    return mult, shift


def quantize_bias(bias_float, s_input, s_weight):
    """
    Quantize bias to INT32.
    bias_q = round(bias_float / (s_input * s_weight))
    """
    scale = s_input * s_weight
    bias_q = torch.clamp(torch.round(bias_float / scale), -(2**31), 2**31 - 1)
    return bias_q.to(torch.int32)


def calibrate_fc1_output(model, device="cpu"):
    """
    Run RAW [0,1] images through float model to find FC1 output (after ReLU) range.
    Model is trained on raw [0,1] pixels (no Normalize), so we calibrate with same.
    """
    transform_raw = transforms.ToTensor()
    cal_set = datasets.MNIST(
        "./data", train=True, download=True, transform=transform_raw
    )
    cal_loader = torch.utils.data.DataLoader(cal_set, batch_size=1000, shuffle=False)

    model.eval()
    fc1_out_min, fc1_out_max = float("inf"), float("-inf")
    fc2_out_min, fc2_out_max = float("inf"), float("-inf")

    with torch.no_grad():
        for data, _ in cal_loader:
            data = data.to(device).view(-1, 784)
            fc1_out = model.relu(model.fc1(data))
            fc1_out_min = min(fc1_out_min, fc1_out.min().item())
            fc1_out_max = max(fc1_out_max, fc1_out.max().item())

            logits = model.fc2(fc1_out)
            fc2_out_min = min(fc2_out_min, logits.min().item())
            fc2_out_max = max(fc2_out_max, logits.max().item())

    return {
        "fc1_output": (fc1_out_min, fc1_out_max),
        "fc2_output": (fc2_out_min, fc2_out_max),
    }


def full_ptq(model, calibration_loader, device="cpu"):
    """
    Full post-training quantization pipeline.

    Key design decisions (matching mini_test.ipynb / CIM hardware):
      - Input: FIXED quantization. Raw pixel [0,255] as UINT8.
        scale_in = 1/255, hw_zp = 0 (x_eff = x_u8 directly)
      - Weights: symmetric INT8, zp=0
      - Bias: INT32, scale = scale_in * scale_w
      - FC1 output: symmetric INT8 (after ReLU, all non-negative)
      - FC2 output: symmetric INT8
    """
    print("\n" + "=" * 60)
    print("Post-Training Quantization")
    print("=" * 60)

    # ---- Step 1: Fixed input quantization ----
    # MNIST pixels are [0, 255] UINT8. Hardware stores as UINT8.
    # Model is trained on raw [0,1] pixels (ToTensor only, no Normalize).
    # Quantization: x_u8 = round(pixel * 255), scale = 1/255, zp = 0.
    # hw_infer_layer does: x_eff = x_u8 - hw_zp = x_u8 - 0 = x_u8
    # So x_eff in [0, 255], and dequant: pixel ≈ x_u8 * (1/255).
    # acc = w_q @ x_u8 + b_q ≈ (w_float @ pixel) / (s_in * s_w)
    s_in1 = 1.0 / 255.0
    hw_zp1 = 0  # x_eff = x_u8 - 0 = x_u8, range [0, 255] matching float [0,1]

    print(f"  FC1 input: FIXED scale=1/255={s_in1:.6f}, hw_zp={hw_zp1}")

    # ---- Step 2: Quantize weights (symmetric, zp=0) ----
    s_w1, _ = compute_scale_zp_symmetric(model.fc1.weight.data)
    s_w2, _ = compute_scale_zp_symmetric(model.fc2.weight.data)

    w1_q = quantize_weight_symmetric(model.fc1.weight.data, s_w1)
    w2_q = quantize_weight_symmetric(model.fc2.weight.data, s_w2)

    print(f"  FC1 weight: scale={s_w1:.6f}, range=[{w1_q.min()}, {w1_q.max()}]")
    print(f"  FC2 weight: scale={s_w2:.6f}, range=[{w2_q.min()}, {w2_q.max()}]")

    # ---- Step 3: Calibrate FC1 output range ----
    print("  Calibrating FC1 output range...")
    ranges = calibrate_fc1_output(model, device)
    fc1_out_min, fc1_out_max = ranges["fc1_output"]
    fc2_out_min, fc2_out_max = ranges["fc2_output"]

    # FC1 output scale (symmetric, after ReLU so min=0)
    fc1_out_abs = max(abs(fc1_out_min), abs(fc1_out_max))
    s_out1 = fc1_out_abs / 127.0 if fc1_out_abs > 0 else 1e-8

    # This is also FC2's input scale
    s_in2 = s_out1
    hw_zp2 = 0  # FC1 output after ReLU is non-negative, symmetric around 0

    print(f"  FC1 output range: [{fc1_out_min:.4f}, {fc1_out_max:.4f}]")
    print(f"  FC1 output / FC2 input scale: {s_out1:.6f}, hw_zp={hw_zp2}")

    # FC2 output scale (for requantization to INT8 logits)
    fc2_out_abs = max(abs(fc2_out_min), abs(fc2_out_max))
    s_out2 = fc2_out_abs / 127.0 if fc2_out_abs > 0 else 1e-8

    # ---- Step 4: Compute requant parameters ----
    fc1_mult, fc1_shift = compute_requant_params(s_in1, s_w1, s_out1, shift=16)
    fc2_mult, fc2_shift = compute_requant_params(s_in2, s_w2, s_out2, shift=16)

    print(f"  FC1 requant: mult={fc1_mult}, shift={fc1_shift}")
    print(f"  FC2 requant: mult={fc2_mult}, shift={fc2_shift}")

    # ---- Step 5: Quantize biases ----
    b1_q = quantize_bias(model.fc1.bias.data, s_in1, s_w1)
    b2_q = quantize_bias(model.fc2.bias.data, s_in2, s_w2)

    return {
        "w1": w1_q.cpu().numpy(),
        "w2": w2_q.cpu().numpy(),
        "b1": b1_q.cpu().numpy(),
        "b2": b2_q.cpu().numpy(),
        "fc1_mult": fc1_mult,
        "fc1_shift": fc1_shift,
        "fc2_mult": fc2_mult,
        "fc2_shift": fc2_shift,
        "hw_zp1": hw_zp1,
        "hw_zp2": hw_zp2,
        "s_in1": s_in1,
        "s_w1": s_w1,
        "s_in2": s_in2,
        "s_w2": s_w2,
    }


# ============================================================================
# 4. Bit-accurate INT8 inference (must match hardware exactly)
# ============================================================================
def hw_infer_layer(x_uint8, w_int8, b_int32, zp, mult, shift, relu=True):
    """Bit-accurate single layer inference matching CIM RTL."""
    # Zero-point subtraction
    x_eff = np.clip(x_uint8.astype(np.int32) - zp, 0, 511)
    # MVM
    acc = w_int8.astype(np.int32) @ x_eff.astype(np.int32)
    acc = acc + b_int32.astype(np.int32)
    # ReLU
    if relu:
        acc = np.maximum(acc, 0)
    # Requantize
    out = np.zeros(len(acc), dtype=np.int8)
    for i in range(len(acc)):
        prod = int(acc[i]) * int(mult)
        shifted = (prod + (1 << (shift - 1))) >> shift if shift > 0 else prod
        out[i] = np.int8(max(-128, min(127, shifted)))
    return out


def quantize_image(image_float, s_in=None, zp_in=None):
    """Quantize a [0,1] float image to UINT8 [0,255] for hardware.

    Simple fixed mapping: x_u8 = round(pixel * 255).
    s_in and zp_in are accepted but ignored (for API compatibility).
    The actual scale (1/255) and zp (-128) are baked into the PTQ parameters.
    """
    x_q = np.clip(np.round(image_float * 255.0), 0, 255)
    return x_q.astype(np.uint8)


def hw_infer_mlp(image_uint8, qparams):
    """Full 2-layer INT8 inference matching hardware exactly."""
    fc1_out = hw_infer_layer(
        image_uint8,
        qparams["w1"],
        qparams["b1"],
        qparams["hw_zp1"],
        qparams["fc1_mult"],
        qparams["fc1_shift"],
        relu=True,
    )
    # FC1 output (signed INT8) → reinterpret as UINT8 for FC2 input
    fc2_in = fc1_out.view(np.uint8)
    fc2_out = hw_infer_layer(
        fc2_in,
        qparams["w2"],
        qparams["b2"],
        qparams["hw_zp2"],
        qparams["fc2_mult"],
        qparams["fc2_shift"],
        relu=False,
    )
    pred = int(np.argmax(fc2_out))
    return pred, fc1_out, fc2_out


# ============================================================================
# 5. Hex file generation (identical format to golden_model.py)
# ============================================================================
def weight_to_chunk_hex(weight_int8, tile_rows=TILE_ROWS, tile_cols=TILE_COLS):
    out_dim, in_dim = weight_int8.shape
    n_ob = (out_dim + tile_rows - 1) // tile_rows
    n_ib = (in_dim + tile_cols - 1) // tile_cols
    chunks_per_row = tile_cols // ELEMS_PER_CHUNK
    lines = []
    for ob in range(n_ob):
        for ib in range(n_ib):
            for chunk in range(CHUNKS_PER_TILE):
                row = chunk // chunks_per_row
                col_group = chunk % chunks_per_row
                word = 0
                for b in range(ELEMS_PER_CHUNK):
                    c = col_group * ELEMS_PER_CHUNK + b
                    oi = ob * tile_rows + row
                    ii = ib * tile_cols + c
                    if oi < out_dim and ii < in_dim:
                        val = int(weight_int8[oi, ii]) & 0xFF
                    else:
                        val = 0
                    word |= val << (b * 8)
                lines.append(f"{word:08x}")
    return lines


def bias_to_hex(b):
    return [f"{int(v) & 0xFFFFFFFF:08x}" for v in b]


def input_to_hex(x):
    return [f"{int(v) & 0xFF:02x}" for v in x]


def int8_to_hex(a):
    return [f"{int(v) & 0xFF:02x}" for v in a]


def save_hex(lines, path):
    with open(path, "w") as f:
        for line in lines:
            f.write(line + "\n")


# ============================================================================
# 5b. Raw INT8 matrix export (for the SW baseline NumPy GEMV)
# ============================================================================
def export_qparams_npz(qparams, output_dir):
    """Dump the raw INT8 weight matrices + quant params as a single .npz.

    The SW baseline (benchmark_sw_baseline.py) loads this to run the SAME
    integer inference in NumPy. Shapes: w1 [128,784], w2 [10,128], biases INT32.
    """
    path = os.path.join(output_dir, "mlp_qparams.npz")
    np.savez(
        path,
        fc1_weight=qparams["w1"],
        fc1_bias=qparams["b1"],
        fc1_zp=qparams["hw_zp1"],
        fc1_mult=qparams["fc1_mult"],
        fc1_shift=qparams["fc1_shift"],
        fc2_weight=qparams["w2"],
        fc2_bias=qparams["b2"],
        fc2_zp=qparams["hw_zp2"],
        fc2_mult=qparams["fc2_mult"],
        fc2_shift=qparams["fc2_shift"],
    )
    print(f"  Raw INT8 matrices saved to {path}")
    print(f"    fc1_weight {qparams['w1'].shape}, fc2_weight {qparams['w2'].shape}")
    return path


# ============================================================================
# 6. Main pipeline
# ============================================================================
def main():
    parser = argparse.ArgumentParser(description="MNIST quantize & export for CIM SoC")
    parser.add_argument(
        "--pretrained", type=str, default=None, help="Load pretrained .pt"
    )
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument(
        "--num-test", type=int, default=20, help="Number of test images"
    )
    parser.add_argument("--output-dir", type=str, default="mnist_real_data")
    parser.add_argument("--save-model", type=str, default="mnist_mlp.pt")
    parser.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Random seed (default: None = fully random)",
    )
    parser.add_argument(
        "--export-npz-only",
        action="store_true",
        help="Load --pretrained, quantize, and ONLY write mlp_qparams.npz "
        "(no retraining, no hex/test-image regeneration). Use this to add "
        "the SW-baseline file without disturbing existing FPGA data.",
    )
    args = parser.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    os.makedirs(args.output_dir, exist_ok=True)

    # ------------------------------------------------------------------
    # FAST PATH: only (re)export the raw INT8 matrices for the SW baseline.
    # Requires an existing checkpoint so the weights match the FPGA results.
    # ------------------------------------------------------------------
    if args.export_npz_only:
        if not (args.pretrained and os.path.exists(args.pretrained)):
            sys.exit(
                "ERROR: --export-npz-only requires --pretrained <model.pt> that exists.\n"
                "       Point it at the SAME checkpoint used to generate the FPGA\n"
                "       data in Thesis/data/ (e.g. --pretrained mnist_mlp.pt), so the\n"
                "       SW baseline runs the identical model.\n"
                "       If you do not have that .pt, you must retrain (drop this flag),\n"
                "       and then ALSO re-run the hardware benchmarks for consistency."
            )
        print(f"[export-npz-only] Loading checkpoint: {args.pretrained}")
        model = MnistMLP()
        model.load_state_dict(torch.load(args.pretrained, map_location=device))
        model = model.to(device).eval()

        cal_loader = torch.utils.data.DataLoader(
            datasets.MNIST(
                "./data", train=False, download=True, transform=transforms.ToTensor()
            ),
            batch_size=1000,
        )
        qparams = full_ptq(model, cal_loader, device)
        export_qparams_npz(qparams, args.output_dir)
        print("[export-npz-only] Done. No hex files or test images were modified.")
        return

    # ---- Train or load ----
    # Model is trained on raw [0,1] pixels (no Normalize)
    transform = transforms.Compose([transforms.ToTensor()])
    test_set = datasets.MNIST("./data", train=False, download=True, transform=transform)

    if args.pretrained and os.path.exists(args.pretrained):
        print(f"Loading pretrained model: {args.pretrained}")
        model = MnistMLP()
        model.load_state_dict(torch.load(args.pretrained, map_location=device))
        float_acc = "N/A (pretrained)"
    else:
        model, _, float_acc = train_model(args.epochs, device=device, seed=args.seed)
        torch.save(model.state_dict(), args.save_model)
        print(f"Model saved to {args.save_model}")

    model = model.to(device).eval()

    # ---- Calibration (use first 1000 test images) ----
    cal_loader = torch.utils.data.DataLoader(test_set, batch_size=1000)
    qparams = full_ptq(model, cal_loader, device)

    # ---- Verify INT8 accuracy on full test set ----
    print("\n" + "=" * 60)
    print("INT8 bit-accurate inference accuracy")
    print("=" * 60)

    transform_raw = transforms.ToTensor()  # no normalization for raw pixels
    test_set_raw = datasets.MNIST(
        "./data", train=False, download=True, transform=transform_raw
    )

    correct_int8 = 0
    correct_float = 0
    total = 0

    for i in range(len(test_set_raw)):
        img_tensor, label = test_set_raw[i]
        img_float = img_tensor.numpy().flatten()  # [0, 1] float

        # Quantize image to UINT8
        img_uint8 = quantize_image(img_float, qparams["s_in1"], -qparams["hw_zp1"])

        # INT8 inference
        pred_int8, _, _ = hw_infer_mlp(img_uint8, qparams)
        if pred_int8 == label:
            correct_int8 += 1

        # Float inference for comparison
        with torch.no_grad():
            img_norm = test_set[i][0].unsqueeze(0).to(device)
            pred_float = model(img_norm).argmax(1).item()
        if pred_float == label:
            correct_float += 1

        total += 1

    acc_int8 = 100.0 * correct_int8 / total
    acc_float = 100.0 * correct_float / total
    print(f"  Float32 accuracy: {acc_float:.2f}% ({correct_float}/{total})")
    print(f"  INT8 accuracy:    {acc_int8:.2f}% ({correct_int8}/{total})")
    print(f"  Accuracy drop:    {acc_float - acc_int8:.2f}%")

    # ---- Export hex files ----
    print("\n" + "=" * 60)
    print("Exporting hex files")
    print("=" * 60)

    # Weights + bias + quant params (shared across all images)
    save_hex(
        weight_to_chunk_hex(qparams["w1"]),
        os.path.join(args.output_dir, "fc1_weight_tiles.hex"),
    )
    save_hex(
        weight_to_chunk_hex(qparams["w2"]),
        os.path.join(args.output_dir, "fc2_weight_tiles.hex"),
    )
    save_hex(bias_to_hex(qparams["b1"]), os.path.join(args.output_dir, "fc1_bias.hex"))
    save_hex(bias_to_hex(qparams["b2"]), os.path.join(args.output_dir, "fc2_bias.hex"))
    save_hex(
        [
            f"{qparams['fc1_mult'] & 0xFFFFFFFF:08x}",
            f"{qparams['fc1_shift'] & 0xFFFFFFFF:08x}",
            f"{qparams['fc2_mult'] & 0xFFFFFFFF:08x}",
            f"{qparams['fc2_shift'] & 0xFFFFFFFF:08x}",
        ],
        os.path.join(args.output_dir, "quant_params.hex"),
    )
    # Zero points — write them explicitly so benchmark_e2e.load_mlp_model reads
    # the true zp (0) instead of falling back to a wrong default. This MNIST MLP
    # is quantized with hw_zp1 = hw_zp2 = 0.
    save_hex(
        [
            f"{qparams['hw_zp1'] & 0xFFFFFFFF:08x}",
            f"{qparams['hw_zp2'] & 0xFFFFFFFF:08x}",
        ],
        os.path.join(args.output_dir, "zero_points.hex"),
    )
    print(f"  Weights/bias/quant/zp saved to {args.output_dir}/")

    # Raw INT8 matrices for the SW baseline (NumPy GEMV)
    export_qparams_npz(qparams, args.output_dir)

    # Test images
    img_dir = os.path.join(args.output_dir, "test_images")
    os.makedirs(img_dir, exist_ok=True)

    # Export N test images
    n_export = min(args.num_test, len(test_set_raw))
    export_correct = 0

    for i in range(n_export):
        img_tensor, label = test_set_raw[i]
        img_float = img_tensor.numpy().flatten()
        img_uint8 = quantize_image(img_float, qparams["s_in1"], -qparams["hw_zp1"])

        pred, fc1_out, fc2_out = hw_infer_mlp(img_uint8, qparams)
        if pred == label:
            export_correct += 1

        prefix = f"img_{i:04d}"
        save_hex(input_to_hex(img_uint8), os.path.join(img_dir, f"{prefix}.hex"))
        save_hex(int8_to_hex(fc1_out), os.path.join(img_dir, f"{prefix}_fc1.hex"))
        save_hex(int8_to_hex(fc2_out), os.path.join(img_dir, f"{prefix}_fc2.hex"))

        with open(os.path.join(img_dir, f"{prefix}_label.txt"), "w") as f:
            f.write(f"{label}\n")
        with open(os.path.join(img_dir, f"{prefix}_pred.txt"), "w") as f:
            f.write(f"{pred}\n")

    print(f"  Exported {n_export} test images to {img_dir}/")
    print(
        f"  INT8 accuracy on exported images: {100.0 * export_correct / n_export:.1f}%"
    )

    # Model info
    info_path = os.path.join(args.output_dir, "model_info.txt")
    with open(info_path, "w") as f:
        f.write(f"Model: 784→128(ReLU)→10\n")
        f.write(f"Float accuracy: {acc_float:.2f}%\n")
        f.write(f"INT8 accuracy: {acc_int8:.2f}%\n")
        f.write(f"FC1: w_scale={qparams['s_w1']:.6f}, in_zp(hw)={qparams['hw_zp1']}\n")
        f.write(f"FC2: w_scale={qparams['s_w2']:.6f}, in_zp(hw)={qparams['hw_zp2']}\n")
        f.write(
            f"FC1 requant: mult={qparams['fc1_mult']}, shift={qparams['fc1_shift']}\n"
        )
        f.write(
            f"FC2 requant: mult={qparams['fc2_mult']}, shift={qparams['fc2_shift']}\n"
        )
        f.write(f"Exported test images: {n_export}\n")
    print(f"  Model info saved to {info_path}")

    # ---- Summary ----
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  Float32 accuracy: {acc_float:.2f}%")
    print(f"  INT8 accuracy:    {acc_int8:.2f}%")
    print(f"  HW zero points:   FC1={qparams['hw_zp1']}, FC2={qparams['hw_zp2']}")
    print(f"  Requant params:   FC1=({qparams['fc1_mult']}, {qparams['fc1_shift']})")
    print(f"                    FC2=({qparams['fc2_mult']}, {qparams['fc2_shift']})")
    print(f"\n  Upload {args.output_dir}/ to PYNQ and run cim_mnist_real_test.py")
    print("=" * 60)


# import numpy as np
if __name__ == "__main__":
    main()
