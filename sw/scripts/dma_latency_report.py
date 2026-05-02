#!/usr/bin/env python3
"""
dma_latency_report.py — DMA-mode latency breakdown analysis

Reads benchmark CSV and produces a latency decomposition report.
Combines: measured end-to-end latency + theoretical DMA bandwidth model
+ per-layer data volume → identifies where 503ms/img is going.

Usage:
    cd sw && source .venv/bin/activate  # optional, python3 works
    python scripts/dma_latency_report.py                        # analyze latest CSV
    python scripts/dma_latency_report.py --csv benchmark_e2e_60mhz_dma.csv
"""
import argparse
import csv
import os
import sys
from collections import namedtuple

# ── Theoretical model ────────────────────────────────────────────
HP0_BW_MBs = 480           # HP0 64-bit @ 60 MHz
AXI_LITE_CSR_US = 15       # ~15 µs per CSR word write (AXI4-Lite round-trip)
# PYNQ DMA overhead: measured ~2.5ms per sendchannel.transfer()+wait() call
# (includes Python→C FFI, kernel DMA engine dispatch, interrupt polling)
PYNQ_DMA_OVERHEAD_MS = 2.5
PS_IM2COL_US = 200         # ~200 µs per Conv2 im2col (28×28→25×196 numpy)

# LeNet-5 packed MVM → n_transfers per layer
# Each MVM call = 3 _stream_load calls (weight+bias+input)
LAYERS = [
    # Conv1: 38 MVMs × 3 = 114 transfers
    {"name": "Conv1 (packed 38×3)",   "n_transfers": 114, "total_bytes": 38 * (6*25+6+784) * 4},
    # Conv2: 20 MVMs × 3 = 60 transfers
    {"name": "Conv2 (packed 20×3)",   "n_transfers": 60,  "total_bytes": 20 * (16*150+16+150*100) * 4},
    # FC1: 1 call × 3
    {"name": "FC1 (256→128)",         "n_transfers": 3,   "total_bytes": (128*256+128+256) * 4},
    # FC2: 1 call × 3
    {"name": "FC2 (128→10)",          "n_transfers": 3,   "total_bytes": (10*128+10+128) * 4},
    # read_output: ~128+256+16+6+10+120+84 ≈ 620 MMIO reads
    {"name": "read_output MMIO",      "n_transfers": 0,   "total_bytes": 0, "mmio_reads": 620},
]

