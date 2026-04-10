"""Tests for cim_driver.py utility functions (offline, no PYNQ hardware needed)."""

import re
import numpy as np
import cim_driver as cd
import golden_model as gm


# ---- 1. weight_to_chunks ----

def test_weight_to_chunks():
    """Small 2x16 weight matrix, verify chunk count and values match golden_model's hex."""
    np.random.seed(123)
    weight = np.random.randint(-128, 127, (2, 16), dtype=np.int8)

    chunks = cd.weight_to_chunks(weight)
    hex_lines = gm.weight_to_chunk_hex(weight)

    # Both should produce the same number of entries
    # n_ob=1, n_ib=1, chunks_per_tile=64 -> 64 chunks
    assert len(chunks) == 64
    assert len(hex_lines) == 64

    # Verify values match
    for i, (chunk_val, hex_str) in enumerate(zip(chunks, hex_lines)):
        assert chunk_val == int(hex_str, 16), (
            f"Mismatch at chunk {i}: driver={chunk_val:#010x}, golden={hex_str}"
        )


# ---- 2. bias_to_u32 ----

def test_bias_to_u32():
    """bias=[-1] -> [0xFFFFFFFF]; bias=[0x12345678] -> [0x12345678]."""
    result = cd.bias_to_u32(np.array([-1], dtype=np.int32))
    assert result == [0xFFFFFFFF]

    result = cd.bias_to_u32(np.array([0x12345678], dtype=np.int32))
    assert result == [0x12345678]


# ---- 3. _make_run_id format ----

def test_make_run_id_format():
    """Verify run ID matches expected format: <hash>_YYYYMMDD_HHMMSS."""
    run_id = cd._make_run_id()
    # Expect: hex-hash_YYYYMMDD_HHMMSS  or  no-git_YYYYMMDD_HHMMSS
    pattern = r'^[a-f0-9]+_\d{8}_\d{6}$|^no-git_\d{8}_\d{6}$'
    assert re.match(pattern, run_id), f"run_id '{run_id}' does not match expected pattern"


# ---- 4. im2col cross-validate ----

def test_im2col_cross_validate():
    """cim_driver.im2col and golden_model.im2col_explicit must produce identical output."""
    np.random.seed(77)
    feat = np.random.randint(0, 255, (2, 6, 6), dtype=np.uint8)
    K_h, K_w = 3, 3
    stride, padding = 1, 1

    col_drv, oh_d, ow_d = cd.im2col(feat, K_h, K_w, stride, padding)
    col_gm, oh_g, ow_g = gm.im2col_explicit(feat, K_h, K_w, stride, padding)

    assert oh_d == oh_g
    assert ow_d == ow_g
    np.testing.assert_array_equal(col_drv, col_gm)


# ---- 5. maxpool2d ----

def test_maxpool2d():
    """[[1,2],[3,4]] with k=2, s=2 -> [4]."""
    feat = np.array([[[1, 2], [3, 4]]], dtype=np.int8)  # shape [1,2,2]
    out = cd.maxpool2d(feat, kernel=2, stride=2)
    assert out.shape == (1, 1, 1)
    assert out[0, 0, 0] == 4


def test_maxpool2d_larger():
    """4x4 -> 2x2 with k=2, s=2."""
    feat = np.array([[[1, 2, 3, 4],
                      [5, 6, 7, 8],
                      [9, 10, 11, 12],
                      [13, 14, 15, 16]]], dtype=np.int8)
    out = cd.maxpool2d(feat, kernel=2, stride=2)
    assert out.shape == (1, 2, 2)
    np.testing.assert_array_equal(out[0], [[6, 8], [14, 16]])
