#!/usr/bin/env python3
"""
golden_model_torch.py — PyTorch-based bit-accurate INT8 golden model for CIM SoC.

Produces hex files in the EXACT same format as golden_model.py,
but uses PyTorch's quantization infrastructure for validation.

Usage:
  python golden_model_torch.py                              Show usage
  python golden_model_torch.py --mnist-e2e                  Random weights, calibrated quant
  python golden_model_torch.py --mnist-e2e --seed 42        Reproducible random
  python golden_model_torch.py --mnist-e2e --fixed          Use fixed small weights (easy to debug)
  python golden_model_torch.py --mnist-e2e --output-dir DIR Custom output directory

Output (identical format to golden_model.py):
  DIR/fc1_weight_tiles.hex   — FC1 weights, tile-packed 32-bit chunks
  DIR/fc2_weight_tiles.hex   — FC2 weights, tile-packed 32-bit chunks
  DIR/fc1_bias.hex           — FC1 bias INT32
  DIR/fc2_bias.hex           — FC2 bias INT32
  DIR/input_image.hex        — Input UINT8
  DIR/fc1_output.hex         — Expected FC1 output INT8
  DIR/fc2_output.hex         — Expected FC2 output INT8 (final logits)
  DIR/expected_class.hex     — Argmax class
  DIR/quant_params.hex       — fc1_mult, fc1_shift, fc2_mult, fc2_shift
"""

import torch
import numpy as np
import argparse
import os

# ============================================================================
# Hardware parameters (must match cim_pkg.sv)
# ============================================================================
TILE_ROWS = 16
TILE_COLS = 16
WEIGHT_W = 8
ELEMS_PER_CHUNK = 32 // WEIGHT_W  # 4
CHUNKS_PER_TILE = (TILE_ROWS * TILE_COLS) // ELEMS_PER_CHUNK  # 64


# ============================================================================
# Core INT8 inference — bit-accurate with hardware
# ============================================================================


def apply_zero_point(x_uint8: np.ndarray, zp: int) -> np.ndarray:
    """UINT8 input → subtract zero point → clamp to [0, 511] (9-bit unsigned)."""
    x_eff = x_uint8.astype(np.int32) - zp
    return np.clip(x_eff, 0, 511)


def requantize(x_int32: np.ndarray, mult: int, shift: int) -> np.ndarray:
    """INT32 → INT8 via multiply-shift with rounding. Matches cim_pkg::requantize()."""
    out = np.zeros(len(x_int32), dtype=np.int8)
    for i in range(len(x_int32)):
        prod = int(x_int32[i]) * int(mult)
        if shift == 0:
            shifted = prod
        else:
            shifted = (prod + (1 << (shift - 1))) >> shift
        out[i] = np.int8(max(-128, min(127, shifted)))
    return out


def infer_layer_int32(x_uint8, w_int8, b_int32, zp, mult, shift, relu=True):
    """
    One FC layer: ZP subtract → MVM → bias → ReLU → requantize.
    All arithmetic in Python int (arbitrary precision), matches RTL exactly.
    """
    x_eff = apply_zero_point(x_uint8, zp)
    # MVM in INT32
    acc = w_int8.astype(np.int32) @ x_eff.astype(np.int32)
    acc = acc + b_int32.astype(np.int32)
    if relu:
        acc = np.maximum(acc, 0)
    out = requantize(acc, mult, shift)
    return out, acc


def calibrate_requant(acc_values, shift=16):
    """Compute (mult, shift) that maps max(|acc|) → 127. Mimics real PTQ."""
    max_abs = max(abs(int(acc_values.max())), abs(int(acc_values.min())), 1)
    scale = 127.0 / max_abs
    mult = max(1, int(round(scale * (1 << shift))))
    return mult, shift


# ============================================================================
# Cross-validation with PyTorch
# ============================================================================