def analyze(csv_path):
    """Read benchmark CSV and compute theoretical breakdown."""
    records = []
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            records.append(row)

    if not records:
        print("No data in CSV")
        return

    row = records[0]
    ms_img = float(row["ms_per_img"])
    n_img = int(row["n_img"])
    acc = float(row["accuracy_pct"])

    # ── Theoretical DMA breakdown ────────────────────────────────
    total_dma_setup_ms = 0
    total_dma_transfer_ms = 0
    total_mmio_ms = 0
    total_n_transfers = 0
    
    for layer in LAYERS:
        n = layer.get("n_transfers", 0)
        total_n_transfers += n
        # PYNQ DMA API overhead: ~2.5ms per transfer call
        total_dma_setup_ms += n * PYNQ_DMA_OVERHEAD_MS
        # DMA wire time: bytes / bandwidth (negligible)
        total_dma_transfer_ms += layer.get("total_bytes", 0) / HP0_BW_MBs / 1000
        # read_output: ~15µs per MMIO read
        total_mmio_ms += layer.get("mmio_reads", 0) * AXI_LITE_CSR_US / 1000

    # ── Compute estimate ─────────────────────────────────────────
    hw_compute_ms = 4

    # ── PS overhead ───────────────────────────────────────────────
    ps_im2col_ms = 0.6       # Conv1 + Conv2 im2col
    ps_pack_ms = 5.0         # weight pack/replicate for packed MVM (numpy block_diag)
    ps_other_ms = 5.0        # predict loop overhead (np.asarray, reshape, etc)

    # ── Total theoretical ────────────────────────────────────────
    total_theory_ms = (
        total_dma_setup_ms + total_dma_transfer_ms +
        hw_compute_ms + ps_im2col_ms + ps_pack_ms + ps_other_ms +
        total_mmio_ms
    )

    # ── Report ───────────────────────────────────────────────────
    print(f"{'='*70}")
    print(f"  DMA Latency Decomposition Report")
    print(f"{'='*70}")
    print(f"  Source:         {csv_path}")
    print(f"  Model:          {row['model']}")
    print(f"  Frequency:      60 MHz")
    print(f"  Images:         {n_img}")
    print(f"  Accuracy:       {acc}%")
    print(f"  Measured:       {ms_img:.1f} ms/img ({row['fps']} fps)")
    print(f"{'='*70}")
    print()
    print(f"  {total_n_transfers} DMA transfers per image predicted by packed-MVM model")
    print(f"  @ {PYNQ_DMA_OVERHEAD_MS}ms PYNQ DMA overhead = {total_dma_setup_ms:.0f}ms DMA overhead")
    print()
    print(f"  {'Component':<35} {'Estimate (ms)':>14} {'% of measured':>14}")
    print(f"  {'-'*63}")

    components = [
        ("PYNQ DMA API overhead (183 calls)",  total_dma_setup_ms),
        ("DMA data transfer (wire time)",       total_dma_transfer_ms),
        ("read_output serial MMIO (620 reads)", total_mmio_ms),
        ("Hardware compute (MVM + ReLU)",       hw_compute_ms),
        ("PS im2col (numpy reshape)",           ps_im2col_ms),
        ("PS weight pack/replicate (SQ-map)",   ps_pack_ms),
        ("PS predict loop overhead",            ps_other_ms),
    ]

    accounted = 0
    for name, val_ms in components:
        pct = val_ms / ms_img * 100
        accounted += val_ms
        print(f"  {name:<30} {val_ms:>14.2f} {pct:>13.1f}%")

    unaccounted = ms_img - accounted
    print(f"  {'─'*58}")
    if unaccounted > 0:
        print(f"  {'UNACCOUNTED (likely PS Python/readout)':<30} {unaccounted:>14.2f} {unaccounted/ms_img*100:>13.1f}%")
    else:
        print(f"  {'TOTAL (theoretical)':<30} {accounted:>14.2f} {accounted/ms_img*100:>13.1f}%")
    print(f"  {'TOTAL (measured)':<30} {ms_img:>14.2f} {100:>13.1f}%")
    print()
    print(f"  {'─'*70}")
    print(f"  Diagnostic Checklist")
    print(f"  {'─'*70}")

    issues = []
    if total_dma_setup_ms > ms_img * 0.5:
        issues.append(f"  ⚠️  DMA API overhead dominant ({total_dma_setup_ms:.0f}ms, {total_dma_setup_ms/ms_img*100:.0f}%)")
        issues.append(f"     → {total_n_transfers} DMA calls × {PYNQ_DMA_OVERHEAD_MS}ms PYNQ overhead")
        issues.append(f"     → FIX: merge weight+bias+input into single DMA transfer per MVM call")
    if total_dma_transfer_ms < 1:
        issues.append(f"  ✅ DMA wire time negligible ({total_dma_transfer_ms:.1f}ms) — raw bandwidth is NOT the problem")
    if total_mmio_ms > 5:
        issues.append(f"  ⚠️  read_output MMIO ({total_mmio_ms:.0f}ms) — could batch reads or DMA S2MM")
    if unaccounted > ms_img * 0.15:
        issues.append(f"  ❓ {unaccounted:.0f}ms unaccounted — may include Python GC, np.array allocation, etc")

    if not issues:
        issues.append("  ✅ No obvious bottlenecks identified")
    for issue in issues:
        print(issue)

    print()
    print(f"  {'─'*70}")
    print(f"  Next Steps (in priority order)")
    print(f"  {'─'*70}")
    print(f"  1. 🔴 P0: Merge DMA transfers — combine weight+bias+input")
    print(f"     → 183 calls → ~61 calls, estimate ~150ms saved")
    print(f"     → RTL: cim_axi_stream_sink.sv already has dest routing, just change driver")
    print(f"  2. 🔴 P0: Replace read_output MMIO with DMA S2MM")
    print(f"     → 620 serial MMIO reads → 1 DMA read-back transfer")
    print(f"  3. 🟡 P1: Larger DMA buffer — reduce chunked transfers")
    print(f"     → current 16KB limit, could bump to 64KB or 256KB")
    print(f"  4. 🟡 P1: Re-run benchmark with enhanced profiler (already updated)")
    print(f"     → captures per-layer dma_setup_ms / dma_transfer_ms")
    print(f"  5. 🟢 P2: im2col in C (C extension or Cython)")
    print(f"     → numpy overhead significant for packed MVM weight construction")
    print(f"{'='*70}")


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="DMA latency decomposition report")
    p.add_argument("--csv", default="benchmark_e2e_60mhz_dma.csv",
                   help="Benchmark CSV file (default: benchmark_e2e_60mhz_dma.csv)")
    args = p.parse_args()

    csv_path = args.csv
    if not os.path.isabs(csv_path):
        # Try sw/ directory
        script_dir = os.path.dirname(os.path.abspath(__file__))
        sw_dir = os.path.dirname(script_dir)  # sw/scripts → sw/
        csv_path = os.path.join(sw_dir, csv_path)

    if not os.path.exists(csv_path):
        print(f"Error: {csv_path} not found")
        sys.exit(1)

    analyze(csv_path)
