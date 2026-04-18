"""
cim_driver.py — Python driver for CIM SoC on PYNQ-Z2

Provides:
  CIMDriver     — low-level MMIO wrapper for single-layer operations
  CIMModel      — high-level multi-layer inference (FC + Conv via im2col)

Usage on PYNQ:
  from cim_driver import CIMDriver, CIMModel

  drv = CIMDriver('cim_soc.bit')

  # Single layer
  fc1_out = drv.infer_fc(input_u8, w_chunks, bias_u32, zp=0, mult=14, shift=16, relu=True)

  # Multi-layer MLP
  model = CIMModel(drv)
  model.add_fc(784, 128, w1_chunks, b1_u32, zp=0, mult=14, shift=16, relu=True)
  model.add_fc(128, 10,  w2_chunks, b2_u32, zp=0, mult=140, shift=16, relu=False)
  pred, logits = model.predict(image_u8)

  # Conv layer (Python-side im2col + hardware MVM)
  out_map = model.infer_conv(feat_map, weight_4d, bias, zp, mult, shift, stride, padding, relu)

Hardware limits (cim_pkg.sv):
  MAX_IN_DIM  = 784
  MAX_OUT_DIM = 128
  TILE_ROWS   = 16
  TILE_COLS   = 16
"""

import numpy as np
import os
import time

# Try importing pynq; if not available, provide a mock for testing on PC
try:
    from pynq import Overlay, MMIO

    _HAS_PYNQ = True
except ImportError:
    _HAS_PYNQ = False


# ============================================================================
# Hardware constants (must match cim_pkg.sv)
# ============================================================================
TILE_ROWS = 16
TILE_COLS = 16
ELEMS_PER_CHUNK = 4  # 32 / WEIGHT_W
CHUNKS_PER_ROW = 4  # TILE_COLS / ELEMS_PER_CHUNK
CHUNKS_PER_TILE = 64  # TILE_ROWS * CHUNKS_PER_ROW
MAX_IN_DIM = 784
MAX_OUT_DIM = 128


# ============================================================================
# Run ID generator (git commit + timestamp fingerprint)
# ============================================================================
def _make_run_id():
    """Generate a run ID: <git-short-hash>_<YYYYMMDD_HHMMSS>."""
    import subprocess
    import datetime

    try:
        git_hash = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
            cwd=os.path.dirname(os.path.abspath(__file__)),
        ).decode().strip()
    except Exception:
        git_hash = "no-git"
    return f"{git_hash}_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}"


# CSR address map (14-bit, base 0x40000000)
_BASE = 0x40000000
_MMIO_SIZE = 0x4000  # 16KB

_CTRL = 0x000
_STATUS = 0x004
_CSR_IN_DIM = 0x010
_CSR_OUT_DIM = 0x014
_CSR_N_IB = 0x018
_CSR_N_OB = 0x01C
_REQUANT_MULT = 0x020
_REQUANT_SHIFT = 0x024
_INPUT_ZP = 0x028
_ACT_MODE = 0x02C
_CYCLE_CNT_LO = 0x030
_MAC_CNT_LO = 0x038
_PRED_CLASS = 0x040
_WDMA_ADDR = 0x044
_WDMA_DATA = 0x048
_WDMA_CTRL = 0x04C
# C3 (step 8): AXI4-Stream sink control (active when CTRL[3]=1)
_CSR_STREAM_DEST = 0x050      # [1:0]=dest (0=weight, 1=input, 2=bias); [31:16]=base_addr
_CSR_STREAM_LEN = 0x054       # [15:0]=beat count; write triggers cfg_start pulse
_CSR_STREAM_STATUS = 0x058    # [0]=busy, [1]=done, [2]=overflow, [3]=underflow
_LOGIT_BASE = 0x100
_MEM_INPUT = 0x1000
_MEM_BIAS = 0x2000

# CSR_CTRL bit masks
_CTRL_START = 0x1
_CTRL_CLEAR_DONE = 0x2
_CTRL_SOFT_RST = 0x4
_CTRL_STREAM_EN = 0x8         # C3: 1 → data writes come from stream sink, 0 → legacy MMIO staging

# Stream destination codes (must match cim_pkg::stream_dest_t)
_DEST_WEIGHT = 0
_DEST_INPUT = 1
_DEST_BIAS = 2

# CMA buffer sizing upper bounds — cover any single-layer load for LeNet-5 / MNIST-MLP.
# LeNet-5 Conv2 packed weight is the largest: col_len=150*16=2400 chunks; headroom 4×.
_DMA_BUF_WEIGHTS = 20000      # 32-bit words (up to ~80 KB)
_DMA_BUF_INPUT = (MAX_IN_DIM + 15) // 4  # packed UINT8 → uint32 words
_DMA_BUF_BIAS = MAX_OUT_DIM


