#!/usr/bin/env python3
"""
gen_lenet5_data.py — Train LeNet-5 on MNIST from scratch, INT8 PTQ, and export
EVERYTHING needed for both the FPGA and the SW baseline, in one run.

This is a from-scratch generator (NOT an exporter from existing artifacts):
it trains the model, quantizes it, runs bit-accurate INT8 inference, and writes
the packed .hex tiles, the raw-matrix .npz, and N test images.

Network: LeNet-5 (MNIST 28x28)
  Conv1:   1x28x28 -> 6x24x24    (5x5 kernel, no padding)
  Pool1:   6x24x24 -> 6x12x12    (2x2 max pool)
  Conv2:   6x12x12 -> 16x8x8     (5x5 kernel, no padding)
  Pool2:   16x8x8  -> 16x4x4     (2x2 max pool)
  FC3:     256 -> 120
  FC4:     120 -> 84
  FC5:     84  -> 10

Hardware mapping (matches cim_pkg.sv / golden_model.py):
  Conv layers : Python im2col -> CIM MVM (per output pixel)
  Pool layers : Python max-pool (no HW)
  FC layers   : CIM MVM directly
  Input       : fixed scale 1/255, zp=0  (x_eff = x_u8)
  Weights     : symmetric INT8, zp=0
  Bias        : INT32, scale = s_in * s_w
  Requant     : multiply-shift, matches cim_pkg::requantize

Usage (mirrors mnist_quantize.py):
  python gen_lenet5_data.py                       # train + quantize + export 20 imgs
  python gen_lenet5_data.py --num-test 200        # export 200 test images
  python gen_lenet5_data.py --pretrained lenet5.pt --num-test 200   # reuse a checkpoint
  python gen_lenet5_data.py --epochs 20 --seed 42 --output-dir lenet5_data

Output (in --output-dir, default lenet5_data/):
  {conv1,conv2,fc3,fc4,fc5}_weight_tiles.hex   packed INT8 weight tiles (FPGA)
  {conv1,conv2,fc3,fc4,fc5}_bias.hex           INT32 bias (FPGA)
  quant_params.hex                             per-layer mult,shift (FPGA)
  zero_points.hex                              per-layer zp (FPGA)
  lenet5_qparams.npz                           raw INT8 matrices (SW baseline)
  layer_info.txt / model_info.txt              human-readable summary
  test_images/
    img_0000.hex        UINT8 image (784)
    img_0000_fc5.hex    INT8 golden logits
    img_0000_label.txt  true label
    img_0000_pred.txt   python INT8 prediction
    ...
"""

import argparse
import os
import sys

import numpy as np
import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms


# ============================================================================
# Hardware constants (must match cim_pkg.sv)
# ============================================================================
TILE_ROWS = 16
TILE_COLS = 16
ELEMS_PER_CHUNK = 4
CHUNKS_PER_ROW = 4
CHUNKS_PER_TILE = 64


def _apply_seed(seed):
    if seed is not None:
        np.random.seed(seed)
        torch.manual_seed(seed)


# ============================================================================
# 1. LeNet-5 model
# ============================================================================
class LeNet5(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 6, 5)  # 28 -> 24
        self.conv2 = nn.Conv2d(6, 16, 5)  # 12 -> 8
        self.fc3 = nn.Linear(16 * 4 * 4, 120)
        self.fc4 = nn.Linear(120, 84)
        self.fc5 = nn.Linear(84, 10)
        self.relu = nn.ReLU()
        self.pool = nn.MaxPool2d(2, 2)

    def forward(self, x):
        x = self.pool(self.relu(self.conv1(x)))  # [B,6,12,12]
        x = self.pool(self.relu(self.conv2(x)))  # [B,16,4,4]
        x = x.view(-1, 16 * 4 * 4)
        x = self.relu(self.fc3(x))
        x = self.relu(self.fc4(x))
        x = self.fc5(x)
        return x


