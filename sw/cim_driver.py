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
_LOGIT_BASE = 0x100
_MEM_INPUT = 0x1000
_MEM_BIAS = 0x2000


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


# ============================================================================
# CIMDriver — low-level hardware interface
# ============================================================================
class CIMDriver:
    """Low-level driver for CIM accelerator via AXI4-Lite MMIO."""

    def __init__(self, bitstream_path="cim_soc.bit", load=True):
        """
        Args:
            bitstream_path: path to .bit file (must have matching .hwh)
            load: if True, load overlay immediately
        """
        if not _HAS_PYNQ:
            raise RuntimeError("pynq not available — run this on PYNQ-Z2")
        if load:
            self.overlay = Overlay(bitstream_path)
        self.mmio = MMIO(_BASE, _MMIO_SIZE)
        self.soft_reset()

    def soft_reset(self):
        self.mmio.write(_CTRL, 0x4)

    def _clear_done(self):
        self.mmio.write(_CTRL, 0x2)

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

    def load_weights(self, chunks):
        """Load weight chunks via burst DMA."""
        m = self.mmio
        m.write(_WDMA_ADDR, 0)
        m.write(_WDMA_CTRL, 0x02)  # burst enable
        for c in chunks:
            m.write(_WDMA_DATA, int(c))
        m.write(_WDMA_CTRL, 0x00)

    def load_bias(self, bias_u32):
        """Load INT32 bias values."""
        for i, b in enumerate(bias_u32):
            self.mmio.write(_MEM_BIAS + 4 * i, int(b) & 0xFFFFFFFF)

    def load_input(self, data_u8):
        """Load UINT8 input vector (auto-pads to multiple of 16)."""
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

    def infer_fc(self, input_u8, w_chunks, bias_u32, zp, mult, shift, relu=True):
        """
        Run one FC layer end-to-end.

        Args:
            input_u8: list/array of UINT8 input values
            w_chunks: list of 32-bit weight chunk words (from weight_to_chunks)
            bias_u32: list of unsigned 32-bit bias words (from bias_to_u32)
            zp: hardware zero point (signed int)
            mult, shift: requantization parameters
            relu: True for ReLU activation

        Returns:
            output: list of signed INT8 values
            cycles: clock cycles used
        """
        in_dim = len(input_u8)
        out_dim = len(bias_u32)

        self.soft_reset()
        self.configure(in_dim, out_dim, zp, mult, shift, relu)
        self.load_weights(w_chunks)
        self.load_bias(bias_u32)
        self.load_input(input_u8)
        cycles, macs = self.start_and_wait()
        output = self.read_output(out_dim)
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

    def add_fc(self, in_dim, out_dim, w_chunks, bias_u32, zp, mult, shift, relu=True):
        """Add a fully-connected layer."""
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
            }
        )

    def predict(self, input_data, verbose=False):
        """
        Run all layers sequentially.

        Args:
            input_data: UINT8 array — flat [784] for FC-first, or [C,H,W] for Conv-first
            verbose: print per-layer timing

        Returns:
            pred_class: int (argmax of final layer)
            final_output: list of signed INT8 (final layer logits)
        """
        x = input_data
        total_cycles = 0

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

                out, cycles = self.drv.infer_fc(
                    x,
                    layer["w_chunks"],
                    layer["bias_u32"],
                    layer["zp"],
                    layer["mult"],
                    layer["shift"],
                    layer["relu"],
                )
                total_cycles += cycles
                if verbose:
                    print(
                        f"  Layer {i} (FC {layer['in_dim']}→{layer['out_dim']}): "
                        f"{cycles} cycles"
                    )
                x = out

            elif layer["type"] == "conv":
                # Input: [C_in, H, W] UINT8
                if isinstance(x, list):
                    x = np.array(x, dtype=np.uint8)
                if x.ndim == 1:
                    raise ValueError(
                        f"Conv layer expects [C,H,W] input, got shape {x.shape}"
                    )

                # im2col on PS
                col_matrix, out_h, out_w = im2col(
                    x, layer["K_h"], layer["K_w"], layer["stride"], layer["padding"]
                )
                n_pixels = out_h * out_w
                C_out = layer["C_out"]

                if verbose:
                    print(
                        f"  Layer {i} (Conv {layer['C_in']}ch "
                        f"{layer['K_h']}x{layer['K_w']}→{C_out}ch): "
                        f"{n_pixels} MVMs, ",
                        end="",
                    )

                # Per-pixel MVM on PL
                output_flat = np.zeros((C_out, n_pixels), dtype=np.int8)
                layer_cycles = 0
                for p in range(n_pixels):
                    col_vec = col_matrix[:, p].tolist()
                    out_p, cyc = self.drv.infer_fc(
                        col_vec,
                        layer["w_chunks"],
                        layer["bias_u32"],
                        layer["zp"],
                        layer["mult"],
                        layer["shift"],
                        layer["relu"],
                    )
                    output_flat[:, p] = out_p
                    layer_cycles += cyc

                total_cycles += layer_cycles
                if verbose:
                    print(f"{layer_cycles} cycles")

                # Reshape to [C_out, out_h, out_w]
                x = output_flat.reshape(C_out, out_h, out_w)

            else:
                raise ValueError(f"Unknown layer type: {layer['type']}")

        # Final prediction
        if isinstance(x, list):
            pred = int(np.argmax(x))
        elif isinstance(x, np.ndarray):
            pred = int(np.argmax(x.flatten()))
        else:
            pred = self.drv.read_pred_class()

        return pred, x

    def clear(self):
        """Remove all layers."""
        self.layers = []