# ============================================================================
# Weight packing (same as golden_model.py / mnist_quantize.py)
# ============================================================================
def weight_to_chunks(weight_int8):
    """Pack [out_dim, in_dim] INT8 weight → list of 32-bit chunk words."""
    out_dim, in_dim = weight_int8.shape
    n_ob = (out_dim + TILE_ROWS - 1) // TILE_ROWS
    n_ib = (in_dim + TILE_COLS - 1) // TILE_COLS
    chunks = []
    for ob in range(n_ob):
        for ib in range(n_ib):
            for chunk in range(CHUNKS_PER_TILE):
                row = chunk // CHUNKS_PER_ROW
                col_group = chunk % CHUNKS_PER_ROW
                word = 0
                for b in range(ELEMS_PER_CHUNK):
                    oi = ob * TILE_ROWS + row
                    ii = ib * TILE_COLS + col_group * ELEMS_PER_CHUNK + b
                    if oi < out_dim and ii < in_dim:
                        val = int(weight_int8[oi, ii]) & 0xFF
                    else:
                        val = 0
                    word |= val << (b * 8)
                chunks.append(word)
    return chunks


def bias_to_u32(bias_int32):
    """INT32 bias → list of unsigned 32-bit words."""
    return [int(b) & 0xFFFFFFFF for b in bias_int32]