# ============================================================================
# 2. Training
# ============================================================================
def train_lenet5(epochs=15, lr=0.001, device="cpu", seed=None):
    _apply_seed(seed)

    print("=" * 60)
    print("Training LeNet-5 on MNIST (from scratch)")
    print(f"Seed: {seed if seed is not None else 'None (fully random)'}")
    print("=" * 60)

    # NO Normalize — raw [0,1] pixels for hardware compatibility
    transform = transforms.Compose([transforms.ToTensor()])
    train_set = datasets.MNIST("./data", train=True, download=True, transform=transform)
    test_set = datasets.MNIST("./data", train=False, download=True, transform=transform)
    train_loader = torch.utils.data.DataLoader(train_set, batch_size=128, shuffle=True)
    test_loader = torch.utils.data.DataLoader(test_set, batch_size=1000)

    model = LeNet5().to(device)
    optimizer = optim.Adam(model.parameters(), lr=lr)
    criterion = nn.CrossEntropyLoss()

    acc = 0.0
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

        model.eval()
        correct = 0
        total = 0
        with torch.no_grad():
            for data, target in test_loader:
                data, target = data.to(device), target.to(device)
                pred = model(data).argmax(1)
                correct += pred.eq(target).sum().item()
                total += target.size(0)
        acc = 100.0 * correct / total
        print(
            f"  Epoch {epoch + 1}/{epochs}: "
            f"loss={total_loss / len(train_loader):.4f}, acc={acc:.2f}%"
        )

    print(f"\nFinal float32 accuracy: {acc:.2f}%")
    return model, acc


# ============================================================================
# 3. Quantization utilities
# ============================================================================
def symmetric_scale(tensor):
    max_val = tensor.abs().max().item()
    return max_val / 127.0 if max_val > 0 else 1e-8


def quantize_symmetric(tensor, scale):
    return torch.clamp(torch.round(tensor / scale), -128, 127).to(torch.int8)


def quantize_bias_int32(bias, s_in, s_w):
    scale = s_in * s_w
    return torch.clamp(torch.round(bias / scale), -(2**31), 2**31 - 1).to(torch.int32)


def compute_requant(s_in, s_w, s_out, shift=16):
    M = (s_in * s_w) / s_out
    mult = max(1, int(round(M * (1 << shift))))
    return mult, shift


# ============================================================================
# 4. Calibration
# ============================================================================
def calibrate(model, device="cpu"):
    transform = transforms.Compose([transforms.ToTensor()])
    cal_set = datasets.MNIST("./data", train=True, download=True, transform=transform)
    cal_loader = torch.utils.data.DataLoader(cal_set, batch_size=500, shuffle=False)

    ranges = {}
    for name in [
        "conv1_out",
        "pool1_out",
        "conv2_out",
        "pool2_out",
        "fc3_out",
        "fc4_out",
        "fc5_out",
    ]:
        ranges[name] = [float("inf"), float("-inf")]

    def update(name, tensor):
        ranges[name][0] = min(ranges[name][0], tensor.min().item())
        ranges[name][1] = max(ranges[name][1], tensor.max().item())

    model.eval()
    with torch.no_grad():
        for data, _ in cal_loader:
            data = data.to(device)
            c1 = model.relu(model.conv1(data))
            update("conv1_out", c1)
            p1 = model.pool(c1)
            update("pool1_out", p1)
            c2 = model.relu(model.conv2(p1))
            update("conv2_out", c2)
            p2 = model.pool(c2)
            update("pool2_out", p2)
            flat = p2.view(-1, 256)
            f3 = model.relu(model.fc3(flat))
            update("fc3_out", f3)
            f4 = model.relu(model.fc4(f3))
            update("fc4_out", f4)
            f5 = model.fc5(f4)
            update("fc5_out", f5)

    return ranges


