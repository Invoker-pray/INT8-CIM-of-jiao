#!/usr/bin/env python3
"""
small_mlp_quantize.py — Train 784→16→10 MLP for PicoRV32 BRAM deployment.

This model fits entirely in 32KB BRAM (~17KB data + ~4KB code + stack).
Used to prove PicoRV32 → CIM control works end-to-end.

Expected accuracy: Float ~92%, INT8 ~91% (small model trades accuracy for size).

Usage:
  python small_mlp_quantize.py                    # Train + export
  python small_mlp_quantize.py --seed 42          # Reproducible
  python small_mlp_quantize.py --output-dir small_mlp_data

  # NEW: only (re)export the raw INT8 matrices needed by the SW baseline,
  # from an existing checkpoint, WITHOUT retraining or touching the hex files:
  python small_mlp_quantize.py --export-npz-only --pretrained small_mlp.pt \
                               --output-dir small_mlp_data
"""

import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms
import numpy as np
import argparse
import os
import sys


# ============================================================================
# Hardware constants
# ============================================================================
TILE_ROWS = 16
TILE_COLS = 16
ELEMS_PER_CHUNK = 4
CHUNKS_PER_ROW = 4
CHUNKS_PER_TILE = 64


# ============================================================================
# Model
# ============================================================================
class SmallMLP(nn.Module):
    """784→16→10 MLP — fits in 32KB BRAM for PicoRV32."""

    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(784, 16)
        self.relu = nn.ReLU()
        self.fc2 = nn.Linear(16, 10)

    def forward(self, x):
        x = x.view(-1, 784)
        return self.fc2(self.relu(self.fc1(x)))


# ============================================================================
# Training
# ============================================================================
def train(epochs=20, lr=0.001, device="cpu", seed=None):
    if seed is not None:
        np.random.seed(seed)
        torch.manual_seed(seed)

    print("=" * 50)
    print("Training SmallMLP (784→16→10)")
    print("=" * 50)

    transform = transforms.Compose([transforms.ToTensor()])
    train_set = datasets.MNIST("./data", train=True, download=True, transform=transform)
    test_set = datasets.MNIST("./data", train=False, download=True, transform=transform)
    train_loader = torch.utils.data.DataLoader(train_set, batch_size=128, shuffle=True)
    test_loader = torch.utils.data.DataLoader(test_set, batch_size=1000)

    model = SmallMLP().to(device)
    optimizer = optim.Adam(model.parameters(), lr=lr)
    criterion = nn.CrossEntropyLoss()

    for epoch in range(epochs):
        model.train()
        loss_sum = 0
        for data, target in train_loader:
            data, target = data.to(device), target.to(device)
            optimizer.zero_grad()
            loss = criterion(model(data), target)
            loss.backward()
            optimizer.step()
            loss_sum += loss.item()

        model.eval()
        correct = 0
        total = 0
        with torch.no_grad():
            for data, target in test_loader:
                data, target = data.to(device), target.to(device)
                correct += model(data).argmax(1).eq(target).sum().item()
                total += target.size(0)
        acc = 100.0 * correct / total
        print(
            f"  Epoch {epoch + 1}/{epochs}: loss={loss_sum / len(train_loader):.4f}, acc={acc:.2f}%"
        )

    return model, acc


# ============================================================================
# Quantization
# ============================================================================
def symmetric_scale(t):
    m = t.abs().max().item()
    return m / 127.0 if m > 0 else 1e-8


def quant_sym(t, s):
    return torch.clamp(torch.round(t / s), -128, 127).to(torch.int8)


def quant_bias(b, s_in, s_w):
    return torch.clamp(torch.round(b / (s_in * s_w)), -(2**31), 2**31 - 1).to(
        torch.int32
    )


def requant_params(s_in, s_w, s_out, shift=16):
    M = (s_in * s_w) / s_out
    return max(1, int(round(M * (1 << shift)))), shift