# ============================================================================
# im2col (explicit, Python-side)
# ============================================================================
def im2col(feature_map, kernel_h, kernel_w, stride=1, padding=0):
    """
    Explicit im2col: rearrange feature map patches into column matrix.

    Args:
        feature_map: [C_in, H, W] UINT8 ndarray
        kernel_h, kernel_w: kernel spatial size
        stride, padding: conv parameters

    Returns:
        col_matrix: [C_in*K_h*K_w, out_h*out_w] UINT8
        out_h, out_w: output spatial dimensions
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


def maxpool2d(feat, kernel=2, stride=2):
    """Max pooling on signed INT8 feature map [C, H, W]."""
    C, H, W = feat.shape
    oh, ow = H // stride, W // stride
    out = np.zeros((C, oh, ow), dtype=feat.dtype)
    for c in range(C):
        for i in range(oh):
            for j in range(ow):
                out[c, i, j] = feat[c, i * stride : i * stride + kernel,
                                    j * stride : j * stride + kernel].max()
    return out


# ============================================================================
# CIMDriver — low-level hardware interface
# ============================================================================
class CIMDriver:
    """Low-level driver for CIM accelerator via AXI4-Lite MMIO."""

    def __init__(self, bitstream_path="cim_soc.bit", load=True, use_dma=True):
        """
        Args:
            bitstream_path: path to .bit file (must have matching .hwh)
            load: if True, load overlay immediately
            use_dma: if True (default, commit 6), route weight/input/bias
                     through AXI-Stream + axi_dma (C3). Requires a bitstream
                     built after commit 4 BD integration. If the bitstream
                     predates C3, pass use_dma=False to fall back to the
                     legacy MMIO path — everything still works at ~270× the
                     wall-clock cost.
        """
        if not _HAS_PYNQ:
            raise RuntimeError("pynq not available — run this on PYNQ-Z2")
        if load:
            self.overlay = Overlay(bitstream_path)
        self.mmio = MMIO(_BASE, _MMIO_SIZE)
        self.use_dma = use_dma
        self.dma = None
        self._buf_w = None
        self._buf_x = None
        self._buf_b = None
        if use_dma:
            self._init_dma()
        self.soft_reset()

    def _init_dma(self):
        """Prepare DMA channel + pinned CMA buffers. Called once from __init__
        when use_dma=True. Fails fast if the bitstream does not expose axi_dma_0.
        """
        try:
            self.dma = self.overlay.axi_dma_0
        except AttributeError as e:
            raise RuntimeError(
                "Bitstream does not expose axi_dma_0 — rebuild with "
                "hw/scripts/vivado_build.sh after C3 BD integration (commit 4)."
            ) from e
        from pynq import allocate
        self._buf_w = allocate(shape=(_DMA_BUF_WEIGHTS,), dtype=np.uint32)
        self._buf_x = allocate(shape=(_DMA_BUF_INPUT,), dtype=np.uint32)
        self._buf_b = allocate(shape=(_DMA_BUF_BIAS,), dtype=np.uint32)

    def set_dma_mode(self, enable):
        """Runtime switch between DMA path and legacy MMIO path.

        Useful for A/B bit-exact comparison. If enable=True and DMA was not
        initialized in __init__, lazily initializes. Writes CTRL[3] so the
        slave's MUX selects the correct path for subsequent load_* calls.
        """
        if enable and self.dma is None:
            self._init_dma()
        self.use_dma = bool(enable)
        # Update CTRL[3] without disturbing other bits; CTRL[0:2] are pulses.
        self.mmio.write(_CTRL, _CTRL_STREAM_EN if enable else 0)

    def soft_reset(self):
        # Preserve CTRL[3] stream-mode bit while pulsing soft-reset.
        self.mmio.write(_CTRL, _CTRL_SOFT_RST | (_CTRL_STREAM_EN if self.use_dma else 0))

    def _clear_done(self):
        self.mmio.write(_CTRL, _CTRL_CLEAR_DONE | (_CTRL_STREAM_EN if self.use_dma else 0))

    def configure(self, in_dim, out_dim, zp, mult, shift, relu):
        """Configure CSR registers for one layer."""
        n_ib = (in_dim + 15) // 16
        n_ob = (out_dim + 15) // 16
        m = self.mmio
        m.write(_CSR_IN_DIM, in_dim)
        m.write(_CSR_OUT_DIM, out_dim)
        m.write(_CSR_N_IB, n_ib)
        m.write(_CSR_N_OB, n_ob)
        m.write(_REQUANT_MULT, mult)
        m.write(_REQUANT_SHIFT, shift)
        m.write(_INPUT_ZP, int(zp) & 0xFFFFFFFF)
        m.write(_ACT_MODE, 1 if relu else 0)

    # ------------------------------------------------------------------ #
    # C3: data-path dispatchers — route to DMA or legacy MMIO path based
    # on self.use_dma. Both paths land the exact same byte sequence in
    # weight_sram / input_buffer / bias_sram (bit-exact guaranteed by the
    # cim_axi_stream_sink FSM mirroring the MMIO staging logic; see
    # docs/c3_dma_design.md §3.1-3.5 and §7.3 mock test).
    # ------------------------------------------------------------------ #
    def _stream_load(self, words, dest, buf):
        """Push `words` (iterable of uint32) to the stream sink at `dest`.

        Synchronous: blocks until DMA completes and sink reports done.
        """
        n = len(words)
        if n == 0:
            return
        if n > len(buf):
            raise ValueError(
                f"stream_load: {n} words exceeds pre-allocated buffer capacity {len(buf)}. "
                f"Increase _DMA_BUF_* at top of cim_driver.py."
            )
        buf[:n] = np.asarray(words, dtype=np.uint32)
        # Order matters: DEST must be latched before LEN. LEN write atomically
        # pulses cfg_start in the sink (see cim_axi_lite_slave.sv line for
        # CSR_STREAM_LEN, and design doc §3.3 scheme A).
        self.mmio.write(_CSR_STREAM_DEST, int(dest))
        self.mmio.write(_CSR_STREAM_LEN, n)
        self.dma.sendchannel.transfer(buf[:n])
        self.dma.sendchannel.wait()
        # Secondary status check — catches desyncs between PS transfer_len
        # and CSR_STREAM_LEN (overflow / underflow sticky bits).
        status = self.mmio.read(_CSR_STREAM_STATUS)
        if status & 0x4:
            raise RuntimeError(f"stream sink overflow (status=0x{status:08x}); "
                               f"PS sent more beats than CSR_STREAM_LEN=n={n}")
        if status & 0x8:
            raise RuntimeError(f"stream sink underflow (status=0x{status:08x}); "
                               f"PS sent fewer beats than CSR_STREAM_LEN=n={n}")
        self.mmio.write(_CSR_STREAM_STATUS, 0)  # clear sticky done

    def load_weights(self, chunks):
        """Load weight chunks. Routes to DMA or legacy MMIO based on use_dma."""
        if self.use_dma:
            self._stream_load(chunks, _DEST_WEIGHT, self._buf_w)
        else:
            self._load_weights_legacy(chunks)

    def load_input(self, data_u8):
        """Load UINT8 input vector. Routes to DMA or legacy MMIO based on use_dma."""
        if self.use_dma:
            # Pack UINT8 stream into uint32 words, LE: byte0 in bits[7:0], etc.
            # This matches cim_axi_stream_sink.sv DEST_INPUT path, which is
            # itself byte-compatible with the legacy MMIO staging in
            # cim_axi_lite_slave.sv (ibuf_staging[8k+7:8k] = byte k).
            arr = np.asarray(data_u8, dtype=np.uint8)
            pad = (-len(arr)) % 16
            if pad:
                arr = np.concatenate([arr, np.zeros(pad, dtype=np.uint8)])
            words = arr.view(np.uint32)
            self._stream_load(words.tolist(), _DEST_INPUT, self._buf_x)
        else:
            self._load_input_legacy(data_u8)

    def load_bias(self, bias_u32):
        """Load INT32 bias values. Routes to DMA or legacy MMIO based on use_dma."""
        if self.use_dma:
            words = [int(b) & 0xFFFFFFFF for b in bias_u32]
            self._stream_load(words, _DEST_BIAS, self._buf_b)
        else:
            self._load_bias_legacy(bias_u32)

    # --- Legacy (per-word MMIO) implementations; retained for A/B tests ---
    def _load_weights_legacy(self, chunks):
        """Load weight chunks via AXI4-Lite burst MMIO."""
        m = self.mmio
        m.write(_WDMA_ADDR, 0)
        m.write(_WDMA_CTRL, 0x02)  # burst enable
        for c in chunks:
            m.write(_WDMA_DATA, int(c))
        m.write(_WDMA_CTRL, 0x00)

    def _load_bias_legacy(self, bias_u32):
        """Load INT32 bias via per-word MMIO writes."""
        for i, b in enumerate(bias_u32):
            self.mmio.write(_MEM_BIAS + 4 * i, int(b) & 0xFFFFFFFF)

    def _load_input_legacy(self, data_u8):
        """Load UINT8 input vector via per-word MMIO writes (auto-pads to 16)."""
        padded = list(data_u8)
        while len(padded) % 16 != 0:
            padded.append(0)
        for i, x in enumerate(padded):
            self.mmio.write(_MEM_INPUT + 4 * i, int(x) & 0xFF)

    def start_and_wait(self):
        """Trigger computation and block until done. Returns (cycles, macs)."""
        self._clear_done()
        self.mmio.write(_CTRL, 0x1)
        while not (self.mmio.read(_STATUS) & 0x2):
            pass
        cycles = self.mmio.read(_CYCLE_CNT_LO)
        macs = self.mmio.read(_MAC_CNT_LO)
        return cycles, macs

    def read_output(self, out_dim):
        """Read output buffer as list of signed INT8."""
        out = []
        for i in range(out_dim):
            v = self.mmio.read(_LOGIT_BASE + 4 * i)
            out.append(np.uint8(v & 0xFF).view(np.int8))
        return out

    def read_pred_class(self):
        """Read hardware argmax result."""
        return self.mmio.read(_PRED_CLASS)

    def infer_fc(self, input_u8, w_chunks, bias_u32, zp, mult, shift, relu=True,
                 _timings=None):
        """
        Run one FC layer end-to-end.

        Args:
            input_u8: list/array of UINT8 input values
            w_chunks: list of 32-bit weight chunk words (from weight_to_chunks)
            bias_u32: list of unsigned 32-bit bias words (from bias_to_u32)
            zp: hardware zero point (signed int)
            mult, shift: requantization parameters
            relu: True for ReLU activation
            _timings: if not None, append a per-phase timing dict to this list

        Returns:
            output: list of signed INT8 values
            cycles: clock cycles used
        """
        in_dim = len(input_u8)
        out_dim = len(bias_u32)
        do_t = _timings is not None

        if do_t: t0 = time.perf_counter()
        self.soft_reset()
        self.configure(in_dim, out_dim, zp, mult, shift, relu)
        if do_t: t1 = time.perf_counter()
        self.load_weights(w_chunks)
        if do_t: t2 = time.perf_counter()
        self.load_bias(bias_u32)
        if do_t: t3 = time.perf_counter()
        self.load_input(input_u8)
        if do_t: t4 = time.perf_counter()
        cycles, macs = self.start_and_wait()
        if do_t: t5 = time.perf_counter()
        output = self.read_output(out_dim)
        if do_t:
            t6 = time.perf_counter()
            _timings.append({
                "configure_ms": (t1 - t0) * 1000,
                "load_w_ms": (t2 - t1) * 1000,
                "load_b_ms": (t3 - t2) * 1000,
                "load_x_ms": (t4 - t3) * 1000,
                "compute_ms": (t5 - t4) * 1000,
                "read_out_ms": (t6 - t5) * 1000,
                "hw_cycles": cycles,
                "hw_macs": macs,
            })
        return output, cycles

    def infer_fc_input_only(self, input_u8, out_dim, _timings=None):
        """
        Run MVM with pre-loaded weights/bias/CSR.
        Only loads input, triggers computation, and reads output.

        Args:
            input_u8: list/array of UINT8 input values
            out_dim: number of output elements to read
            _timings: if not None, append a per-phase timing dict

        Returns:
            output: list of signed INT8 values
            cycles: clock cycles used
        """
        do_t = _timings is not None
        if do_t: t0 = time.perf_counter()
        self.load_input(input_u8)
        if do_t: t1 = time.perf_counter()
        cycles, macs = self.start_and_wait()
        if do_t: t2 = time.perf_counter()
        output = self.read_output(out_dim)
        if do_t:
            t3 = time.perf_counter()
            _timings.append({
                "load_x_ms": (t1 - t0) * 1000,
                "compute_ms": (t2 - t1) * 1000,
                "read_out_ms": (t3 - t2) * 1000,
                "hw_cycles": cycles,
                "hw_macs": macs,
            })
        return output, cycles


# ============================================================================
# CIMModel — high-level multi-layer inference
# ============================================================================
class CIMModel:
    """
    High-level model: define layers, then call predict().

    Example:
        model = CIMModel(driver)
        model.add_fc(784, 128, w1_chunks, b1_u32, zp=0, mult=14, shift=16, relu=True)
        model.add_fc(128, 10,  w2_chunks, b2_u32, zp=0, mult=140, shift=16, relu=False)
        pred, logits = model.predict(image_u8)
    """

    def __init__(self, driver):
        self.drv = driver
        self.layers = []

    def add_fc(self, in_dim, out_dim, w_chunks, bias_u32, zp, mult, shift, relu=True,
               weight_int8=None, bias_int32=None):
        """Add a fully-connected layer.

        Optional weight_int8/bias_int32: original int arrays for per-layer
        verification against golden_model. If None, verify will skip this layer.
        """
        self.layers.append(
            {
                "type": "fc",
                "in_dim": in_dim,
                "out_dim": out_dim,
                "w_chunks": w_chunks,
                "bias_u32": bias_u32,
                "zp": zp,
                "mult": mult,
                "shift": shift,
                "relu": relu,
                "weight_int8": weight_int8,
                "bias_int32": bias_int32,
            }
        )

    def add_conv(
        self,
        weight_4d_int8,
        bias_int32,
        zp,
        mult,
        shift,
        stride=1,
        padding=0,
        relu=True,
    ):
        """
        Add a Conv2D layer (im2col on PS, MVM on PL).

        weight_4d_int8: [C_out, C_in, K_h, K_w] INT8 ndarray
        bias_int32:     [C_out] INT32 ndarray
        """
        C_out, C_in, K_h, K_w = weight_4d_int8.shape
        col_len = C_in * K_h * K_w
        # Reshape to [C_out, col_len] and pack as FC weight
        weight_2d = weight_4d_int8.reshape(C_out, col_len)
        w_chunks = weight_to_chunks(weight_2d)
        bias_u32 = bias_to_u32(bias_int32)

        self.layers.append(
            {
                "type": "conv",
                "C_out": C_out,
                "C_in": C_in,
                "K_h": K_h,
                "K_w": K_w,
                "col_len": col_len,
                "w_chunks": w_chunks,
                "bias_u32": bias_u32,
                "zp": zp,
                "mult": mult,
                "shift": shift,
                "stride": stride,
                "padding": padding,
                "relu": relu,
                "weight_int8": weight_4d_int8,
                "bias_int32": bias_int32,
            }
        )
        self._build_packed_conv_params(self.layers[-1])

    def add_pool(self, kernel=2, stride=2):
        """Add a max-pooling layer (Python-side, no hardware needed)."""
        self.layers.append({"type": "pool", "kernel": kernel, "stride": stride})

    # ------------------------------------------------------------------ #
    # SQ-mapping: block-diagonal weight packing (step 6 Phase 2)
    # ------------------------------------------------------------------ #
    def _build_packed_conv_params(self, layer):
        """Precompute block-diagonal packed weight/bias for multi-pixel MVM.

        When col_len << MAX_IN_DIM and C_out << MAX_OUT_DIM, we can pack
        k_pack output pixels into a single MVM call by replicating the weight
        matrix along the diagonal. Result is cached in layer['_packed'].
        """
        col_len = layer["col_len"]
        C_out = layer["C_out"]
        k_pack = min(MAX_IN_DIM // col_len, MAX_OUT_DIM // C_out)
        if k_pack <= 1:
            layer["_packed"] = None
            return

        # Block-diagonal weight: [k_pack*C_out, k_pack*col_len]
        W_2d = layer["weight_int8"].reshape(C_out, col_len)
        packed_out = k_pack * C_out
        packed_in = k_pack * col_len
        W_packed = np.zeros((packed_out, packed_in), dtype=np.int8)
        for b in range(k_pack):
            W_packed[b * C_out : (b + 1) * C_out,
                     b * col_len : (b + 1) * col_len] = W_2d

        # Tiled bias
        bias_packed = np.tile(layer["bias_int32"], k_pack)

        layer["_packed"] = {
            "k_pack": k_pack,
            "w_chunks": weight_to_chunks(W_packed),
            "bias_u32": bias_to_u32(bias_packed),
            "packed_in_dim": packed_in,
            "packed_out_dim": packed_out,
        }

    def predict(self, input_data, verbose=False, verify=False, run_id=None,
                dump_dir="sw/logs", profile=False):
        """
        Run all layers sequentially.

        Args:
            input_data: UINT8 array — flat [784] for FC-first, or [C,H,W] for Conv-first
            verbose: print per-layer timing
            verify: if True, run golden_model on each layer and compare bit-exact
            run_id: identifier for dump directory; auto-generated if None and verify=True
            dump_dir: base directory for verification dumps (default "sw/logs")
            profile: if True, return (pred, logits, profile_data) with per-phase timing

        Returns:
            (pred_class, final_output) when profile=False
            (pred_class, final_output, profile_data) when profile=True
        """
        x = input_data
        total_cycles = 0

        if verify and run_id is None:
            run_id = _make_run_id()
            print(f"[verify] run_id = {run_id}")

        if profile:
            prof = {"layers": [], "total_ms": 0.0}
            t_total_start = time.perf_counter()

        for i, layer in enumerate(self.layers):
            if layer["type"] == "fc":
                # Input: flat UINT8 array
                if isinstance(x, np.ndarray) and x.ndim > 1:
                    x = x.flatten()
                # If previous output was signed INT8, reinterpret as UINT8
                if isinstance(x, list):
                    x = [int(v) & 0xFF for v in x]
                elif isinstance(x, np.ndarray) and x.dtype == np.int8:
                    x = x.view(np.uint8)

                mvm_timings = [] if profile else None
                if profile: t_layer = time.perf_counter()

                out, cycles = self.drv.infer_fc(
                    x,
                    layer["w_chunks"],
                    layer["bias_u32"],
                    layer["zp"],
                    layer["mult"],
                    layer["shift"],
                    layer["relu"],
                    _timings=mvm_timings,
                )
                total_cycles += cycles
                if verbose:
                    print(
                        f"  Layer {i} (FC {layer['in_dim']}->{layer['out_dim']}): "
                        f"{cycles} cycles"
                    )
                if profile:
                    mt = mvm_timings[0] if mvm_timings else {}
                    prof["layers"].append({
                        "name": f"fc_{layer['in_dim']}x{layer['out_dim']}",
                        "type": "fc",
                        "n_mvm": 1,
                        "k_pack": 1,
                        "im2col_ms": 0.0,
                        "setup_ms": mt.get("configure_ms", 0) + mt.get("load_w_ms", 0) + mt.get("load_b_ms", 0),
                        "load_x_ms": mt.get("load_x_ms", 0),
                        "compute_ms": mt.get("compute_ms", 0),
                        "read_out_ms": mt.get("read_out_ms", 0),
                        "hw_cycles": cycles,
                        "total_ms": (time.perf_counter() - t_layer) * 1000,
                    })
                if verify:
                    self._verify_layer(i, layer, x, out, run_id, dump_dir)
                x = out

            elif layer["type"] == "conv":
                # Input: [C_in, H, W] UINT8
                if isinstance(x, list):
                    x = np.array(x, dtype=np.uint8)
                if x.ndim == 1:
                    raise ValueError(
                        f"Conv layer expects [C,H,W] input, got shape {x.shape}"
                    )

                if profile: t_layer = time.perf_counter()

                # im2col on PS
                if profile: t_im2col = time.perf_counter()
                col_matrix, out_h, out_w = im2col(
                    x, layer["K_h"], layer["K_w"], layer["stride"], layer["padding"]
                )
                if profile: im2col_ms = (time.perf_counter() - t_im2col) * 1000
                n_pixels = out_h * out_w
                C_out = layer["C_out"]
                col_len = layer["col_len"]

                output_flat = np.zeros((C_out, n_pixels), dtype=np.int8)
                layer_cycles = 0
                mvm_timings = [] if profile else None

                packed = layer.get("_packed")
                if packed is not None and packed["k_pack"] > 1:
                    # === Packed MVM path (SQ-mapping) ===
                    k_pack = packed["k_pack"]

                    # One-time setup: configure + load weights + bias
                    if profile: t_setup = time.perf_counter()
                    self.drv.soft_reset()
                    self.drv.configure(
                        packed["packed_in_dim"], packed["packed_out_dim"],
                        layer["zp"], layer["mult"], layer["shift"], layer["relu"],
                    )
                    self.drv.load_weights(packed["w_chunks"])
                    self.drv.load_bias(packed["bias_u32"])
                    if profile: setup_ms = (time.perf_counter() - t_setup) * 1000

                    n_mvm = 0
                    for start in range(0, n_pixels, k_pack):
                        end = min(start + k_pack, n_pixels)
                        batch_size = end - start

                        # Build packed input vector
                        packed_input = np.zeros(k_pack * col_len, dtype=np.uint8)
                        for b in range(batch_size):
                            packed_input[b * col_len : (b + 1) * col_len] = col_matrix[:, start + b]

                        out_packed, cyc = self.drv.infer_fc_input_only(
                            packed_input.tolist(), packed["packed_out_dim"],
                            _timings=mvm_timings,
                        )

                        for b in range(batch_size):
                            output_flat[:, start + b] = out_packed[b * C_out : (b + 1) * C_out]
                        layer_cycles += cyc
                        n_mvm += 1

                    if verbose:
                        print(
                            f"  Layer {i} (Conv {layer['C_in']}ch "
                            f"{layer['K_h']}x{layer['K_w']}->{C_out}ch): "
                            f"{n_mvm} packed MVMs (k_pack={k_pack}), "
                            f"{layer_cycles} cycles"
                        )
                else:
                    # === Unpacked path with weight reuse ===
                    if profile: t_setup = time.perf_counter()
                    self.drv.soft_reset()
                    self.drv.configure(
                        col_len, C_out,
                        layer["zp"], layer["mult"], layer["shift"], layer["relu"],
                    )
                    self.drv.load_weights(layer["w_chunks"])
                    self.drv.load_bias(layer["bias_u32"])
                    if profile: setup_ms = (time.perf_counter() - t_setup) * 1000

                    for p in range(n_pixels):
                        col_vec = col_matrix[:, p].tolist()
                        out_p, cyc = self.drv.infer_fc_input_only(
                            col_vec, C_out, _timings=mvm_timings,
                        )
                        output_flat[:, p] = out_p
                        layer_cycles += cyc

                    n_mvm = n_pixels
                    if verbose:
                        print(
                            f"  Layer {i} (Conv {layer['C_in']}ch "
                            f"{layer['K_h']}x{layer['K_w']}->{C_out}ch): "
                            f"{n_mvm} MVMs, {layer_cycles} cycles"
                        )

                total_cycles += layer_cycles

                if profile:
                    agg = {}
                    for key in ("load_x_ms", "compute_ms", "read_out_ms"):
                        agg[key] = sum(mt.get(key, 0) for mt in mvm_timings) if mvm_timings else 0
                    k_p = packed["k_pack"] if packed else 1
                    prof["layers"].append({
                        "name": f"conv_{layer['C_in']}x{layer['K_h']}x{layer['K_w']}_to_{C_out}",
                        "type": "conv",
                        "n_mvm": n_mvm,
                        "k_pack": k_p,
                        "im2col_ms": im2col_ms,
                        "setup_ms": setup_ms,
                        "load_x_ms": agg["load_x_ms"],
                        "compute_ms": agg["compute_ms"],
                        "read_out_ms": agg["read_out_ms"],
                        "hw_cycles": layer_cycles,
                        "total_ms": (time.perf_counter() - t_layer) * 1000,
                    })

                # Reshape to [C_out, out_h, out_w]
                if verify:
                    y_hw_map = output_flat.reshape(C_out, out_h, out_w)
                    self._verify_layer(i, layer, x, y_hw_map, run_id, dump_dir)
                x = output_flat.reshape(C_out, out_h, out_w)

            elif layer["type"] == "pool":
                # Max pooling — pure Python, no hardware
                if isinstance(x, list):
                    x = np.array(x, dtype=np.int8)
                if isinstance(x, np.ndarray) and x.dtype == np.uint8:
                    x = x.view(np.int8)
                if profile: t_layer = time.perf_counter()
                x = maxpool2d(x, layer["kernel"], layer["stride"])
                x = x.view(np.uint8)
                if verbose:
                    print(
                        f"  Layer {i} (Pool {layer['kernel']}x{layer['kernel']}): "
                        f"-> {x.shape}"
                    )
                if profile:
                    prof["layers"].append({
                        "name": f"pool_{layer['kernel']}x{layer['kernel']}",
                        "type": "pool",
                        "total_ms": (time.perf_counter() - t_layer) * 1000,
                    })

            else:
                raise ValueError(f"Unknown layer type: {layer['type']}")

        # Final prediction
        if isinstance(x, list):
            pred = int(np.argmax(x))
        elif isinstance(x, np.ndarray):
            pred = int(np.argmax(x.flatten()))
        else:
            pred = self.drv.read_pred_class()

        if profile:
            prof["total_ms"] = (time.perf_counter() - t_total_start) * 1000
            return pred, x, prof
        return pred, x

    def clear(self):
        """Remove all layers."""
        self.layers = []

    # ------------------------------------------------------------------ #
    # Per-layer bit-exact verification (step 6 Phase 1)
    # ------------------------------------------------------------------ #
    def _verify_layer(self, layer_idx, layer, x_in, y_hw, run_id, dump_dir):
        """Compare HW layer output against golden_model.py; dump on mismatch."""
        if layer.get("weight_int8") is None or layer.get("bias_int32") is None:
            print(f"  [SKIP] layer_{layer_idx}: raw weight/bias not stored "
                  f"(pass weight_int8=/bias_int32= to add_fc/add_conv)")
            return

        # Lazy import so cim_driver still works without golden_model in path
        import sys
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import golden_model as gm

        activation = "relu" if layer["relu"] else "none"

        if layer["type"] == "fc":
            x_uint8 = np.asarray(x_in, dtype=np.uint8).flatten()
            golden = gm.infer_layer(
                input_uint8=x_uint8,
                weight_int8=layer["weight_int8"],
                bias_int32=layer["bias_int32"],
                zero_point=layer["zp"],
                requant_mult=layer["mult"],
                requant_shift=layer["shift"],
                activation=activation,
            )
            y_golden = np.asarray(golden["output"], dtype=np.int8)
            y_hw_arr = np.asarray(y_hw, dtype=np.int8).flatten()
            tag = f"fc_{layer['in_dim']}x{layer['out_dim']}"

        elif layer["type"] == "conv":
            feat = np.asarray(x_in, dtype=np.uint8)
            C_out, C_in, K_h, K_w = layer["weight_int8"].shape
            out_map, _ = gm.infer_conv_layer(
                feature_map=feat,
                weight_4d=layer["weight_int8"],
                bias_int32=layer["bias_int32"],
                stride=layer["stride"],
                padding=layer["padding"],
                zero_point=layer["zp"],
                requant_mult=layer["mult"],
                requant_shift=layer["shift"],
                activation=activation,
                mode="explicit",
            )
            y_golden = out_map.astype(np.int8).flatten()
            y_hw_arr = np.asarray(y_hw, dtype=np.int8).flatten()
            tag = f"conv_{C_in}x{K_h}x{K_w}_to_{C_out}"
        else:
            print(f"  [SKIP] layer_{layer_idx}: unknown type {layer['type']}")
            return

        # Dump hex files
        layer_dir = os.path.join(dump_dir, run_id, f"layer_{layer_idx}_{tag}")
        os.makedirs(layer_dir, exist_ok=True)

        def _to_hex_bytes(arr):
            return (np.asarray(arr).flatten().astype(np.int64) & 0xFF).astype(np.uint8)

        np.savetxt(os.path.join(layer_dir, "x.hex"),
                   _to_hex_bytes(x_in), fmt="%02x")
        np.savetxt(os.path.join(layer_dir, "y_hw.hex"),
                   _to_hex_bytes(y_hw_arr), fmt="%02x")
        np.savetxt(os.path.join(layer_dir, "y_golden.hex"),
                   _to_hex_bytes(y_golden), fmt="%02x")

        # Compare
        match = np.array_equal(y_hw_arr, y_golden)
        if match:
            print(f"  [MATCH]   layer_{layer_idx} ({tag})  "
                  f"{y_hw_arr.size} elements")
        else:
            diff_mask = (y_hw_arr != y_golden)
            n_diff = int(np.sum(diff_mask))
            diff_idx = np.where(diff_mask)[0]
            with open(os.path.join(layer_dir, "diff.txt"), "w") as f:
                f.write(f"layer_{layer_idx} {tag}: "
                        f"{n_diff} / {y_hw_arr.size} mismatches\n")
                for idx in diff_idx[:50]:
                    f.write(
                        f"  idx={int(idx):6d}  hw={int(y_hw_arr[idx]):4d}  "
                        f"golden={int(y_golden[idx]):4d}  "
                        f"diff={int(y_hw_arr[idx]) - int(y_golden[idx]):+5d}\n"
                    )
            print(f"  [UNMATCH] layer_{layer_idx} ({tag})  "
                  f"{n_diff}/{y_hw_arr.size} diffs  ->  {layer_dir}/diff.txt")