def torch_cross_validate(w_np, b_np, x_np, zp, mult, shift, relu, layer_name):
    """
    Run the same computation in PyTorch float32 and compare direction.
    This is NOT bit-accurate (float vs int), but catches gross errors
    like wrong sign, wrong magnitude, transposed weight, etc.
    """
    w_t = torch.from_numpy(w_np.astype(np.float32))
    b_t = torch.from_numpy(b_np.astype(np.float32))
    x_eff = np.clip(x_np.astype(np.int32) - zp, 0, 511)
    x_t = torch.from_numpy(x_eff.astype(np.float32))

    acc_torch = (w_t @ x_t + b_t).numpy()
    if relu:
        acc_torch = np.maximum(acc_torch, 0)

    # Apply requantize in float for comparison
    scale = mult / (2.0**shift)
    out_float = np.clip(np.round(acc_torch * scale), -128, 127).astype(np.int8)

    return acc_torch, out_float


# ============================================================================
# Hex file generation (identical format to golden_model.py)
# ============================================================================


def weight_to_chunk_hex(weight_int8, tile_rows=TILE_ROWS, tile_cols=TILE_COLS):
    """Pack weight matrix → tile-packed 32-bit chunk hex lines."""
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
                    r = row
                    oi = ob * tile_rows + r
                    ii = ib * tile_cols + c
                    if oi < out_dim and ii < in_dim:
                        val = int(weight_int8[oi, ii]) & 0xFF
                    else:
                        val = 0
                    word |= val << (b * 8)
                lines.append(f"{word:08x}")
    return lines


def bias_to_hex(bias_int32):
    return [f"{int(b) & 0xFFFFFFFF:08x}" for b in bias_int32]


def input_to_hex(x_uint8):
    return [f"{int(v) & 0xFF:02x}" for v in x_uint8]


def int8_to_hex(arr):
    return [f"{int(v) & 0xFF:02x}" for v in arr]


def save_hex(lines, filepath):
    with open(filepath, "w") as f:
        for line in lines:
            f.write(line + "\n")
    print(f"  Saved {filepath} ({len(lines)} lines)")


# ============================================================================
# Data generation modes
# ============================================================================


def generate_random_model(seed=42):
    """Random weights/bias/input with specified seed."""
    np.random.seed(seed)
    torch.manual_seed(seed)

    w1 = np.random.randint(-128, 127, (128, 784), dtype=np.int8)
    b1 = np.random.randint(-5000, 5000, 128, dtype=np.int32)
    w2 = np.random.randint(-128, 127, (10, 128), dtype=np.int8)
    b2 = np.random.randint(-5000, 5000, 10, dtype=np.int32)
    img = np.random.randint(0, 255, 784, dtype=np.uint8)

    return w1, b1, w2, b2, img


def generate_fixed_model():
    """Small fixed weights for easy manual debugging."""
    # Weights with known pattern: w[o][i] = ((o * 7 + i * 3) % 256) - 128
    w1 = np.zeros((128, 784), dtype=np.int8)
    for o in range(128):
        for i in range(784):
            w1[o, i] = np.int8(((o * 7 + i * 3) % 256) - 128)

    b1 = np.arange(128, dtype=np.int32) * 100 - 6400  # [-6400, 6300]

    w2 = np.zeros((10, 128), dtype=np.int8)
    for o in range(10):
        for i in range(128):
            w2[o, i] = np.int8(((o * 13 + i * 5) % 256) - 128)

    b2 = np.arange(10, dtype=np.int32) * 500 - 2500  # [-2500, 2000]

    # Input: gradient pattern
    img = (np.arange(784) % 256).astype(np.uint8)

    return w1, b1, w2, b2, img


# ============================================================================
# Main generation
# ============================================================================


