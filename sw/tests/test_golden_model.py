"""Tests for golden_model.py core functions (offline, no hardware needed)."""

import numpy as np
import golden_model as gm


# ---- 1. apply_zero_point ----

def test_apply_zero_point_basic():
    """x=[200], zp=-128 -> 200-(-128)=328; x=[0], zp=0 -> 0."""
    out = gm.apply_zero_point(np.array([200], dtype=np.uint8), -128)
    assert out[0] == 328

    out = gm.apply_zero_point(np.array([0], dtype=np.uint8), 0)
    assert out[0] == 0


def test_apply_zero_point_clamp():
    """Result must be clamped to [0, 511]."""
    # Large subtraction: 0 - (-128) = 128, fine
    # 255 - (-256) = 511 would be the max, but zp is normally in int8 range
    # Test upper clamp: x=255, zp=-300 -> 555, clamped to 511
    out = gm.apply_zero_point(np.array([255], dtype=np.uint8), -300)
    assert out[0] == 511

    # Test lower clamp: x=0, zp=10 -> -10, clamped to 0
    out = gm.apply_zero_point(np.array([0], dtype=np.uint8), 10)
    assert out[0] == 0


# ---- 2. cim_mvm ----

def test_cim_mvm_identity():
    """2x2 identity weight, known input -> known output."""
    weight = np.eye(2, dtype=np.int8)
    x_eff = np.array([100, 200], dtype=np.uint16)
    result = gm.cim_mvm(x_eff, weight)
    np.testing.assert_array_equal(result, [100, 200])


def test_cim_mvm_known():
    """Simple 2x2 matrix * vector."""
    weight = np.array([[1, 2], [3, 4]], dtype=np.int8)
    x_eff = np.array([10, 20], dtype=np.uint16)
    result = gm.cim_mvm(x_eff, weight)
    # [1*10+2*20, 3*10+4*20] = [50, 110]
    np.testing.assert_array_equal(result, [50, 110])


# ---- 3. relu ----

def test_relu():
    """[-3, 0, 5] -> [0, 0, 5]."""
    x = np.array([-3, 0, 5], dtype=np.int32)
    result = gm.relu(x)
    np.testing.assert_array_equal(result, [0, 0, 5])


# ---- 4. requantize ----

def test_requantize_basic():
    """Known mult/shift, verify clamp to [-128, 127]."""
    # Simple case: mult=1, shift=0 -> identity, but clamped
    x = np.array([50, -50, 200, -200], dtype=np.int32)
    result = gm.requantize_int32_to_int8(x, mult=1, rshift=0)
    np.testing.assert_array_equal(result, [50, -50, 127, -128])


def test_requantize_with_shift():
    """mult=2, shift=1 -> effectively multiply by 1, with rounding."""
    x = np.array([60, -60], dtype=np.int32)
    result = gm.requantize_int32_to_int8(x, mult=2, rshift=1)
    # prod=120, shifted=(120+1)>>1=60; prod=-120, shifted=(-120+1)>>1=-59 (Python // is floor)
    # But the golden model uses >>, which for negative in Python is arithmetic shift.
    # (prod + (1 << (rshift-1))) >> rshift
    # For -60: prod=-120, (-120 + 1) >> 1 = -119 >> 1 = -60 (Python arithmetic shift right)
    np.testing.assert_array_equal(result, [60, -60])


# ---- 5. infer_layer_roundtrip ----

def test_infer_layer_roundtrip():
    """seed=42, small 4x4 FC layer, verify output matches manual computation."""
    np.random.seed(42)
    in_dim, out_dim = 4, 4
    weight = np.random.randint(-128, 127, (out_dim, in_dim), dtype=np.int8)
    bias = np.random.randint(-100, 100, out_dim, dtype=np.int32)
    x = np.random.randint(0, 255, in_dim, dtype=np.uint8)
    zp = -128
    mult, shift = 1, 0

    result = gm.infer_layer(x, weight, bias, zp, mult, shift, "relu")

    # Manual computation
    x_eff = np.clip(x.astype(np.int32) - zp, 0, 511)
    acc = weight.astype(np.int32) @ x_eff.astype(np.int32)
    acc_bias = acc + bias.astype(np.int32)
    activated = np.maximum(acc_bias, 0)
    output = gm.requantize_int32_to_int8(activated, mult, shift)

    np.testing.assert_array_equal(result["x_eff"], x_eff.astype(np.uint16))
    np.testing.assert_array_equal(result["acc"], acc)
    np.testing.assert_array_equal(result["acc_bias"], acc_bias)
    np.testing.assert_array_equal(result["activated"], activated)
    np.testing.assert_array_equal(result["output"], output)


# ---- 6. im2col explicit vs implicit ----

def test_im2col_explicit_vs_implicit():
    """1-channel 4x4 feature, 2x2 kernel -> both modes must produce identical output."""
    feat = np.arange(16, dtype=np.uint8).reshape(1, 4, 4)
    K_h, K_w = 2, 2
    stride, padding = 1, 0

    col_explicit, oh_e, ow_e = gm.im2col_explicit(feat, K_h, K_w, stride, padding)

    addr_table, oh_i, ow_i = gm.im2col_implicit_addr_gen(
        1, 4, 4, K_h, K_w, stride, padding
    )
    col_len = 1 * K_h * K_w
    n_pixels = oh_i * ow_i
    col_implicit = gm.im2col_apply_implicit(feat, addr_table, col_len, n_pixels)

    assert oh_e == oh_i
    assert ow_e == ow_i
    np.testing.assert_array_equal(col_explicit, col_implicit)


# ---- 7. infer_conv_layer ----

def test_infer_conv_layer():
    """Small 1->2 conv with 3x3 kernel, verify output shape and deterministic values."""
    np.random.seed(99)
    C_in, H, W = 1, 5, 5
    C_out, K = 2, 3
    stride, padding = 1, 0

    feat = np.random.randint(0, 255, (C_in, H, W), dtype=np.uint8)
    weight = np.random.randint(-128, 127, (C_out, C_in, K, K), dtype=np.int8)
    bias = np.random.randint(-100, 100, C_out, dtype=np.int32)

    out_map, info = gm.infer_conv_layer(
        feat, weight, bias,
        stride=stride, padding=padding,
        zero_point=-128, requant_mult=1, requant_shift=0,
        activation="relu", mode="explicit",
    )

    # Output spatial: (5-3)//1+1 = 3
    assert out_map.shape == (C_out, 3, 3)
    assert info["out_h"] == 3
    assert info["out_w"] == 3
    assert info["n_mvm"] == 9

    # Run again with same seed, verify deterministic
    np.random.seed(99)
    feat2 = np.random.randint(0, 255, (C_in, H, W), dtype=np.uint8)
    weight2 = np.random.randint(-128, 127, (C_out, C_in, K, K), dtype=np.int8)
    bias2 = np.random.randint(-100, 100, C_out, dtype=np.int32)
    out_map2, _ = gm.infer_conv_layer(
        feat2, weight2, bias2,
        stride=stride, padding=padding,
        zero_point=-128, requant_mult=1, requant_shift=0,
        activation="relu", mode="explicit",
    )
    np.testing.assert_array_equal(out_map, out_map2)