# ============================================================================
# 5. Full PTQ
# ============================================================================
def full_ptq_lenet5(model, device="cpu"):
    print("\n" + "=" * 60)
    print("Post-Training Quantization (LeNet-5)")
    print("=" * 60)

    model.eval()
    model_cpu = model.cpu()

    print("  Calibrating activation ranges...")
    ranges = calibrate(model_cpu, "cpu")

    # Input: fixed scale=1/255, zp=0
    s_in0 = 1.0 / 255.0

    # ---- Conv1 ----
    s_w_c1 = symmetric_scale(model_cpu.conv1.weight.data)
    w_c1 = quantize_symmetric(model_cpu.conv1.weight.data, s_w_c1)
    s_out_c1 = max(abs(ranges["conv1_out"][0]), abs(ranges["conv1_out"][1])) / 127.0
    if s_out_c1 == 0:
        s_out_c1 = 1e-8
    b_c1 = quantize_bias_int32(model_cpu.conv1.bias.data, s_in0, s_w_c1)
    m_c1, sh_c1 = compute_requant(s_in0, s_w_c1, s_out_c1)
    print(
        f"  Conv1: s_w={s_w_c1:.6f}, s_out={s_out_c1:.6f}, mult={m_c1}, shift={sh_c1}"
    )

    # ---- Conv2 ---- (input scale = conv1 output scale; pool is max so scale unchanged)
    s_in_c2 = s_out_c1
    s_w_c2 = symmetric_scale(model_cpu.conv2.weight.data)
    w_c2 = quantize_symmetric(model_cpu.conv2.weight.data, s_w_c2)
    s_out_c2 = max(abs(ranges["conv2_out"][0]), abs(ranges["conv2_out"][1])) / 127.0
    if s_out_c2 == 0:
        s_out_c2 = 1e-8
    b_c2 = quantize_bias_int32(model_cpu.conv2.bias.data, s_in_c2, s_w_c2)
    m_c2, sh_c2 = compute_requant(s_in_c2, s_w_c2, s_out_c2)
    print(
        f"  Conv2: s_w={s_w_c2:.6f}, s_out={s_out_c2:.6f}, mult={m_c2}, shift={sh_c2}"
    )

    # ---- FC3 ----
    s_in_fc3 = s_out_c2
    s_w_f3 = symmetric_scale(model_cpu.fc3.weight.data)
    w_f3 = quantize_symmetric(model_cpu.fc3.weight.data, s_w_f3)
    s_out_f3 = max(abs(ranges["fc3_out"][0]), abs(ranges["fc3_out"][1])) / 127.0
    if s_out_f3 == 0:
        s_out_f3 = 1e-8
    b_f3 = quantize_bias_int32(model_cpu.fc3.bias.data, s_in_fc3, s_w_f3)
    m_f3, sh_f3 = compute_requant(s_in_fc3, s_w_f3, s_out_f3)
    print(
        f"  FC3:   s_w={s_w_f3:.6f}, s_out={s_out_f3:.6f}, mult={m_f3}, shift={sh_f3}"
    )

    # ---- FC4 ----
    s_in_f4 = s_out_f3
    s_w_f4 = symmetric_scale(model_cpu.fc4.weight.data)
    w_f4 = quantize_symmetric(model_cpu.fc4.weight.data, s_w_f4)
    s_out_f4 = max(abs(ranges["fc4_out"][0]), abs(ranges["fc4_out"][1])) / 127.0
    if s_out_f4 == 0:
        s_out_f4 = 1e-8
    b_f4 = quantize_bias_int32(model_cpu.fc4.bias.data, s_in_f4, s_w_f4)
    m_f4, sh_f4 = compute_requant(s_in_f4, s_w_f4, s_out_f4)
    print(
        f"  FC4:   s_w={s_w_f4:.6f}, s_out={s_out_f4:.6f}, mult={m_f4}, shift={sh_f4}"
    )

    # ---- FC5 ----
    s_in_f5 = s_out_f4
    s_w_f5 = symmetric_scale(model_cpu.fc5.weight.data)
    w_f5 = quantize_symmetric(model_cpu.fc5.weight.data, s_w_f5)
    s_out_f5 = max(abs(ranges["fc5_out"][0]), abs(ranges["fc5_out"][1])) / 127.0
    if s_out_f5 == 0:
        s_out_f5 = 1e-8
    b_f5 = quantize_bias_int32(model_cpu.fc5.bias.data, s_in_f5, s_w_f5)
    m_f5, sh_f5 = compute_requant(s_in_f5, s_w_f5, s_out_f5)
    print(
        f"  FC5:   s_w={s_w_f5:.6f}, s_out={s_out_f5:.6f}, mult={m_f5}, shift={sh_f5}"
    )

    return {
        "layers": [
            {
                "name": "conv1",
                "type": "conv",
                "weight": w_c1.numpy(),
                "bias": b_c1.numpy(),
                "zp": 0,
                "mult": m_c1,
                "shift": sh_c1,
                "relu": True,
                "C_out": 6,
                "C_in": 1,
                "K_h": 5,
                "K_w": 5,
                "stride": 1,
                "padding": 0,
            },
            {"name": "pool1", "type": "pool", "kernel": 2, "stride": 2},
            {
                "name": "conv2",
                "type": "conv",
                "weight": w_c2.numpy(),
                "bias": b_c2.numpy(),
                "zp": 0,
                "mult": m_c2,
                "shift": sh_c2,
                "relu": True,
                "C_out": 16,
                "C_in": 6,
                "K_h": 5,
                "K_w": 5,
                "stride": 1,
                "padding": 0,
            },
            {"name": "pool2", "type": "pool", "kernel": 2, "stride": 2},
            {
                "name": "fc3",
                "type": "fc",
                "weight": w_f3.numpy(),
                "bias": b_f3.numpy(),
                "zp": 0,
                "mult": m_f3,
                "shift": sh_f3,
                "relu": True,
                "in_dim": 256,
                "out_dim": 120,
            },
            {
                "name": "fc4",
                "type": "fc",
                "weight": w_f4.numpy(),
                "bias": b_f4.numpy(),
                "zp": 0,
                "mult": m_f4,
                "shift": sh_f4,
                "relu": True,
                "in_dim": 120,
                "out_dim": 84,
            },
            {
                "name": "fc5",
                "type": "fc",
                "weight": w_f5.numpy(),
                "bias": b_f5.numpy(),
                "zp": 0,
                "mult": m_f5,
                "shift": sh_f5,
                "relu": False,
                "in_dim": 84,
                "out_dim": 10,
            },
        ]
    }