def calibrate(model, device="cpu"):
    transform = transforms.Compose([transforms.ToTensor()])
    cal_set = datasets.MNIST("./data", train=True, download=True, transform=transform)
    cal_loader = torch.utils.data.DataLoader(cal_set, batch_size=1000, shuffle=False)
    model.eval()
    fc1_min, fc1_max = float("inf"), float("-inf")
    fc2_min, fc2_max = float("inf"), float("-inf")
    with torch.no_grad():
        for data, _ in cal_loader:
            data = data.to(device).view(-1, 784)
            o1 = model.relu(model.fc1(data))
            o2 = model.fc2(o1)
            fc1_min = min(fc1_min, o1.min().item())
            fc1_max = max(fc1_max, o1.max().item())
            fc2_min = min(fc2_min, o2.min().item())
            fc2_max = max(fc2_max, o2.max().item())
    return {"fc1": (fc1_min, fc1_max), "fc2": (fc2_min, fc2_max)}


def full_ptq(model, device="cpu"):
    print("\nQuantizing...")
    model = model.to(device).eval()
    ranges = calibrate(model, device)

    s_in = 1.0 / 255.0

    s_w1 = symmetric_scale(model.fc1.weight.data)
    w1_q = quant_sym(model.fc1.weight.data, s_w1)
    s_out1 = max(abs(ranges["fc1"][0]), abs(ranges["fc1"][1])) / 127.0
    if s_out1 == 0:
        s_out1 = 1e-8
    b1_q = quant_bias(model.fc1.bias.data, s_in, s_w1)
    m1, sh1 = requant_params(s_in, s_w1, s_out1)

    s_in2 = s_out1
    s_w2 = symmetric_scale(model.fc2.weight.data)
    w2_q = quant_sym(model.fc2.weight.data, s_w2)
    s_out2 = max(abs(ranges["fc2"][0]), abs(ranges["fc2"][1])) / 127.0
    if s_out2 == 0:
        s_out2 = 1e-8
    b2_q = quant_bias(model.fc2.bias.data, s_in2, s_w2)
    m2, sh2 = requant_params(s_in2, s_w2, s_out2)

    print(f"  FC1: s_w={s_w1:.6f}, s_out={s_out1:.6f}, mult={m1}, shift={sh1}")
    print(f"  FC2: s_w={s_w2:.6f}, s_out={s_out2:.6f}, mult={m2}, shift={sh2}")

    return {
        "w1": w1_q.cpu().numpy(),
        "b1": b1_q.cpu().numpy(),
        "w2": w2_q.cpu().numpy(),
        "b2": b2_q.cpu().numpy(),
        "fc1_mult": m1,
        "fc1_shift": sh1,
        "fc2_mult": m2,
        "fc2_shift": sh2,
        "hw_zp1": 0,
        "hw_zp2": 0,
    }


# ============================================================================
# Bit-accurate INT8 inference
# ============================================================================
def hw_mvm(x_u8, w_i8, b_i32, zp, mult, shift, relu):
    x_eff = np.clip(x_u8.astype(np.int32) - zp, -512, 511)
    acc = w_i8.astype(np.int32) @ x_eff.astype(np.int32) + b_i32.astype(np.int32)
    if relu:
        acc = np.maximum(acc, 0)
    out = np.zeros(len(acc), dtype=np.int8)
    for i in range(len(acc)):
        prod = int(acc[i]) * int(mult)
        shifted = (prod + (1 << (shift - 1))) >> shift if shift > 0 else prod
        out[i] = np.int8(max(-128, min(127, shifted)))
    return out


def int8_infer(img_u8, qp):
    fc1 = hw_mvm(
        img_u8, qp["w1"], qp["b1"], qp["hw_zp1"], qp["fc1_mult"], qp["fc1_shift"], True
    )
    fc2_in = fc1.view(np.uint8)
    fc2 = hw_mvm(
        fc2_in, qp["w2"], qp["b2"], qp["hw_zp2"], qp["fc2_mult"], qp["fc2_shift"], False
    )
    return int(np.argmax(fc2)), fc1, fc2


