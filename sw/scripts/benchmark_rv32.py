#!/usr/bin/env python3
"""
benchmark_rv32.py — PicoRV32 CIM SoC end-to-end batch benchmark

Usage (on PYNQ):
    python scripts/benchmark_rv32.py
    python scripts/benchmark_rv32.py --n_images 200
    python scripts/benchmark_rv32.py --data-dir small_mlp_data --firmware firmware.hex

Protocol:
  PS loads firmware into FW BRAM (0x4000_0000), controls PicoRV32 via GPIO,
  feeds images through handshake at FW BRAM offset 0x6000, reads results
  from Result BRAM (0x4200_0000).

Output:
    Console: formatted result table
    File:    results/benchmark_rv32_<timestamp>.csv
"""

import argparse
import glob
import os
import sys
import time
import csv
import struct
import numpy as np
from datetime import datetime

# ============================================================================
# PicoRV32 system constants
# ============================================================================
FW_BRAM_BASE = 0x40000000  # PS side: FW BRAM port B
FW_BRAM_SIZE = 0x8000  # 32 KB
RES_BRAM_BASE = 0x42000000  # PS side: Result BRAM port B
GPIO_BASE = 0x43000000  # AXI GPIO: bit[0] = cpu_rst_n
IMAGE_BUF_OFFSET = 0x6000  # FW BRAM offset for PS-loaded image

RES_MAGIC = 0xC1AA0001
RES_GO_SIGNAL = 0x00000000
RES_STOP_SIGNAL = 0xDEADBEEF


# ============================================================================
# Helpers
# ============================================================================
def read_hex_u8(path):
    with open(path) as f:
        return [int(l.strip(), 16) & 0xFF for l in f if l.strip()]


def read_firmware_hex(path):
    """Read Verilog-format firmware hex file (32-bit words)."""
    with open(path) as f:
        return [int(l.strip(), 16) for l in f if l.strip() and l.strip() != ""]


# ============================================================================
# PicoRV32 driver
# ============================================================================
class RV32Driver:
    """PS-side driver for PicoRV32 CIM SoC."""

    def __init__(self, bitstream_path):
        from pynq import MMIO, Bitstream
        import os as _os

        _ext = _os.path.splitext(bitstream_path)[1].lower()

        # Load bitstream (try Overlay first, fall back to Bitstream)
        try:
            from pynq import Overlay

            self.overlay = Overlay(bitstream_path, ignore_version=True)
            print(f"[RV32] Overlay loaded from {bitstream_path}")
        except Exception as _e:
            _msg = str(_e)
            if (
                "not a valid input" not in _msg
                and "Unknown file format" not in _msg
                and "sysdef.xml" not in _msg
                and "tuple index" not in _msg
            ):
                raise
            # Fallback: Bitstream.download() + MMIO
            print(f"[RV32] Overlay() failed, falling back to Bitstream.download()")
            if _ext == ".xsa":
                import zipfile as _zf

                with _zf.ZipFile(bitstream_path, "r") as _z:
                    _bit_name = [n for n in _z.namelist() if n.endswith(".bit")][0]
                    _z.extract(_bit_name, "/tmp")
                    _bit_path = f"/tmp/{_bit_name}"
            else:
                _bit_path = bitstream_path
            Bitstream(_bit_path).download()
            print(f"[RV32] Bitstream downloaded OK")
            self.overlay = type("_DummyOL", (), {"ip_dict": {}})()

        # MMIO for three regions
        self.mmio_fw = MMIO(FW_BRAM_BASE, FW_BRAM_SIZE)
        self.mmio_res = MMIO(RES_BRAM_BASE, 0x1000)
        self.mmio_gpio = MMIO(GPIO_BASE, 0x1000)

    def cpu_hold(self):
        """Hold PicoRV32 in reset (cpu_rst_n=0)."""
        self.mmio_gpio.write(0, 0)

    def cpu_release(self):
        """Release PicoRV32 reset (cpu_rst_n=1)."""
        self.mmio_gpio.write(0, 1)

    def load_firmware(self, fw_words):
        """Write firmware words to FW BRAM via PS port B."""
        for i, w in enumerate(fw_words):
            self.mmio_fw.write(i * 4, w)
        print(f"[RV32] Firmware loaded: {len(fw_words)} words")

    def load_image(self, img_u8, label):
        """Write image + label to FW BRAM image buffer.
        Layout: [0..3] = label (uint32 LE), [4..787] = pixels (784 × uint8)
        """
        buf = struct.pack("<I", label)
        buf += bytes(img_u8[:784].tolist())
        # Write as 32-bit words
        for i in range(0, len(buf), 4):
            word = int.from_bytes(buf[i : i + 4], "little")
            self.mmio_fw.write(IMAGE_BUF_OFFSET + i, word)

    def signal_go(self):
        """Write go signal to Result BRAM[0]."""
        self.mmio_res.write(0, RES_GO_SIGNAL)

    def signal_stop(self):
        """Write stop signal to Result BRAM[0]."""
        self.mmio_res.write(0, RES_STOP_SIGNAL)

    def wait_for_done(self, timeout_ms=5000):
        """Poll Result BRAM[0] for RES_MAGIC. Returns True on success."""
        for _ in range(timeout_ms * 100):  # ~10us per iteration
            if self.mmio_res.read(0) == RES_MAGIC:
                return True
        return False

    def read_result(self):
        """Read prediction + logits + diagnostics from Result BRAM."""
        pred = self.mmio_res.read(4)
        expected = self.mmio_res.read(8)
        match = self.mmio_res.read(12)
        logits = []
        for i in range(10):
            v = self.mmio_res.read(16 + 4 * i)
            v32 = int(v) & 0xFFFFFFFF  # mask to 32-bit
            if v32 & 0x80000000:
                v32 = v32 - 0x100000000  # sign-extend
            logits.append(v32)
        # Diagnostics (firmware echoes first image bytes for verification)
        diag_expected = self.mmio_res.read(56)  # RES_WORD(14)
        diag_pix_sum = self.mmio_res.read(60)  # RES_WORD(15)
        diag_pix0 = self.mmio_res.read(64)  # RES_WORD(16)
        diag_pix1 = self.mmio_res.read(68)  # RES_WORD(17)
        return {
            "pred": pred,
            "expected": expected,
            "match": match,
            "logits": logits,
            "diag_expected": diag_expected,
            "diag_pix_sum": diag_pix_sum,
            "diag_pix0": diag_pix0,
            "diag_pix1": diag_pix1,
        }


