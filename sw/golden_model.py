#!/usr/bin/env python3
"""
golden_model.py — Bit-accurate INT8 inference golden model for CIM SoC.

This model exactly replicates the hardware behavior:
  1. Input: UINT8 → subtract zero_point → x_eff (unsigned 9-bit, clamped)
  2. MAC: x_eff (unsigned) × weight (signed INT8) → accumulate in INT32
  3. Bias: add signed INT32 bias
  4. Activation: ReLU (or none)
  5. Requantize: INT32 → INT8 via multiply-shift with rounding

Usage:
  python golden_model.py                                    # self-test
  python golden_model.py --mnist-e2e                        # generate MNIST hex
  python golden_model.py --mnist-e2e --output-dir path/     # custom output dir

This is the single source of truth for verifying RTL correctness.
"""

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
# Core functions — must match hardware exactly
# ============================================================================


def apply_zero_point(x_uint8: np.ndarray, zero_point: int) -> np.ndarray:
    """Subtract zero point from UINT8 input, clamp to [0, 511]."""
    x_eff = x_uint8.astype(np.int32) - zero_point
    x_eff = np.clip(x_eff, 0, 511)
    return x_eff.astype(np.uint16)


def cim_mvm(x_eff: np.ndarray, weight_int8: np.ndarray) -> np.ndarray:
    """Matrix-vector multiply: out = W @ x_eff, returns INT32."""
    w = weight_int8.astype(np.int32)
    x = x_eff.astype(np.int32)
    return w @ x


def add_bias(acc: np.ndarray, bias_int32: np.ndarray) -> np.ndarray:
    return acc + bias_int32.astype(np.int32)


def relu(x: np.ndarray) -> np.ndarray:
    return np.maximum(x, 0)


def requantize_int32_to_int8(x: np.ndarray, mult: int, rshift: int) -> np.ndarray:
    """
    Requantize INT32 → INT8 with multiply-shift and rounding.
    Matches cim_pkg::requantize() exactly.
    """
    result = np.zeros(len(x), dtype=np.int8)
    for i in range(len(x)):
        prod = int(x[i]) * int(mult)
        if rshift == 0:
            shifted = prod
        else:
            shifted = (prod + (1 << (rshift - 1))) >> rshift
        shifted = max(-128, min(127, shifted))
        result[i] = np.int8(shifted)
    return result


# ============================================================================
# Full layer inference
# ============================================================================


def infer_layer(
    input_uint8,
    weight_int8,
    bias_int32,
    zero_point=-128,
    requant_mult=1,
    requant_shift=0,
    activation="relu",
):
    """Run one FC layer, return dict with all intermediates."""
    x_eff = apply_zero_point(input_uint8, zero_point)
    acc = cim_mvm(x_eff, weight_int8)
    acc_bias = add_bias(acc, bias_int32)

    if activation == "relu":
        activated = relu(acc_bias)
    else:
        activated = acc_bias

    output = requantize_int32_to_int8(activated, requant_mult, requant_shift)
    pred_class = int(np.argmax(output))

    return {
        "x_eff": x_eff,
        "acc": acc,
        "acc_bias": acc_bias,
        "activated": activated,
        "output": output,
        "pred_class": pred_class,
    }


def infer_mlp(input_uint8, layers):
    """Run multi-layer MLP inference."""
    x = input_uint8
    results = []
    for layer in layers:
        result = infer_layer(
            input_uint8=x,
            weight_int8=layer["weight"],
            bias_int32=layer["bias"],
            zero_point=layer.get("zp", -128),
            requant_mult=layer.get("mult", 1),
            requant_shift=layer.get("shift", 0),
            activation=layer.get("act", "relu"),
        )
        results.append(result)
        x = result["output"].view(np.uint8)
    return {
        "layers": results,
        "final_output": results[-1]["output"],
        "pred_class": results[-1]["pred_class"],
    }


# ============================================================================
# Hex file generation for RTL $readmemh
# ============================================================================


