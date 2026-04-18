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


# ---- 6. C3 (step 8): DMA path bit-exact vs legacy MMIO ----

class _MockMMIO:
    """Records all .write() calls as (addr, data) tuples; .read() returns 0."""
    def __init__(self):
        self.writes = []
    def write(self, addr, data):
        self.writes.append((int(addr), int(data) & 0xFFFFFFFF))
    def read(self, _addr):
        return 0  # status always clean (no overflow/underflow)


class _MockDMAChannel:
    """Captures the numpy buffer passed to transfer(); wait() is a no-op."""
    def __init__(self):
        self.transfers = []
    def transfer(self, buf):
        self.transfers.append(np.asarray(buf).copy())
    def wait(self):
        pass


class _MockDMA:
    def __init__(self):
        self.sendchannel = _MockDMAChannel()


def _make_dma_driver():
    """Bypass pynq-dependent __init__ and build a driver wired to mocks."""
    drv = cd.CIMDriver.__new__(cd.CIMDriver)
    drv.mmio = _MockMMIO()
    drv.use_dma = True
    drv.dma = _MockDMA()
    # Pre-allocate buffers as plain ndarrays (not pynq.allocate — no kernel CMA on PC).
    drv._buf_w = np.zeros(cd._DMA_BUF_WEIGHTS, dtype=np.uint32)
    drv._buf_x = np.zeros(cd._DMA_BUF_INPUT, dtype=np.uint32)
    drv._buf_b = np.zeros(cd._DMA_BUF_BIAS, dtype=np.uint32)
    return drv


def _make_legacy_driver():
    drv = cd.CIMDriver.__new__(cd.CIMDriver)
    drv.mmio = _MockMMIO()
    drv.use_dma = False
    drv.dma = None
    return drv


def test_dma_path_bit_exact_weights():
    """DMA path must push the exact same 32-bit chunks legacy path would MMIO."""
    np.random.seed(42)
    weight = np.random.randint(-128, 127, (16, 16), dtype=np.int8)
    chunks = cd.weight_to_chunks(weight)

    # Legacy: record sequence of WDMA_DATA writes
    legacy = _make_legacy_driver()
    legacy.load_weights(chunks)
    legacy_data = [d for a, d in legacy.mmio.writes if a == cd._WDMA_DATA]
    assert legacy_data == [c & 0xFFFFFFFF for c in chunks]

    # DMA path: record transfer buffer
    dma = _make_dma_driver()
    dma.load_weights(chunks)
    assert len(dma.dma.sendchannel.transfers) == 1
    buf = dma.dma.sendchannel.transfers[0]
    np.testing.assert_array_equal(
        buf, np.asarray([c & 0xFFFFFFFF for c in chunks], dtype=np.uint32)
    )
    # CSR protocol: DEST=0 first, then LEN=n; nothing else written before transfer.
    assert dma.mmio.writes[0] == (cd._CSR_STREAM_DEST, cd._DEST_WEIGHT)
    assert dma.mmio.writes[1] == (cd._CSR_STREAM_LEN, len(chunks))


def test_dma_path_bit_exact_bias():
    """DMA path bias words match legacy MEM_BIAS MMIO sequence."""
    bias = np.array([-1, 0, 123, -2**30, 2**30], dtype=np.int32)
    bias_u32 = cd.bias_to_u32(bias)

    legacy = _make_legacy_driver()
    legacy.load_bias(bias_u32)
    legacy_data = [d for a, d in legacy.mmio.writes
                   if cd._MEM_BIAS <= a < cd._MEM_BIAS + 0x200]
    assert legacy_data == [b & 0xFFFFFFFF for b in bias_u32]

    dma = _make_dma_driver()
    dma.load_bias(bias_u32)
    buf = dma.dma.sendchannel.transfers[0]
    np.testing.assert_array_equal(
        buf, np.asarray([b & 0xFFFFFFFF for b in bias_u32], dtype=np.uint32)
    )
    assert dma.mmio.writes[0] == (cd._CSR_STREAM_DEST, cd._DEST_BIAS)
    assert dma.mmio.writes[1] == (cd._CSR_STREAM_LEN, len(bias_u32))


def test_dma_path_bit_exact_input():
    """DMA path packs input bytes little-endian into uint32 identical to
    how the legacy MMIO path (byte-per-word) would assemble in the slave's
    ibuf_staging. Specifically: byte k lands in staging[8k+7:8k], which for
    k<4 is the low byte of word 0; for k=4..7 the low byte of word 1; etc."""
    np.random.seed(99)
    # Use 48 bytes → 3 full 16-byte tiles, all populated.
    data_u8 = np.random.randint(0, 255, 48, dtype=np.uint8).tolist()

    dma = _make_dma_driver()
    dma.load_input(data_u8)
    buf = dma.dma.sendchannel.transfers[0]

    # Reconstruct expected uint32 words: 4 bytes little-endian per word.
    expected = np.asarray(data_u8, dtype=np.uint8).view(np.uint32)
    np.testing.assert_array_equal(buf, expected)

    # Protocol order
    assert dma.mmio.writes[0] == (cd._CSR_STREAM_DEST, cd._DEST_INPUT)
    assert dma.mmio.writes[1] == (cd._CSR_STREAM_LEN, len(expected))


def test_dma_path_auto_pad_input():
    """Input not a multiple of 16 bytes must be zero-padded before packing."""
    data_u8 = [0x01, 0x02, 0x03, 0x04, 0x05]  # 5 bytes → pad 11 zeros → 1 tile

    dma = _make_dma_driver()
    dma.load_input(data_u8)
    buf = dma.dma.sendchannel.transfers[0]

    assert len(buf) == 4  # 16 bytes / 4 = 4 uint32 words
    # First word = 0x04030201 (little-endian), second = 0x00000005, rest = 0
    assert buf[0] == 0x04030201
    assert buf[1] == 0x00000005
    assert buf[2] == 0x00000000
    assert buf[3] == 0x00000000


def test_dma_path_zero_length_noop():
    """Empty input list must not trigger any CSR write or DMA transfer."""
    dma = _make_dma_driver()
    dma.load_weights([])
    assert dma.mmio.writes == []
    assert dma.dma.sendchannel.transfers == []


def test_dma_path_overflow_raises():
    """More words than buffer capacity must raise ValueError."""
    dma = _make_dma_driver()
    oversized = list(range(cd._DMA_BUF_WEIGHTS + 1))
    try:
        dma.load_weights(oversized)
    except ValueError as e:
        assert "exceeds pre-allocated buffer capacity" in str(e)
    else:
        raise AssertionError("expected ValueError on oversized load")
