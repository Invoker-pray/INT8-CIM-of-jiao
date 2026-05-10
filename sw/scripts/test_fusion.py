#!/usr/bin/env python3
"""Phase C Layer Fusion: on-board functional test.

Tests OBUF→IBUF internal copy for FC1→FC2 transition.
Compares fusion result against numpy golden model — no DDR round-trip.
Self-contained: no torch, no pre-trained models needed.

Usage (on PYNQ-Z2 Jupyter):
    %run scripts/test_fusion.py
"""

import numpy as np
import os
import sys

# Look for cim_driver.py in parent dir (dev) or same dir (on-board)
_script_dir = os.path.dirname(os.path.abspath(__file__))
for _d in (_script_dir, os.path.join(_script_dir, "..")):
    if os.path.exists(os.path.join(_d, "cim_driver.py")):
        sys.path.insert(0, _d)
        break
from cim_driver import CIMDriver

# ============================================================================
# Pure-numpy INT8 golden model (bit-identical to golden_model.py)
# ============================================================================
def golden_fc(input_u8, weight_i8, bias_i32, zp=-128, mult=1, shift=0, relu=False):
    """Single FC layer: zp → MVM → bias → act → requantize.
    Matches hardware (cim_accel_core.sv) bit-exactly.
    """
    # Zero-point subtraction (unsigned [0,255] → effective [0,511] after -(-128))
    x_eff = np.clip(input_u8.astype(np.int32) - zp, 0, 511)
    # MVM
    acc = weight_i8.astype(np.int32) @ x_eff.astype(np.int32)
    # Bias
    acc = acc + bias_i32
    # Activation
    if relu:
        acc = np.maximum(acc, 0)
    # Requantize INT32→INT8 (matches cim_pkg::requantize)
    prod = acc.astype(np.int64) * np.int64(mult)
    if shift > 0:
        shifted = (prod + (np.int64(1) << (shift - 1))) >> shift
    else:
        shifted = prod
    shifted = np.clip(shifted, -128, 127)
    return shifted.astype(np.int8)


def weight_to_chunks(weight_i8):
    """Pack INT8[r,c] weight matrix into tile chunks for cim_driver.
    Each tile = 16×16 int8 = 256 bytes = 64 uint32 words.
    Tiles laid out: for ob in n_ob: for ib in n_ib: tile[ob, ib]
    """
    r, c = weight_i8.shape
    TILE_R, TILE_C = 16, 16
    n_ob = (r + TILE_R - 1) // TILE_R
    n_ib = (c + TILE_C - 1) // TILE_C
    chunks = []
    for ob in range(n_ob):
        for ib in range(n_ib):
            r0, r1 = ob * TILE_R, min((ob + 1) * TILE_R, r)
            c0, c1 = ib * TILE_C, min((ib + 1) * TILE_C, c)
            tile = np.zeros((TILE_R, TILE_C), dtype=np.int8)
            tile[: r1 - r0, : c1 - c0] = weight_i8[r0:r1, c0:c1]
            # Pack row-major bytes into 32-bit words, little-endian
            words = tile.view(np.uint8).ravel().view(np.uint32)
            chunks.extend(words.tolist())
    return chunks


def bias_to_words(bias_i32):
    """Convert int32 bias array to uint32 words."""
    return np.asarray(bias_i32, dtype=np.int32).view(np.uint32).tolist()