def weight_to_chunk_hex(weight_int8, tile_rows=TILE_ROWS, tile_cols=TILE_COLS):
    """
    Pack weight matrix into tile-packed 32-bit chunk hex lines.
    Output order: tile 0 chunk 0, tile 0 chunk 1, ..., tile N chunk 63
    Each line is one 32-bit hex word (8 hex chars).

    Tile packing:
      tile[ob][ib] where tile_addr = ob * n_ib + ib
      Within a tile, flatten row-major: flat[r*tile_cols + c]
      chunk_idx maps to: row = chunk_idx // chunks_per_row
                         col_group = chunk_idx % chunks_per_row
      Each chunk = 4 consecutive INT8 bytes in the row
    """
    out_dim, in_dim = weight_int8.shape
    n_ob = (out_dim + tile_rows - 1) // tile_rows
    n_ib = (in_dim + tile_cols - 1) // tile_cols
    chunks_per_row = tile_cols // ELEMS_PER_CHUNK  # 4
    chunks_per_tile = tile_rows * chunks_per_row  # 64

    lines = []
    for ob in range(n_ob):
        for ib in range(n_ib):
            for chunk in range(chunks_per_tile):
                row = chunk // chunks_per_row
                col_group = chunk % chunks_per_row
                word = 0
                for b in range(ELEMS_PER_CHUNK):  # 4 bytes per chunk
                    c = col_group * ELEMS_PER_CHUNK + b
                    r = row
                    oi = ob * tile_rows + r
                    ii = ib * tile_cols + c
                    if oi < out_dim and ii < in_dim:
                        val = int(weight_int8[oi, ii]) & 0xFF
                    else:
                        val = 0
                    word |= val << (b * 8)
                lines.append(f"{word:08x}")  # python 3.6+
                # lines.append("{:0.8x}".format(word))  # python 3.5-
    return lines


def bias_to_hex(bias_int32):
    """Pack INT32 bias → hex lines (one per element)."""
    return [f"{int(b) & 0xFFFFFFFF:08x}" for b in bias_int32]


def input_to_hex(input_uint8):
    """Pack UINT8 input → hex lines (one byte per line, zero-padded to 8 chars)."""
    return [f"{int(v) & 0xFF:02x}" for v in input_uint8]


def int8_to_hex(arr_int8):
    """Pack signed INT8 array → hex lines (as unsigned byte)."""
    return [f"{int(v) & 0xFF:02x}" for v in arr_int8]


def save_hex(lines, filepath):
    with open(filepath, "w") as f:
        for line in lines:
            f.write(line + "\n")
    print(f"  Saved {filepath} ({len(lines)} lines)")


# ============================================================================
# MNIST E2E hex generation
# ============================================================================