# ============================================================================
# Hex export
# ============================================================================
def w2chunks(w):
    od, id_ = w.shape
    nob = (od + TILE_ROWS - 1) // TILE_ROWS
    nib = (id_ + TILE_COLS - 1) // TILE_COLS
    chunks = []
    for ob in range(nob):
        for ib in range(nib):
            for ch in range(CHUNKS_PER_TILE):
                r = ch // CHUNKS_PER_ROW
                cg = ch % CHUNKS_PER_ROW
                word = 0
                for b in range(ELEMS_PER_CHUNK):
                    oi = ob * TILE_ROWS + r
                    ii = ib * TILE_COLS + cg * ELEMS_PER_CHUNK + b
                    if oi < od and ii < id_:
                        word |= (int(w[oi, ii]) & 0xFF) << (b * 8)
                chunks.append(word)
    return chunks


def save_hex(lines, path):
    with open(path, "w") as f:
        for l in lines:
            f.write(l + "\n")


# ============================================================================
# Raw INT8 matrix export (for the SW baseline NumPy GEMV)
# ============================================================================
def export_qparams_npz(qp, output_dir):
    """Dump the raw INT8 weight matrices + quant params as a single .npz.

    The SW baseline (benchmark_sw_baseline.py) loads this to run the SAME
    integer inference in NumPy. Shapes: w1 [16,784], w2 [10,16], biases INT32.
    """
    path = os.path.join(output_dir, "mlp_qparams.npz")
    np.savez(
        path,
        fc1_weight=qp["w1"],
        fc1_bias=qp["b1"],
        fc1_zp=qp["hw_zp1"],
        fc1_mult=qp["fc1_mult"],
        fc1_shift=qp["fc1_shift"],
        fc2_weight=qp["w2"],
        fc2_bias=qp["b2"],
        fc2_zp=qp["hw_zp2"],
        fc2_mult=qp["fc2_mult"],
        fc2_shift=qp["fc2_shift"],
    )
    print(f"  Raw INT8 matrices saved to {path}")
    print(f"    fc1_weight {qp['w1'].shape}, fc2_weight {qp['w2'].shape}")
    return path


