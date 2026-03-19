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
  python golden_model.py                       # Run self-test with random data
  python golden_model.py --mnist weights.npz   # Run MNIST inference test

This is the single source of truth for verifying RTL correctness.
"""

import numpy as np
import argparse
import struct
import os


# ============================================================================
# Core functions — must match hardware exactly
# ============================================================================

def apply_zero_point(x_uint8: np.ndarray, zero_point: int) -> np.ndarray:
    """
    Subtract zero point from UINT8 input, clamp to [0, 511].
    Matches input_buffer.sv behavior.
    """
    x_eff = x_uint8.astype(np.int32) - zero_point
    x_eff = np.clip(x_eff, 0, 511)
    return x_eff.astype(np.uint16)  # 9-bit unsigned


def cim_mvm(x_eff: np.ndarray, weight_int8: np.ndarray) -> np.ndarray:
    """
    Matrix-vector multiply: out = W @ x_eff
    weight_int8: shape [OUT_DIM, IN_DIM], signed INT8
    x_eff: shape [IN_DIM], unsigned 9-bit
    Returns: shape [OUT_DIM], signed INT32
    """
    # Cast to INT32 for accumulation (matches PSUM_W=32 in hardware)
    w = weight_int8.astype(np.int32)
    x = x_eff.astype(np.int32)
    return w @ x  # INT32 result


def add_bias(acc: np.ndarray, bias_int32: np.ndarray) -> np.ndarray:
    """Add signed INT32 bias."""
    return acc + bias_int32.astype(np.int32)


def relu(x: np.ndarray) -> np.ndarray:
    """ReLU activation (matches ACT_RELU in hardware)."""
    return np.maximum(x, 0)


def requantize_int32_to_int8(x: np.ndarray, mult: int, rshift: int) -> np.ndarray:
    """
    Requantize INT32 → INT8 with multiply-shift and rounding.
    Matches cim_pkg::requantize() exactly.

    Formula: out = round(x * mult / 2^rshift)
    With rounding: (x * mult + 2^(rshift-1)) >> rshift
    Then clamp to [-128, 127].
    """
    # Use Python's arbitrary precision integers to avoid overflow
    result = np.zeros_like(x, dtype=np.int8)
    for i in range(len(x)):
        prod = int(x[i]) * int(mult)
        if rshift == 0:
            shifted = prod
        else:
            shifted = (prod + (1 << (rshift - 1))) >> rshift
        # Clamp to INT8
        shifted = max(-128, min(127, shifted))
        result[i] = np.int8(shifted)
    return result


# ============================================================================
# Full layer inference
# ============================================================================

def infer_layer(
    input_uint8: np.ndarray,
    weight_int8: np.ndarray,
    bias_int32: np.ndarray,
    zero_point: int = -128,
    requant_mult: int = 1,
    requant_shift: int = 0,
    activation: str = "relu",
) -> dict:
    """
    Run one FC layer through the CIM pipeline.
    Returns dict with all intermediate values (for debugging).
    """
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


def infer_mlp(
    input_uint8: np.ndarray,
    layers: list,  # list of dicts: {weight, bias, zp, mult, shift, act}
) -> dict:
    """Run multi-layer MLP inference."""
    x = input_uint8
    results = []

    for i, layer in enumerate(layers):
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
        # Output of this layer becomes input of next (as UINT8 reinterpreted)
        x = result["output"].view(np.uint8)

    return {
        "layers": results,
        "final_output": results[-1]["output"],
        "pred_class": results[-1]["pred_class"],
    }


# ============================================================================
# Hex file generation (for loading into RTL SRAM)
# ============================================================================

def weight_to_hex_tiles(weight_int8: np.ndarray, tile_rows: int = 16,
                         tile_cols: int = 16) -> list:
    """
    Pack weight matrix into tile-format hex strings.
    Each tile is TILE_ROWS × TILE_COLS × 8 bits = 2048 bits.
    Layout: row-major within tile, tile[ob][ib] order.
    Returns list of hex strings, one per tile.
    """
    out_dim, in_dim = weight_int8.shape
    n_ob = (out_dim + tile_rows - 1) // tile_rows
    n_ib = (in_dim + tile_cols - 1) // tile_cols
    tiles = []

    for ob in range(n_ob):
        for ib in range(n_ib):
            tile_bytes = bytearray()
            for r in range(tile_rows):
                for c in range(tile_cols):
                    out_idx = ob * tile_rows + r
                    in_idx = ib * tile_cols + c
                    if out_idx < out_dim and in_idx < in_dim:
                        val = int(weight_int8[out_idx, in_idx])
                        tile_bytes.append(val & 0xFF)
                    else:
                        tile_bytes.append(0)
            # Convert to hex (little-endian: element 0 in LSBs)
            hex_str = bytes(tile_bytes).hex()
            tiles.append(hex_str)

    return tiles


def save_hex_file(data_list: list, filename: str):
    """Save list of hex strings to a .hex file (one per line)."""
    with open(filename, 'w') as f:
        for line in data_list:
            f.write(line + '\n')
    print(f"  Saved {filename} ({len(data_list)} lines)")


def bias_to_hex(bias_int32: np.ndarray) -> list:
    """Pack INT32 bias array into hex strings (one per element)."""
    return [f"{int(b) & 0xFFFFFFFF:08x}" for b in bias_int32]


def input_to_hex_tiles(input_uint8: np.ndarray, tile_cols: int = 16) -> list:
    """Pack input vector into tile-format hex strings."""
    in_dim = len(input_uint8)
    n_ib = (in_dim + tile_cols - 1) // tile_cols
    tiles = []

    for ib in range(n_ib):
        tile_bytes = bytearray()
        for c in range(tile_cols):
            idx = ib * tile_cols + c
            if idx < in_dim:
                tile_bytes.append(int(input_uint8[idx]) & 0xFF)
            else:
                tile_bytes.append(0)
        tiles.append(bytes(tile_bytes).hex())

    return tiles


# ============================================================================
# Self-test
# ============================================================================

def self_test():
    """Run a small self-test to verify golden model correctness."""
    print("=" * 60)
    print("Golden Model Self-Test")
    print("=" * 60)

    np.random.seed(42)

    # Small layer: 32 → 16
    IN_DIM, OUT_DIM = 32, 16
    ZP = -128
    MULT = 1073741824  # 2^30
    SHIFT = 30          # effectively scale ≈ 1.0

    weight = np.random.randint(-128, 127, (OUT_DIM, IN_DIM), dtype=np.int8)
    bias = np.random.randint(-1000, 1000, OUT_DIM, dtype=np.int32)
    x = np.random.randint(0, 255, IN_DIM, dtype=np.uint8)

    result = infer_layer(x, weight, bias, ZP, MULT, SHIFT, "relu")

    print(f"\nInput (first 8):  {x[:8]}")
    print(f"x_eff (first 8):  {result['x_eff'][:8]}")
    print(f"Acc (first 4):    {result['acc'][:4]}")
    print(f"Acc+bias (first 4): {result['acc_bias'][:4]}")
    print(f"ReLU (first 4):   {result['activated'][:4]}")
    print(f"Output (all):     {result['output']}")
    print(f"Pred class:       {result['pred_class']}")

    # Verify: manual computation for output[0]
    x_eff = np.clip(x.astype(np.int32) - ZP, 0, 511)
    manual_acc = np.sum(x_eff * weight[0].astype(np.int32)) + bias[0]
    manual_relu = max(0, manual_acc)
    print(f"\nManual check out[0]: acc={manual_acc}, relu={manual_relu}")
    assert result['acc_bias'][0] == manual_acc, "ACC mismatch!"
    print("Manual check: PASS")

    # Multi-layer test (MNIST-like: 784 → 128 → 10)
    print("\n" + "=" * 60)
    print("Multi-layer test: 784 → 128 → 10")
    print("=" * 60)

    w1 = np.random.randint(-128, 127, (128, 784), dtype=np.int8)
    b1 = np.random.randint(-5000, 5000, 128, dtype=np.int32)
    w2 = np.random.randint(-128, 127, (10, 128), dtype=np.int8)
    b2 = np.random.randint(-5000, 5000, 10, dtype=np.int32)
    img = np.random.randint(0, 255, 784, dtype=np.uint8)

    mlp_result = infer_mlp(img, [
        {"weight": w1, "bias": b1, "zp": -128, "mult": MULT, "shift": SHIFT, "act": "relu"},
        {"weight": w2, "bias": b2, "zp": 0,    "mult": MULT, "shift": SHIFT, "act": "none"},
    ])

    print(f"Layer 1 output (first 10): {mlp_result['layers'][0]['output'][:10]}")
    print(f"Layer 2 output (all 10):   {mlp_result['final_output']}")
    print(f"Predicted class: {mlp_result['pred_class']}")

    # Generate hex files for RTL loading
    print("\n" + "=" * 60)
    print("Generating hex files for RTL...")
    print("=" * 60)

    os.makedirs("data_golden", exist_ok=True)
    save_hex_file(weight_to_hex_tiles(w1), "data_golden/fc1_weight.hex")
    save_hex_file(bias_to_hex(b1), "data_golden/fc1_bias.hex")
    save_hex_file(weight_to_hex_tiles(w2, tile_rows=10, tile_cols=16),
                  "data_golden/fc2_weight.hex")
    save_hex_file(bias_to_hex(b2), "data_golden/fc2_bias.hex")
    save_hex_file(input_to_hex_tiles(img), "data_golden/input.hex")

    # Save expected output for comparison
    with open("data_golden/expected_output.txt", 'w') as f:
        for val in mlp_result['final_output']:
            f.write(f"{int(val)}\n")
    print(f"  Saved data_golden/expected_output.txt")
    print(f"  Expected pred_class = {mlp_result['pred_class']}")

    print("\n>>> SELF-TEST PASSED <<<")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="CIM SoC Golden Model")
    parser.add_argument("--mnist", type=str, help="Path to quantized MNIST weights .npz")
    parser.add_argument("--self-test", action="store_true", default=True,
                        help="Run self-test (default)")
    args = parser.parse_args()

    if args.mnist:
        print("MNIST mode not yet implemented — use --self-test first")
    else:
        self_test()