def generate_mnist_e2e(output_dir, seed=42):
    """
    Generate random MNIST-like 784→128→10 model and test data.
    Writes all hex files needed by tb_mnist_e2e.sv.
    """
    np.random.seed(seed)
    os.makedirs(output_dir, exist_ok=True)

    print("=" * 60)
    print("Generating MNIST E2E golden data")
    print(f"Output dir: {output_dir}")
    print("=" * 60)

    # ---- Model parameters ----
    w1 = np.random.randint(-128, 127, (128, 784), dtype=np.int8)
    b1 = np.random.randint(-5000, 5000, 128, dtype=np.int32)
    w2 = np.random.randint(-128, 127, (10, 128), dtype=np.int8)
    b2 = np.random.randint(-5000, 5000, 10, dtype=np.int32)

    # ---- Test image (random) ----
    img = np.random.randint(0, 255, 784, dtype=np.uint8)

    # ---- Calibrate quantization parameters from actual data ----
    # Run a "calibration" pass to find accumulator ranges,
    # then compute mult/shift that map the range to [-128, 127].
    # This is what real PTQ (post-training quantization) does.
    def calibrate_requant(acc_values, shift=16):
        """Compute (mult, shift) that maps max(abs(acc)) → 127."""
        max_abs = max(abs(int(acc_values.max())), abs(int(acc_values.min())), 1)
        scale = 127.0 / max_abs
        mult = int(round(scale * (1 << shift)))
        mult = max(1, mult)  # at least 1
        return mult, shift

    # Calibrate FC1
    x_eff_cal = np.clip(img.astype(np.int32) - (-128), 0, 511).astype(np.int32)
    acc1_cal = w1.astype(np.int32) @ x_eff_cal + b1.astype(np.int32)
    relu1_cal = np.maximum(acc1_cal, 0)
    fc1_mult, fc1_shift = calibrate_requant(relu1_cal, shift=16)

    # Run FC1 with calibrated params to get FC1 output for FC2 calibration
    fc1_out_cal = np.zeros(128, dtype=np.int8)
    for i in range(128):
        v = int(relu1_cal[i])
        prod = v * fc1_mult
        shifted = (
            (prod + (1 << (fc1_shift - 1))) >> fc1_shift if fc1_shift > 0 else prod
        )
        fc1_out_cal[i] = np.int8(max(-128, min(127, shifted)))

    # Calibrate FC2
    fc2_in_cal = fc1_out_cal.view(np.uint8)
    x_eff2_cal = np.clip(fc2_in_cal.astype(np.int32) - 0, 0, 511).astype(np.int32)
    acc2_cal = w2.astype(np.int32) @ x_eff2_cal + b2.astype(np.int32)
    fc2_mult, fc2_shift = calibrate_requant(acc2_cal, shift=16)

    print(f"  Calibrated FC1: mult={fc1_mult}, shift={fc1_shift}")
    print(f"    acc range: [{acc1_cal.min()}, {acc1_cal.max()}]")
    print(f"  Calibrated FC2: mult={fc2_mult}, shift={fc2_shift}")
    print(f"    acc range: [{acc2_cal.min()}, {acc2_cal.max()}]")

    # ---- Run inference ----
    mlp_result = infer_mlp(
        img,
        [
            {
                "weight": w1,
                "bias": b1,
                "zp": -128,
                "mult": fc1_mult,
                "shift": fc1_shift,
                "act": "relu",
            },
            {
                "weight": w2,
                "bias": b2,
                "zp": 0,
                "mult": fc2_mult,
                "shift": fc2_shift,
                "act": "none",
            },
        ],
    )

    fc1_out = mlp_result["layers"][0]["output"]
    fc2_out = mlp_result["final_output"]
    pred = mlp_result["pred_class"]

    print(f"\nFC1 output (first 10): {fc1_out[:10]}")
    print(f"FC2 output (all 10):   {fc2_out}")
    print(f"Predicted class: {pred}")

    # ---- Write hex files ----
    print("\nWriting hex files...")

    # Weight tiles (flat 32-bit chunks)
    save_hex(weight_to_chunk_hex(w1), os.path.join(output_dir, "fc1_weight_tiles.hex"))
    save_hex(weight_to_chunk_hex(w2), os.path.join(output_dir, "fc2_weight_tiles.hex"))

    # Bias
    save_hex(bias_to_hex(b1), os.path.join(output_dir, "fc1_bias.hex"))
    save_hex(bias_to_hex(b2), os.path.join(output_dir, "fc2_bias.hex"))

    # Input image
    save_hex(input_to_hex(img), os.path.join(output_dir, "input_image.hex"))

    # Expected outputs
    save_hex(int8_to_hex(fc1_out), os.path.join(output_dir, "fc1_output.hex"))
    save_hex(int8_to_hex(fc2_out), os.path.join(output_dir, "fc2_output.hex"))

    # Expected class (single line)
    save_hex([f"{pred:08x}"], os.path.join(output_dir, "expected_class.hex"))

    # Quant params: fc1_mult, fc1_shift, fc2_mult, fc2_shift
    save_hex(
        [
            f"{fc1_mult & 0xFFFFFFFF:08x}",
            f"{fc1_shift & 0xFFFFFFFF:08x}",
            f"{fc2_mult & 0xFFFFFFFF:08x}",
            f"{fc2_shift & 0xFFFFFFFF:08x}",
        ],
        os.path.join(output_dir, "quant_params.hex"),
    )

    # ---- Verification: sanity check layer 1 manually ----
    x_eff = np.clip(img.astype(np.int32) - (-128), 0, 511)
    manual_acc0 = np.sum(x_eff * w1[0].astype(np.int32)) + b1[0]
    assert mlp_result["layers"][0]["acc_bias"][0] == manual_acc0, (
        f"Manual check failed: {mlp_result['layers'][0]['acc_bias'][0]} != {manual_acc0}"
    )
    print("\nManual sanity check: PASS")

    # ---- Summary ----
    n_ob1 = (128 + TILE_ROWS - 1) // TILE_ROWS
    n_ib1 = (784 + TILE_COLS - 1) // TILE_COLS
    n_ob2 = (10 + TILE_ROWS - 1) // TILE_ROWS
    n_ib2 = (128 + TILE_COLS - 1) // TILE_COLS
    print(f"\nFC1: {n_ob1 * n_ib1} tiles ({n_ob1}×{n_ib1})")
    print(f"FC2: {n_ob2 * n_ib2} tiles ({n_ob2}×{n_ib2})")
    print(f"FC1 weight hex: {n_ob1 * n_ib1 * CHUNKS_PER_TILE} lines")
    print(f"FC2 weight hex: {n_ob2 * n_ib2 * CHUNKS_PER_TILE} lines")
    print(f"\n>>> MNIST E2E DATA GENERATION COMPLETE <<<")