# ============================================================================
# 6. Bit-accurate INT8 inference (matches CIM hardware)
# ============================================================================
def hw_mvm(x_u8, w_i8, b_i32, zp, mult, shift, relu):
    x_eff = np.clip(x_u8.astype(np.int32) - zp, 0, 511)
    acc = w_i8.astype(np.int32) @ x_eff.astype(np.int32) + b_i32.astype(np.int32)
    if relu:
        acc = np.maximum(acc, 0)
    out = np.zeros(len(acc), dtype=np.int8)
    for i in range(len(acc)):
        prod = int(acc[i]) * int(mult)
        shifted = (prod + (1 << (shift - 1))) >> shift if shift > 0 else prod
        out[i] = np.int8(max(-128, min(127, shifted)))
    return out


def im2col(feat, kh, kw, stride=1, padding=0):
    C, H, W = feat.shape
    if padding > 0:
        p = np.zeros((C, H + 2 * padding, W + 2 * padding), dtype=feat.dtype)
        p[:, padding : padding + H, padding : padding + W] = feat
        feat = p
    Hp, Wp = feat.shape[1], feat.shape[2]
    oh = (Hp - kh) // stride + 1
    ow = (Wp - kw) // stride + 1
    col = np.zeros((C * kh * kw, oh * ow), dtype=feat.dtype)
    idx = 0
    for i in range(oh):
        for j in range(ow):
            col[:, idx] = feat[
                :, i * stride : i * stride + kh, j * stride : j * stride + kw
            ].flatten()
            idx += 1
    return col, oh, ow