# ============================================================================
# Test: FC1(784→128) → fusion → FC2(128→10)
# ============================================================================
def main():
    print("=" * 60)
    print("Phase C Layer Fusion — On-Board Test")
    print("=" * 60)

    np.random.seed(42)

    # Generate random quantized weights (small magnitude like real MNIST)
    w1 = np.random.randint(-16, 16, (128, 784), dtype=np.int8)
    b1 = np.random.randint(-500, 500, (128,), dtype=np.int32)
    w2 = np.random.randint(-16, 16, (10, 128), dtype=np.int8)
    b2 = np.random.randint(-500, 500, (10,), dtype=np.int32)

    # Quantization params
    fc1_mult, fc1_shift = 6, 16    # real MNIST values
    fc2_mult, fc2_shift = 263, 16

    # Test input (random but realistic — MNIST pixels in [0,255])
    img_u8 = np.random.randint(0, 256, (784,), dtype=np.uint8)

    # --- Golden reference ---
    fc1_ref = golden_fc(img_u8, w1, b1, zp=-128, mult=fc1_mult,
                        shift=fc1_shift, relu=True)
    fc2_ref = golden_fc(fc1_ref.view(np.uint8), w2, b2, zp=0,
                        mult=fc2_mult, shift=fc2_shift, relu=False)
    golden_pred = int(np.argmax(fc2_ref))
    print(f"\nGolden reference:")
    print(f"  FC1 output (first 8): {fc1_ref[:8]}")
    print(f"  FC2 output:           {fc2_ref}")
    print(f"  Predicted class:      {golden_pred}")

    # --- CIM hardware with fusion (multi-layer weight coexistence) ---
    drv = CIMDriver(use_dma=True)

    fc1_w_chunks = weight_to_chunks(w1)
    fc2_w_chunks = weight_to_chunks(w2)
    fc1_b = bias_to_words(b1)
    fc2_b = bias_to_words(b2)

    # Pre-load both layers at different SRAM offsets (no overwrite)
    drv.setup_fc_fused_pair(
        fc1_in_dim=784, fc1_out_dim=128,
        fc1_w_chunks=fc1_w_chunks, fc1_bias_u32=fc1_b,
        fc1_zp=-128, fc1_mult=fc1_mult, fc1_shift=fc1_shift,
        fc2_out_dim=10, fc2_w_chunks=fc2_w_chunks, fc2_bias_u32=fc2_b,
        fc2_mult=fc2_mult, fc2_shift=fc2_shift,
    )
    print(f"\nWeight SRAM: FC1 tiles 0..{drv._fc2_weight_base - 1}, "
          f"FC2 tiles {drv._fc2_weight_base}..{drv._fc2_weight_base + len(fc2_w_chunks)//64 - 1}")
    print(f"Bias SRAM:   FC1 addr 0..{127}, FC2 addr {drv._fc2_bias_base}..{drv._fc2_bias_base + len(fc2_b) - 1}")

    # --- Test 1: Single image fusion ---
    print("\n--- Test 1: Single image fusion ---")
    out1, c1, c2 = drv.infer_fc_fused_pair(img_u8, 128, 10)
    pred1 = int(np.argmax(out1))
    match1 = np.array_equal(out1, fc2_ref)
    print(f"  FC1 cycles={c1}, FC2 cycles={c2}")
    print(f"  Output: {out1}")
    print(f"  Prediction: {pred1} (golden: {golden_pred})")
    print(f"  Match: {match1}")

    # --- Test 2: Batch fusion (3 images, no per-image weight reload) ---
    print("\n--- Test 2: Batch fusion (3 images) ---")
    np.random.seed(99)
    batch_imgs = [np.random.randint(0, 256, (784,), dtype=np.uint8)
                  for _ in range(3)]
    batch_golden = []
    for img in batch_imgs:
        r1 = golden_fc(img, w1, b1, zp=-128, mult=fc1_mult,
                       shift=fc1_shift, relu=True)
        r2 = golden_fc(r1.view(np.uint8), w2, b2, zp=0,
                       mult=fc2_mult, shift=fc2_shift, relu=False)
        batch_golden.append(r2)

    batch_out, tc1, tc2 = drv.infer_fc_fused_batch(batch_imgs, 128, 10)
    all_match = True
    for i, (hw, ref) in enumerate(zip(batch_out, batch_golden)):
        m = np.array_equal(hw, ref)
        p_hw, p_ref = int(np.argmax(hw)), int(np.argmax(ref))
        print(f"  Image {i}: match={m}, pred HW={p_hw}, ref={p_ref}")
        if not m:
            all_match = False
            diff = hw.astype(np.int32) - ref.astype(np.int32)
            print(f"    Diff: {diff}")
    print(f"  FC1 total cycles: {tc1}, FC2 total cycles: {tc2}")

    # --- Final ---
    passed = match1 and all_match
    if passed:
        print("\n>>> LAYER FUSION TESTS PASSED (single + batch) <<<")
    else:
        print("\n>>> LAYER FUSION TESTS FAILED <<<")

    return passed


if __name__ == "__main__":
    main()