# ============================================================================
# im2col — Convolution → MVM mapping
# ============================================================================


def im2col_explicit(feature_map, kernel_h, kernel_w, stride=1, padding=0):
    """
    Explicit im2col: physically rearrange feature map patches into a matrix.

    Args:
        feature_map: shape [C_in, H, W], UINT8
        kernel_h, kernel_w: convolution kernel spatial size
        stride: convolution stride
        padding: zero-padding (symmetric)

    Returns:
        col_matrix: shape [C_in * kernel_h * kernel_w, out_h * out_w], UINT8
                    Each column is one flattened receptive field patch.
        out_h, out_w: output spatial dimensions

    Usage:
        col = im2col_explicit(feat, 3, 3, stride=1, padding=1)
        # Then: output = weight.reshape(C_out, -1) @ col  → shape [C_out, out_h*out_w]
        # Feed each column of `col` to CIM as an input vector, weight stays the same.
    """
    C_in, H, W = feature_map.shape

    if padding > 0:
        padded = np.zeros(
            (C_in, H + 2 * padding, W + 2 * padding), dtype=feature_map.dtype
        )
        padded[:, padding : padding + H, padding : padding + W] = feature_map
    else:
        padded = feature_map

    H_pad, W_pad = padded.shape[1], padded.shape[2]
    out_h = (H_pad - kernel_h) // stride + 1
    out_w = (W_pad - kernel_w) // stride + 1
    col_len = C_in * kernel_h * kernel_w

    col_matrix = np.zeros((col_len, out_h * out_w), dtype=feature_map.dtype)

    col_idx = 0
    for oh in range(out_h):
        for ow in range(out_w):
            h_start = oh * stride
            w_start = ow * stride
            patch = padded[
                :, h_start : h_start + kernel_h, w_start : w_start + kernel_w
            ]
            col_matrix[:, col_idx] = patch.flatten()
            col_idx += 1

    return col_matrix, out_h, out_w


def im2col_implicit_addr_gen(C_in, H, W, kernel_h, kernel_w, stride=1, padding=0):
    """
    Implicit im2col: generate address mapping instead of copying data.

    Returns a list of (out_h * out_w) entries, each entry is a list of
    (C_in * kernel_h * kernel_w) flat source addresses into the
    (optionally padded) feature map, or -1 for zero-padding positions.

    Hardware can use this address table to read the input buffer in the
    correct order without physically rearranging data.

    Args:
        C_in, H, W: input feature map dimensions
        kernel_h, kernel_w: kernel spatial size
        stride, padding: convolution parameters

    Returns:
        addr_table: list of lists, shape [n_output_pixels][col_len]
                    Each inner list has col_len source addresses.
                    -1 means zero (padding position).
        out_h, out_w: output spatial dimensions

    Usage on HW (pseudocode):
        for each output pixel p:
            for i in range(col_len):
                addr = addr_table[p][i]
                x_val = (feat_buf[addr] if addr >= 0 else 0)
            # feed x_val sequence to CIM tile
    """
    H_pad = H + 2 * padding
    W_pad = W + 2 * padding
    out_h = (H_pad - kernel_h) // stride + 1
    out_w = (W_pad - kernel_w) // stride + 1
    col_len = C_in * kernel_h * kernel_w

    addr_table = []
    for oh in range(out_h):
        for ow in range(out_w):
            addrs = []
            for c in range(C_in):
                for kh in range(kernel_h):
                    for kw in range(kernel_w):
                        h_pos = oh * stride + kh - padding
                        w_pos = ow * stride + kw - padding
                        if 0 <= h_pos < H and 0 <= w_pos < W:
                            # flat address in original [C_in, H, W] layout
                            addrs.append(c * H * W + h_pos * W + w_pos)
                        else:
                            addrs.append(-1)  # padding → zero
            addr_table.append(addrs)

    return addr_table, out_h, out_w