def maxpool2d(feat, k=2, s=2):
    C, H, W = feat.shape
    oh, ow = H // s, W // s
    out = np.zeros((C, oh, ow), dtype=feat.dtype)
    for c in range(C):
        for i in range(oh):
            for j in range(ow):
                out[c, i, j] = feat[c, i * s : i * s + k, j * s : j * s + k].max()
    return out


def int8_infer_lenet5(image_u8_flat, qparams):
    x = image_u8_flat.reshape(1, 28, 28)
    intermediates = {}

    for layer in qparams["layers"]:
        name = layer["name"]

        if layer["type"] == "conv":
            w4d = layer["weight"]
            C_out = layer["C_out"]
            w2d = w4d.reshape(C_out, -1)
            col, oh, ow = im2col(
                x, layer["K_h"], layer["K_w"], layer["stride"], layer["padding"]
            )
            n_pix = oh * ow
            out_flat = np.zeros((C_out, n_pix), dtype=np.int8)
            for p in range(n_pix):
                out_flat[:, p] = hw_mvm(
                    col[:, p],
                    w2d,
                    layer["bias"],
                    layer["zp"],
                    layer["mult"],
                    layer["shift"],
                    layer["relu"],
                )
            x = out_flat.reshape(C_out, oh, ow)
            intermediates[name] = x.copy()

        elif layer["type"] == "pool":
            x_signed = x.view(np.int8)
            x_pooled = maxpool2d(x_signed, layer["kernel"], layer["stride"])
            x = x_pooled.view(np.uint8)
            intermediates[name] = x.copy()

        elif layer["type"] == "fc":
            x_flat = x.flatten() if x.ndim > 1 else x
            if x_flat.dtype == np.int8:
                x_flat = x_flat.view(np.uint8)
            out = hw_mvm(
                x_flat,
                layer["weight"],
                layer["bias"],
                layer["zp"],
                layer["mult"],
                layer["shift"],
                layer["relu"],
            )
            x = out
            intermediates[name] = x.copy()

    pred = int(np.argmax(x))
    return pred, intermediates


# ============================================================================
# 7. Hex export (same format as mnist_quantize.py)
# ============================================================================
def weight_to_chunk_hex(w_i8, tile_rows=TILE_ROWS, tile_cols=TILE_COLS):
    od, id_ = w_i8.shape
    n_ob = (od + tile_rows - 1) // tile_rows
    n_ib = (id_ + tile_cols - 1) // tile_cols
    lines = []
    for ob in range(n_ob):
        for ib in range(n_ib):
            for chunk in range(CHUNKS_PER_TILE):
                row = chunk // CHUNKS_PER_ROW
                cg = chunk % CHUNKS_PER_ROW
                word = 0
                for b in range(ELEMS_PER_CHUNK):
                    oi = ob * tile_rows + row
                    ii = ib * tile_cols + cg * ELEMS_PER_CHUNK + b
                    if oi < od and ii < id_:
                        word |= (int(w_i8[oi, ii]) & 0xFF) << (b * 8)
                lines.append(f"{word:08x}")
    return lines


def bias_hex(b):
    return [f"{int(v) & 0xFFFFFFFF:08x}" for v in b]


def input_hex(x):
    return [f"{int(v) & 0xFF:02x}" for v in x]


def int8_hex(x):
    return [f"{int(v) & 0xFF:02x}" for v in x]


def save_hex(lines, path):
    with open(path, "w") as f:
        for l in lines:
            f.write(l + "\n")