# ============================================================================
# Main benchmark
# ============================================================================
def main():
    parser = argparse.ArgumentParser(description="PicoRV32 CIM SoC batch benchmark")
    parser.add_argument(
        "--model",
        default="mlp",
        choices=["mlp"],
        help="Model: mlp = 784→16→10 small_mlp (default). "
        "Firmware must match the model!",
    )
    parser.add_argument("--bitstream", default="cim_rv32_soc.xsa")
    parser.add_argument(
        "--firmware",
        default=None,
        help="Firmware hex file (default: firmware_<model>.hex)",
    )
    parser.add_argument(
        "--data-dir", default=None, help="Data directory (default: auto from --model)"
    )
    parser.add_argument(
        "--n-images",
        type=int,
        default=None,
        help="Number of test images (default: all in test_images/)",
    )
    parser.add_argument("--out-dir", default="results")
    parser.add_argument(
        "--out-name",
        default=None,
        help="Exact CSV basename (no extension). If omitted, a "
        "timestamped name benchmark_rv32_<ts> is used.",
    )
    args = parser.parse_args()

    # Auto-select data_dir and firmware based on model
    model_defaults = {
        "mlp": {"data_dir": "small_mlp_data", "firmware": "firmware.hex"},
    }
    cfg = model_defaults.get(args.model, model_defaults["mlp"])
    if args.data_dir is None:
        args.data_dir = cfg["data_dir"]
    if args.firmware is None:
        args.firmware = cfg["firmware"]

    print(f"Config: model={args.model}, bitstream={args.bitstream}")
    print(f"        firmware={args.firmware}, data_dir={args.data_dir}")

    # Discover test images
    img_dir = os.path.join(args.data_dir, "test_images")
    img_files = sorted(glob.glob(os.path.join(img_dir, "img_????.hex")))
    if not img_files:
        print(f"ERROR: no test images found in {img_dir}", file=sys.stderr)
        sys.exit(1)

    n = min(args.n_images or len(img_files), len(img_files))
    img_files = img_files[:n]
    print(f"Benchmark: PicoRV32, n={n}, data_dir={args.data_dir}")

    # Load firmware binary
    fw_words = read_firmware_hex(args.firmware)
    print(f"Firmware: {len(fw_words)} words ({os.path.getsize(args.firmware)} bytes)")

    # Initialize driver
    drv = RV32Driver(args.bitstream)

    # --- Begin benchmark ---
    correct = 0
    wrong_list = []
    timings = []

    # Initial setup: hold CPU, load firmware + first image
    drv.cpu_hold()
    drv.load_firmware(fw_words)

    t_start = time.time()

    for idx, img_path in enumerate(img_files):
        name = os.path.basename(img_path).replace(".hex", "")
        img_u8 = np.array(read_hex_u8(img_path), dtype=np.uint8)
        label = int(open(os.path.join(img_dir, f"{name}_label.txt")).read().strip())

        t0 = time.perf_counter()

        # Load image + signal go
        drv.load_image(img_u8, label)
        drv.signal_go()

        if idx == 0:
            # First image: release CPU (firmware has weights to load)
            drv.cpu_release()

        # Wait for inference complete
        if not drv.wait_for_done():
            print(f"  TIMEOUT: {name}", file=sys.stderr)
            drv.signal_stop()
            break

        # Read result
        result = drv.read_result()
        pred = result["pred"]
        t1 = time.perf_counter()
        ms = (t1 - t0) * 1000
        timings.append(ms)

        # Show diagnostics for first image
        if idx == 0:
            print(f"\n  [DIAG] Image {name}: label={label}")
            print(
                f"  [DIAG] FW reads: expected={result['diag_expected']} "
                f"pix[0:4]={result['diag_pix0']:08x} "
                f"pix[4:8]={result['diag_pix1']:08x} "
                f"pix_sum(first 16)={result['diag_pix_sum']}"
            )
            # PS side: show what we wrote
            expected_ps = label
            pix0_ps = int.from_bytes(bytes(img_u8[:4].tolist()), "little")
            pix1_ps = int.from_bytes(bytes(img_u8[4:8].tolist()), "little")
            pix_sum_ps = sum(int(b) for b in img_u8[:16])
            print(
                f"  [DIAG] PS wrote: expected={expected_ps} "
                f"pix[0:4]={pix0_ps:08x} "
                f"pix[4:8]={pix1_ps:08x} "
                f"pix_sum(first 16)={pix_sum_ps}"
            )

        if pred == label:
            correct += 1
        else:
            wrong_list.append((name, pred, label))
            if len(wrong_list) <= 5:
                print(f"  WRONG {name}: pred={pred} label={label}")

    # Signal end of benchmark
    drv.signal_stop()

    t_end = time.time()

    # --- Results ---
    total_s = t_end - t_start
    ms_per_img = total_s / n * 1000
    fps = n / total_s
    accuracy = correct / n * 100

    col = [
        ("Model", 12),
        ("n_img", 6),
        ("total_s", 9),
        ("ms/img", 9),
        ("fps", 7),
        ("accuracy", 10),
    ]
    hdr = "  ".join(f"{name:<{w}}" for name, w in col)
    sep = "  ".join("-" * w for _, w in col)
    vals = [
        "PicoRV32",
        str(n),
        f"{total_s:.2f}s",
        f"{ms_per_img:.1f}",
        f"{fps:.2f}",
        f"{correct}/{n} ({accuracy:.1f}%)",
    ]
    row = "  ".join(f"{v:<{w}}" for v, (_, w) in zip(vals, col))

    print("\n" + sep)
    print(hdr)
    print(sep)
    print(row)
    print(sep)

    # Per-image timing stats
    if timings:
        t_sorted = sorted(timings)
        print(
            f"\nPer-image timing (ms): "
            f"min={t_sorted[0]:.1f}  p50={t_sorted[len(t_sorted) // 2]:.1f}  "
            f"avg={sum(timings) / len(timings):.1f}  max={t_sorted[-1]:.1f}"
        )

    if wrong_list:
        print(f"\nWrong predictions ({len(wrong_list)}):")
        for name, pred, label in wrong_list[:10]:
            print(f"  {name}: pred={pred} label={label}")

    # --- CSV export ---
    os.makedirs(args.out_dir, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    # Auto-name: picorv32_{data_dir}. PicoRV32 is always MMIO-style (no DMA,
    # no batch, no fusion), so those optional tags are always empty and the
    # name collapses to the controller prefix + data dir. Explicit --out-name
    # overrides.
    if args.out_name:
        base = args.out_name
    else:
        data_tag = os.path.basename(os.path.normpath(args.data_dir))
        base = f"picorv32_{data_tag}"
    csv_path = os.path.join(args.out_dir, f"{base}.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            [
                "model",
                "n_img",
                "total_s",
                "ms_per_img",
                "fps",
                "correct",
                "accuracy_pct",
                "min_ms",
                "p50_ms",
                "avg_ms",
                "max_ms",
            ]
        )
        writer.writerow(
            [
                "rv32_mlp",
                n,
                f"{total_s:.3f}",
                f"{ms_per_img:.2f}",
                f"{fps:.3f}",
                correct,
                f"{accuracy:.2f}",
                f"{min(timings):.1f}" if timings else "",
                f"{sorted(timings)[len(timings) // 2]:.1f}" if timings else "",
                f"{sum(timings) / len(timings):.1f}" if timings else "",
                f"{max(timings):.1f}" if timings else "",
            ]
        )
    print(f"\nCSV saved: {csv_path}")


if __name__ == "__main__":
    main()