def im2col_apply_implicit(feature_map, addr_table, col_len, n_pixels):
    """
    Build col_matrix from address table (implicit im2col).
    This is what the hardware does: read feat_buf[addr] for each position.
    """
    feat_flat = feature_map.flatten()
    col = np.zeros((col_len, n_pixels), dtype=feature_map.dtype)
    for p in range(n_pixels):
        for i, addr in enumerate(addr_table[p]):
            col[i, p] = feat_flat[addr] if addr >= 0 else 0
    return col


def infer_conv_layer(
    feature_map,
    weight_4d,
    bias_int32,
    stride=1,
    padding=0,
    zero_point=-128,
    requant_mult=1,
    requant_shift=0,
    activation="relu",
    mode="explicit",
):
    """
    Run one Conv2D layer through im2col → CIM MVM pipeline.

    Args:
        feature_map: [C_in, H, W] UINT8
        weight_4d:   [C_out, C_in, K_h, K_w] INT8
        bias_int32:  [C_out] INT32
        stride, padding: conv params
        zero_point, requant_mult, requant_shift: quantization
        activation: "relu" or "none"
        mode: "explicit" — physically rearrange data (PS-side NumPy)
              "implicit" — address-table driven (HW-side addr gen)

    Returns:
        output_map: [C_out, out_h, out_w] INT8
        details dict with intermediates
    """
    C_out, C_in, K_h, K_w = weight_4d.shape
    _, H, W = feature_map.shape
    col_len = C_in * K_h * K_w

    # Reshape weight: [C_out, C_in*K_h*K_w]
    weight_2d = weight_4d.reshape(C_out, col_len).astype(np.int8)

    print(
        f"  Conv: feat[{C_in},{H},{W}] * weight[{C_out},{C_in},{K_h},{K_w}]"
        f"  stride={stride} pad={padding}  mode={mode}"
    )

    # ---- im2col ----
    if mode == "explicit":
        col_matrix, out_h, out_w = im2col_explicit(
            feature_map, K_h, K_w, stride, padding
        )
    elif mode == "implicit":
        addr_table, out_h, out_w = im2col_implicit_addr_gen(
            C_in, H, W, K_h, K_w, stride, padding
        )
        n_pixels = out_h * out_w
        col_matrix = im2col_apply_implicit(feature_map, addr_table, col_len, n_pixels)
    else:
        raise ValueError(f"Unknown mode: {mode!r}. Use 'explicit' or 'implicit'.")

    n_pixels = out_h * out_w
    print(
        f"  Output spatial: {out_h}×{out_w} = {n_pixels} pixels, "
        f"col_len={col_len}, MVMs={n_pixels}"
    )

    # ---- Per-pixel MVM through CIM pipeline ----
    output_flat = np.zeros((C_out, n_pixels), dtype=np.int8)
    for p in range(n_pixels):
        input_vec = col_matrix[:, p]  # [col_len] UINT8
        result = infer_layer(
            input_uint8=input_vec,
            weight_int8=weight_2d,
            bias_int32=bias_int32,
            zero_point=zero_point,
            requant_mult=requant_mult,
            requant_shift=requant_shift,
            activation=activation,
        )
        output_flat[:, p] = result["output"]

    output_map = output_flat.reshape(C_out, out_h, out_w)

    return output_map, {
        "col_matrix_shape": col_matrix.shape,
        "out_h": out_h,
        "out_w": out_w,
        "n_mvm": n_pixels,
        "mode": mode,
    }