# ============================================================================
# Main
# ============================================================================
def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--num-test", type=int, default=20)
    parser.add_argument("--output-dir", type=str, default="small_mlp_data")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument(
        "--pretrained",
        type=str,
        default=None,
        help="Load pretrained .pt (required for --export-npz-only)",
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
                "       data in Thesis/data/ (e.g. --pretrained small_mlp.pt), so the\n"
                "       SW baseline runs the identical model.\n"
                "       If you do not have that .pt, you must retrain (drop this flag),\n"
                "       and then ALSO re-run the hardware benchmarks for consistency."
            )
        print(f"[export-npz-only] Loading checkpoint: {args.pretrained}")
        model = SmallMLP()
        model.load_state_dict(torch.load(args.pretrained, map_location=device))
        model = model.to(device).eval()

        qp = full_ptq(model, device)
        export_qparams_npz(qp, args.output_dir)
        print("[export-npz-only] Done. No hex files or test images were modified.")
        return

    # Train (or load if --pretrained given)
    if args.pretrained and os.path.exists(args.pretrained):
        print(f"Loading pretrained model: {args.pretrained}")
        model = SmallMLP()
        model.load_state_dict(torch.load(args.pretrained, map_location=device))
        model = model.to(device).eval()
        float_acc = float("nan")
    else:
        model, float_acc = train(args.epochs, device=device, seed=args.seed)
        torch.save(model.state_dict(), "small_mlp.pt")

    # Quantize
    qp = full_ptq(model, device)

    # INT8 accuracy
    print("\nINT8 accuracy:")
    transform_raw = transforms.ToTensor()
    test_set = datasets.MNIST(
        "./data", train=False, download=True, transform=transform_raw
    )
    correct = 0
    total = len(test_set)
    for i in range(total):
        img, label = test_set[i]
        img_u8 = np.clip(np.round(img.numpy().flatten() * 255), 0, 255).astype(np.uint8)
        pred, _, _ = int8_infer(img_u8, qp)
        if pred == label:
            correct += 1
    acc_i8 = 100.0 * correct / total
    print(f"  Float: {float_acc:.2f}%, INT8: {acc_i8:.2f}%")

    # Export hex
    d = args.output_dir
    fc1_chunks = w2chunks(qp["w1"])
    fc2_chunks = w2chunks(qp["w2"])

    save_hex([f"{v:08x}" for v in fc1_chunks], f"{d}/fc1_weight_tiles.hex")
    save_hex([f"{v:08x}" for v in fc2_chunks], f"{d}/fc2_weight_tiles.hex")
    save_hex([f"{int(v) & 0xFFFFFFFF:08x}" for v in qp["b1"]], f"{d}/fc1_bias.hex")
    save_hex([f"{int(v) & 0xFFFFFFFF:08x}" for v in qp["b2"]], f"{d}/fc2_bias.hex")
    save_hex(
        [
            f"{qp['fc1_mult'] & 0xFFFFFFFF:08x}",
            f"{qp['fc1_shift'] & 0xFFFFFFFF:08x}",
            f"{qp['fc2_mult'] & 0xFFFFFFFF:08x}",
            f"{qp['fc2_shift'] & 0xFFFFFFFF:08x}",
        ],
        f"{d}/quant_params.hex",
    )
    save_hex(
        [
            f"{qp['hw_zp1'] & 0xFFFFFFFF:08x}",
            f"{qp['hw_zp2'] & 0xFFFFFFFF:08x}",
        ],
        f"{d}/zero_points.hex",
    )

    # Raw INT8 matrices for the SW baseline (NumPy GEMV)
    export_qparams_npz(qp, d)

    # Export test images
    img_dir = f"{d}/test_images"
    os.makedirs(img_dir, exist_ok=True)
    n = min(args.num_test, len(test_set))
    exp_correct = 0
    for i in range(n):
        img, label = test_set[i]
        img_u8 = np.clip(np.round(img.numpy().flatten() * 255), 0, 255).astype(np.uint8)
        pred, fc1_out, fc2_out = int8_infer(img_u8, qp)
        if pred == label:
            exp_correct += 1
        pf = f"img_{i:04d}"
        save_hex([f"{int(v) & 0xFF:02x}" for v in img_u8], f"{img_dir}/{pf}.hex")
        save_hex([f"{int(v) & 0xFF:02x}" for v in fc2_out], f"{img_dir}/{pf}_fc2.hex")
        with open(f"{img_dir}/{pf}_label.txt", "w") as f:
            f.write(f"{label}\n")
        with open(f"{img_dir}/{pf}_pred.txt", "w") as f:
            f.write(f"{pred}\n")
        print(f"  [{i:04d}] label={label}, pred={pred} {'✓' if pred == label else '✗'}")

    # BRAM size report
    data_bytes = (
        len(fc1_chunks) * 4
        + len(fc2_chunks) * 4
        + len(qp["b1"]) * 4
        + len(qp["b2"]) * 4
        + 784
    )
    print(f"\nBRAM data size: {data_bytes} bytes ({data_bytes / 1024:.1f} KB)")
    print(f"Fits in 32KB BRAM: {'YES' if data_bytes < 28000 else 'NO'}")
    print(f"FC1 chunks: {len(fc1_chunks)}, FC2 chunks: {len(fc2_chunks)}")
    print(f"\nExported to {d}/")


if __name__ == "__main__":
    main()