def export_qparams_npz(qparams, output_dir):
    """Raw INT8 matrices for the SW baseline (NumPy GEMV) and packed-conv driver.

    Keys per compute layer: {name}_weight, {name}_bias, {name}_zp/_mult/_shift.
    Conv weights kept 4D [C_out,C_in,K,K]; FC weights 2D [out,in].
    """
    npz = {}
    for l in qparams["layers"]:
        if l["type"] in ("conv", "fc"):
            name = l["name"]
            npz[f"{name}_weight"] = np.asarray(l["weight"]).astype(np.int8)
            npz[f"{name}_bias"] = np.asarray(l["bias"]).astype(np.int32)
            npz[f"{name}_mult"] = np.int32(l["mult"])
            npz[f"{name}_shift"] = np.int32(l["shift"])
            npz[f"{name}_zp"] = np.int32(l["zp"])
    path = os.path.join(output_dir, "lenet5_qparams.npz")
    np.savez(path, **npz)
    print(f"  Raw INT8 matrices saved to {path}")
    return path


# ============================================================================
# 8. Main
# ============================================================================
def main():
    parser = argparse.ArgumentParser(description="Generate lenet5_data from scratch")
    parser.add_argument(
        "--pretrained",
        type=str,
        default=None,
        help="Load this .pt instead of training (optional)",
    )
    parser.add_argument("--epochs", type=int, default=15)
    parser.add_argument(
        "--num-test",
        type=int,
        default=20,
        help="Number of test images to generate (default 20)",
    )
    parser.add_argument("--output-dir", type=str, default="lenet5_data")
    parser.add_argument("--save-model", type=str, default="lenet5.pt")
    parser.add_argument("--seed", type=int, default=42, help="Random seed (default 42)")
    args = parser.parse_args()

    device = "cuda" if torch.cuda.is_available() else "cpu"
    os.makedirs(args.output_dir, exist_ok=True)

    # ---- Train or load ----
    if args.pretrained and os.path.exists(args.pretrained):
        print(f"Loading pretrained model: {args.pretrained}")
        model = LeNet5()
        model.load_state_dict(torch.load(args.pretrained, map_location=device))
        float_acc = float("nan")
    else:
        model, float_acc = train_lenet5(args.epochs, device=device, seed=args.seed)
        torch.save(model.state_dict(), args.save_model)
        print(f"Model saved to {args.save_model}")

    model = model.to(device).eval()

    # ---- PTQ ----
    qparams = full_ptq_lenet5(model, device)

    # ---- INT8 accuracy on full test set ----
    print("\n" + "=" * 60)
    print("INT8 accuracy (bit-accurate)")
    print("=" * 60)
    transform_raw = transforms.ToTensor()
    test_set = datasets.MNIST(
        "./data", train=False, download=True, transform=transform_raw
    )

    correct_int8 = 0
    total = len(test_set)
    for i in range(total):
        img, label = test_set[i]
        img_u8 = np.clip(np.round(img.numpy().flatten() * 255), 0, 255).astype(np.uint8)
        pred, _ = int8_infer_lenet5(img_u8, qparams)
        if pred == label:
            correct_int8 += 1
    acc_int8 = 100.0 * correct_int8 / total
    acc_float_str = (
        f"{float_acc:.2f}"
        if isinstance(float_acc, float) and not np.isnan(float_acc)
        else "N/A (pretrained)"
    )
    print(f"  Float32: {acc_float_str}%")
    print(f"  INT8:    {acc_int8:.2f}% ({correct_int8}/{total})")

    # ---- Export hex (FPGA) ----
    print("\n" + "=" * 60)
    print("Exporting hex files (FPGA)")
    print("=" * 60)
    for layer in qparams["layers"]:
        name = layer["name"]
        if layer["type"] in ("conv", "fc"):
            w = layer["weight"]
            if w.ndim == 4:
                w = w.reshape(w.shape[0], -1)
            save_hex(
                weight_to_chunk_hex(w), f"{args.output_dir}/{name}_weight_tiles.hex"
            )
            save_hex(bias_hex(layer["bias"]), f"{args.output_dir}/{name}_bias.hex")

    compute_layers = [l for l in qparams["layers"] if l["type"] in ("conv", "fc")]
    qp_lines = []
    for l in compute_layers:
        qp_lines.append(f"{l['mult'] & 0xFFFFFFFF:08x}")
        qp_lines.append(f"{l['shift'] & 0xFFFFFFFF:08x}")
    save_hex(qp_lines, f"{args.output_dir}/quant_params.hex")

    zp_lines = [f"{l['zp'] & 0xFFFFFFFF:08x}" for l in compute_layers]
    save_hex(zp_lines, f"{args.output_dir}/zero_points.hex")
    print(f"  Weights/bias/quant/zp saved to {args.output_dir}/")

    # ---- Export raw INT8 matrices (SW baseline) ----
    export_qparams_npz(qparams, args.output_dir)

    # ---- Layer / model info ----
    with open(f"{args.output_dir}/layer_info.txt", "w") as f:
        for l in qparams["layers"]:
            if l["type"] == "conv":
                f.write(
                    f"{l['name']}: conv {l['C_in']}ch {l['K_h']}x{l['K_w']} -> {l['C_out']}ch "
                    f"stride={l['stride']} pad={l['padding']} mult={l['mult']} shift={l['shift']}\n"
                )
            elif l["type"] == "pool":
                f.write(
                    f"{l['name']}: maxpool {l['kernel']}x{l['kernel']} stride={l['stride']}\n"
                )
            elif l["type"] == "fc":
                f.write(
                    f"{l['name']}: fc {l['in_dim']}->{l['out_dim']} "
                    f"mult={l['mult']} shift={l['shift']} relu={l['relu']}\n"
                )
    with open(f"{args.output_dir}/model_info.txt", "w") as f:
        f.write("Model: LeNet-5 (Conv1->Pool->Conv2->Pool->FC3->FC4->FC5)\n")
        f.write(f"Float accuracy: {acc_float_str}%\n")
        f.write(f"INT8 accuracy: {acc_int8:.2f}%\n")
        f.write(f"Exported test images: {min(args.num_test, len(test_set))}\n")
    print(f"  Layer/model info saved to {args.output_dir}/")

    # ---- Export N test images ----
    print("\n" + "=" * 60)
    print(f"Exporting {min(args.num_test, len(test_set))} test images")
    print("=" * 60)
    img_dir = f"{args.output_dir}/test_images"
    os.makedirs(img_dir, exist_ok=True)
    n_export = min(args.num_test, len(test_set))
    export_correct = 0

    for i in range(n_export):
        img, label = test_set[i]
        img_u8 = np.clip(np.round(img.numpy().flatten() * 255), 0, 255).astype(np.uint8)
        pred, intermediates = int8_infer_lenet5(img_u8, qparams)
        if pred == label:
            export_correct += 1

        prefix = f"img_{i:04d}"
        save_hex(input_hex(img_u8), f"{img_dir}/{prefix}.hex")
        save_hex(int8_hex(intermediates["fc5"]), f"{img_dir}/{prefix}_fc5.hex")
        with open(f"{img_dir}/{prefix}_label.txt", "w") as f:
            f.write(f"{label}\n")
        with open(f"{img_dir}/{prefix}_pred.txt", "w") as f:
            f.write(f"{pred}\n")
        if n_export <= 50 or (i % 20 == 0):
            mark = "OK" if pred == label else "x"
            print(f"  [{i:04d}] label={label}, pred={pred} {mark}")

    print(
        f"\n  Exported {n_export} images, INT8 acc on them: "
        f"{100.0 * export_correct / n_export:.1f}%"
    )

    # ---- Summary ----
    print("\n" + "=" * 60)
    print("SUMMARY")
    print("=" * 60)
    print(f"  Float32 accuracy: {acc_float_str}%")
    print(f"  INT8 accuracy:    {acc_int8:.2f}%")
    print(f"  Test images:      {n_export}")
    print(f"  Output dir:       {args.output_dir}/")
    print(f"  npz (SW baseline):{args.output_dir}/lenet5_qparams.npz")
    print("=" * 60)


if __name__ == "__main__":
    main()