def im2col_demo(mode="both"):
    """
    Demo: run Conv inference with explicit, implicit, or both modes.

    mode: "explicit", "implicit", or "both" (default)
    """
    print("=" * 60)
    print(f"im2col Conv Inference Demo  (mode={mode})")
    print("=" * 60)

    np.random.seed(123)

    # Small Conv layer: 3×8×8 input, 16 output channels, 3×3 kernel
    C_in, H, W = 3, 8, 8
    C_out, K = 16, 3
    stride, pad = 1, 1
    ZP, MULT, SHIFT = -128, 1073741824, 30

    feat = np.random.randint(0, 255, (C_in, H, W), dtype=np.uint8)
    weight = np.random.randint(-128, 127, (C_out, C_in, K, K), dtype=np.int8)
    bias = np.random.randint(-500, 500, C_out, dtype=np.int32)

    modes_to_run = ["explicit", "implicit"] if mode == "both" else [mode]
    results = {}

    for m in modes_to_run:
        print(f"\n--- Running with mode='{m}' ---")
        out_map, info = infer_conv_layer(
            feat,
            weight,
            bias,
            stride=stride,
            padding=pad,
            zero_point=ZP,
            requant_mult=MULT,
            requant_shift=SHIFT,
            activation="relu",
            mode=m,
        )
        results[m] = out_map
        print(f"  Output shape: {out_map.shape}")
        print(f"  Output[0,:2,:2]:\n    {out_map[0, :2, :2]}")
        print(f"  Total MVMs: {info['n_mvm']}")

    # Compare if both were run
    if len(results) == 2:
        if np.array_equal(results["explicit"], results["implicit"]):
            print(
                f"\n  Explicit vs Implicit output: MATCH ✓ "
                f"({np.prod(results['explicit'].shape)} elements)"
            )
        else:
            diff = np.sum(results["explicit"] != results["implicit"])
            print(f"\n  Explicit vs Implicit: {diff} MISMATCHES!")

    print("\n>>> im2col DEMO COMPLETE <<<")


# ============================================================================
# Self-test (original)
# ============================================================================


def self_test():
    print("=" * 60)
    print("Golden Model Self-Test")
    print("=" * 60)

    np.random.seed(42)
    IN_DIM, OUT_DIM = 32, 16
    ZP, MULT, SHIFT = -128, 1073741824, 30

    weight = np.random.randint(-128, 127, (OUT_DIM, IN_DIM), dtype=np.int8)
    bias = np.random.randint(-1000, 1000, OUT_DIM, dtype=np.int32)
    x = np.random.randint(0, 255, IN_DIM, dtype=np.uint8)

    result = infer_layer(x, weight, bias, ZP, MULT, SHIFT, "relu")

    print(f"\nInput (first 8):  {x[:8]}")
    print(f"x_eff (first 8):  {result['x_eff'][:8]}")
    print(f"Output (all):     {result['output']}")
    print(f"Pred class:       {result['pred_class']}")

    x_eff = np.clip(x.astype(np.int32) - ZP, 0, 511)
    manual_acc = np.sum(x_eff * weight[0].astype(np.int32)) + bias[0]
    assert result["acc_bias"][0] == manual_acc, "ACC mismatch!"
    print("Manual check: PASS")
    print("\n>>> SELF-TEST PASSED <<<")


# ============================================================================
# Main
# ============================================================================

USAGE = """
CIM SoC Golden Model — Usage
============================================================
  python golden_model.py                          Show this usage info
  python golden_model.py --self-test              Run bit-accurate FC self-test
  python golden_model.py --mnist-e2e              Generate MNIST 784→128→10 hex
  python golden_model.py --im2col-demo            Conv demo (both modes)
  python golden_model.py --im2col-demo --im2col-mode explicit
  python golden_model.py --im2col-demo --im2col-mode implicit

Options:
  --im2col-mode MODE  "explicit", "implicit", or "both" (default: both)
  --output-dir DIR    Output directory for hex files  (default: data_e2e)
  --seed N            Random seed                      (default: 42)

Examples:
  python golden_model.py --mnist-e2e --output-dir ../hw/sim/tb_mnist_e2e/data_e2e
  python golden_model.py --im2col-demo --im2col-mode explicit
============================================================
"""

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="CIM SoC Golden Model",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=USAGE,
    )
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument(
        "--mnist-e2e", action="store_true", help="Generate MNIST E2E hex files"
    )
    parser.add_argument(
        "--im2col-demo", action="store_true", help="Run Conv im2col demo"
    )
    parser.add_argument(
        "--im2col-mode",
        type=str,
        default="both",
        choices=["explicit", "implicit", "both"],
        help="im2col mode (default: both)",
    )
    parser.add_argument("--output-dir", type=str, default="data_e2e")
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    if args.mnist_e2e:
        generate_mnist_e2e(args.output_dir, args.seed)
    elif args.self_test:
        self_test()
    elif args.im2col_demo:
        im2col_demo(mode=args.im2col_mode)
    else:
        print(USAGE)