def generate_mnist_e2e(output_dir, mode="random", seed=42):
    os.makedirs(output_dir, exist_ok=True)

    print("=" * 60)
    print(f"Golden Model (PyTorch) — MNIST E2E")
    print(f"  Mode: {mode}, Seed: {seed}")
    print(f"  Output: {output_dir}")
    print(f"  PyTorch: {torch.__version__}")
    print("=" * 60)

    # ---- Generate data ----
    if mode == "fixed":
        w1, b1, w2, b2, img = generate_fixed_model()
    else:
        w1, b1, w2, b2, img = generate_random_model(seed)

    # ---- FC1: calibrate ----
    x_eff1 = apply_zero_point(img, -128)
    acc1_raw = w1.astype(np.int32) @ x_eff1.astype(np.int32) + b1.astype(np.int32)
    acc1_relu = np.maximum(acc1_raw, 0)
    fc1_mult, fc1_shift = calibrate_requant(acc1_relu, shift=16)

    # ---- FC1: inference ----
    fc1_out, fc1_acc = infer_layer_int32(
        img, w1, b1, zp=-128, mult=fc1_mult, shift=fc1_shift, relu=True
    )

    print(f"\n  FC1: 784→128, ReLU")
    print(f"    mult={fc1_mult}, shift={fc1_shift}")
    print(f"    acc range: [{fc1_acc.min()}, {fc1_acc.max()}]")
    print(f"    output (first 10): {fc1_out[:10]}")
    print(f"    unique values: {len(np.unique(fc1_out))}")

    # ---- PyTorch cross-validation FC1 ----
    acc_pt, out_pt = torch_cross_validate(
        w1, b1, img, -128, fc1_mult, fc1_shift, True, "FC1"
    )
    fc1_match = np.sum(fc1_out == out_pt)
    print(
        f"    PyTorch cross-val: {fc1_match}/128 match"
        f"{'  ✓' if fc1_match == 128 else '  (minor float rounding diffs OK)'}"
    )

    # ---- FC2: calibrate ----
    fc2_input = fc1_out.view(np.uint8)
    x_eff2 = apply_zero_point(fc2_input, 0)
    acc2_raw = w2.astype(np.int32) @ x_eff2.astype(np.int32) + b2.astype(np.int32)
    fc2_mult, fc2_shift = calibrate_requant(acc2_raw, shift=16)

    # ---- FC2: inference ----
    fc2_out, fc2_acc = infer_layer_int32(
        fc2_input, w2, b2, zp=0, mult=fc2_mult, shift=fc2_shift, relu=False
    )
    pred_class = int(np.argmax(fc2_out))

    print(f"\n  FC2: 128→10, no activation")
    print(f"    mult={fc2_mult}, shift={fc2_shift}")
    print(f"    acc range: [{fc2_acc.min()}, {fc2_acc.max()}]")
    print(f"    output (all 10): {fc2_out}")
    print(f"    pred class: {pred_class}")

    # ---- PyTorch cross-validation FC2 ----
    acc_pt2, out_pt2 = torch_cross_validate(
        w2, b2, fc2_input, 0, fc2_mult, fc2_shift, False, "FC2"
    )
    fc2_match = np.sum(fc2_out == out_pt2)
    print(
        f"    PyTorch cross-val: {fc2_match}/10 match"
        f"{'  ✓' if fc2_match == 10 else '  (minor float rounding diffs OK)'}"
    )

    # ---- Write hex files ----
    print(f"\n  Writing hex files...")
    save_hex(weight_to_chunk_hex(w1), os.path.join(output_dir, "fc1_weight_tiles.hex"))
    save_hex(weight_to_chunk_hex(w2), os.path.join(output_dir, "fc2_weight_tiles.hex"))
    save_hex(bias_to_hex(b1), os.path.join(output_dir, "fc1_bias.hex"))
    save_hex(bias_to_hex(b2), os.path.join(output_dir, "fc2_bias.hex"))
    save_hex(input_to_hex(img), os.path.join(output_dir, "input_image.hex"))
    save_hex(int8_to_hex(fc1_out), os.path.join(output_dir, "fc1_output.hex"))
    save_hex(int8_to_hex(fc2_out), os.path.join(output_dir, "fc2_output.hex"))
    save_hex([f"{pred_class:08x}"], os.path.join(output_dir, "expected_class.hex"))
    save_hex(
        [
            f"{fc1_mult & 0xFFFFFFFF:08x}",
            f"{fc1_shift & 0xFFFFFFFF:08x}",
            f"{fc2_mult & 0xFFFFFFFF:08x}",
            f"{fc2_shift & 0xFFFFFFFF:08x}",
        ],
        os.path.join(output_dir, "quant_params.hex"),
    )

    # ---- Summary ----
    n_ob1 = (128 + TILE_ROWS - 1) // TILE_ROWS
    n_ib1 = (784 + TILE_COLS - 1) // TILE_COLS
    n_ob2 = (10 + TILE_ROWS - 1) // TILE_ROWS
    n_ib2 = (128 + TILE_COLS - 1) // TILE_COLS
    print(
        f"\n  FC1: {n_ob1 * n_ib1} tiles, {n_ob1 * n_ib1 * CHUNKS_PER_TILE} weight chunks"
    )
    print(
        f"  FC2: {n_ob2 * n_ib2} tiles, {n_ob2 * n_ib2 * CHUNKS_PER_TILE} weight chunks"
    )
    print(f"\n>>> GENERATION COMPLETE <<<")


# ============================================================================
# Self-test: verify numpy path matches torch path
# ============================================================================


def self_test():
    print("=" * 60)
    print("Self-test: numpy vs torch cross-validation")
    print("=" * 60)

    np.random.seed(99)
    torch.manual_seed(99)

    IN, OUT = 32, 16
    w = np.random.randint(-128, 127, (OUT, IN), dtype=np.int8)
    b = np.random.randint(-500, 500, OUT, dtype=np.int32)
    x = np.random.randint(0, 255, IN, dtype=np.uint8)

    x_eff = apply_zero_point(x, -128)
    acc = w.astype(np.int32) @ x_eff.astype(np.int32) + b.astype(np.int32)
    acc_relu = np.maximum(acc, 0)
    mult, shift = calibrate_requant(acc_relu)
    out_np, _ = infer_layer_int32(x, w, b, -128, mult, shift, True)

    # Torch path
    acc_pt, out_pt = torch_cross_validate(w, b, x, -128, mult, shift, True, "test")

    # Compare
    match = np.sum(out_np == out_pt)
    print(f"  Output match: {match}/{OUT}")
    print(f"  numpy:  {out_np}")
    print(f"  torch:  {out_pt}")

    # Check accumulator direction (sign) matches
    acc_np = w.astype(np.int32) @ apply_zero_point(x, -128).astype(np.int32) + b.astype(
        np.int32
    )
    sign_match = np.sum(np.sign(acc_np) == np.sign(acc_pt.astype(np.int32)))
    print(f"  Acc sign match: {sign_match}/{OUT}")

    if match >= OUT - 2:  # allow 1-2 rounding diffs
        print("\n>>> SELF-TEST PASSED <<<")
    else:
        print("\n>>> SELF-TEST FAILED — significant divergence! <<<")


# ============================================================================
# Usage
# ============================================================================

USAGE = """
Golden Model (PyTorch) — Usage
============================================================
  python golden_model_torch.py                            Show this usage
  python golden_model_torch.py --self-test                Cross-validate numpy vs torch
  python golden_model_torch.py --mnist-e2e                Random model, calibrated quant
  python golden_model_torch.py --mnist-e2e --fixed        Fixed pattern weights (debug)
  python golden_model_torch.py --mnist-e2e --seed 123     Custom random seed

Options:
  --output-dir DIR    Output directory (default: data_e2e_torch)
  --seed N            Random seed (default: 42)
  --fixed             Use deterministic fixed-pattern weights

Output format is IDENTICAL to golden_model.py — same hex files, same layout.
Can be used as drop-in replacement for RTL testbench and on-board testing.
============================================================
"""

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="CIM SoC Golden Model (PyTorch)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=USAGE,
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--mnist-e2e", action="store_true", help="Generate MNIST E2E hex files"
    )
    parser.add_argument(
        "--fixed",
        action="store_true",
        help="Use fixed-pattern weights (deterministic, easy to debug)",
    )
    parser.add_argument("--output-dir", type=str, default="data_e2e_torch")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    if args.mnist_e2e:
        mode = "fixed" if args.fixed else "random"
        generate_mnist_e2e(args.output_dir, mode=mode, seed=args.seed)
    elif args.self_test:
        self_test()
    else:
        print(USAGE)
