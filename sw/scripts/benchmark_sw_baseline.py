#!/usr/bin/env python3
"""
benchmark_sw_baseline.py — ARM Cortex-A9 pure-software (NumPy) baseline.

Runs the SAME INT8 integer inference that the hardware performs, but entirely
in NumPy on the ARM PS, over the SAME 200 real MNIST test images that the
hardware benchmarks use. Reports per-image SOFTWARE COMPUTE time so it can be
compared, at the same 100 MHz cycle-count basis, against the CIM compute core.

This produces the data behind Thesis §"软件基线对比":
    - MLP        784 -> 128 -> 10
    - LeNet-5    conv1 -> pool -> conv2 -> pool -> fc3 -> fc4 -> fc5
    - small_mlp  784 -> 16 -> 10

Two software regimes are timed (relevant only to conv layers):
    sequential : one MVM per output pixel — matches the hardware execution model
    batched    : one big GEMM per conv layer — best-case ARM BLAS upper bound
FC-only models (mlp / small_mlp) have a single regime (one GEMV per layer).

IMPORTANT — run this ON THE PYNQ BOARD (ARM Cortex-A9), not on a desktop.
The whole point is to measure ARM CPU time. Running it on an x86 host gives a
meaningless number. No bitstream / Overlay is loaded here — it is pure CPU.

Usage (on PYNQ, from sw/):
    # compare one model against its HW end-to-end CSV:
    python scripts/benchmark_sw_baseline.py --model lenet5 --data-dir lenet5_data \
           --hw-csv results/arm_dma_batch_lenet5_data.csv

    # all three, auto-finding the matching HW CSV in a directory:
    python scripts/benchmark_sw_baseline.py --model all --hw-csv-dir ../Thesis/data

Output:
    Console : SW compute time + TWO speedup families:
                (1) pure-compute  (HW MAC-only vs SW matmul)  — symmetric, the 43x family
                (2) end-to-end    (HW full+DMA vs SW matmul)  — the 0.75x/0.93x/0.16x family
    Files   : results/sw_baseline_<model>_<ts>.json     (full detail per model)
              results/sw_baseline_summary_<ts>.csv       (one row per model x regime)
              results/sw_baseline_ALL_<ts>.json          (combined)

Calibers (read carefully — this was a source of confusion):
  - PURE-COMPUTE speedup: both sides are compute-only (HW = perf-counter MAC
    cycles / freq; SW = NumPy matmul time). Fair, symmetric. HW wins (>1x).
  - END-TO-END comparison: HW side is the FULL measured wall time from the CSV
    (includes DMA + Python scheduling); SW side is still compute-only. The
    hardware is therefore HANDICAPPED in this ratio. Use it to show the honest
    "system has not yet beaten lean CPU compute" point, NOT a like-for-like race.

IMPORTANT — run this ON THE PYNQ BOARD (ARM Cortex-A9), not on a desktop.
No bitstream / Overlay is loaded here — it is pure CPU. The HW numbers come
from the CSV you pass / auto-discover, not from running hardware in this script.
"""

import argparse
import glob
import json
import os
import sys
import time
from datetime import datetime

import numpy as np

# ============================================================================
# Hardware compute-core cycle counts (from on-board performance counters).
# These are the SAME numbers reported in the thesis cycle tables. The SW/HW
# speedup is SW_time / (cycles / FREQ). FREQ MUST match the thesis (100 MHz).
# ============================================================================
HW_FREQ_MHZ = 100  # <-- thesis reporting frequency. (Was 60 in the old notebook.)

HW_CYCLES = {
    "mlp": {"total": 3282, "layers": {"fc1": 3136, "fc2": 146}},
    "small_mlp": {"total": 422, "layers": {"fc1": 392, "fc2": 30}},  # 784->16->10
    "lenet5": {
        "total": 76034,
        "layers": {"conv1": 63360, "conv2": 10112, "fc3": 1552, "fc4": 876, "fc5": 134},
    },
}

N_RUNS_DEFAULT = 30  # timing repeats per image (median taken); ARM is slow, keep modest
WARMUP = 3


# ============================================================================
# INT8 integer primitives — bit-identical to sw/golden_model.py
# (replicated here so this script is standalone and its timing loop is tight)
# ============================================================================
def apply_zero_point(x_uint8, zp):
    x_eff = x_uint8.astype(np.int32) - zp
    return np.clip(x_eff, 0, 511).astype(np.int32)


def requantize_int32_to_int8(x, mult, rshift):
    prod = x.astype(np.int64) * np.int64(mult)
    if rshift == 0:
        shifted = prod
    else:
        shifted = (prod + (np.int64(1) << (rshift - 1))) >> rshift
    return np.clip(shifted, -128, 127).astype(np.int8)


def fc_layer(x_uint8, w_int8, b_int32, zp, mult, shift, relu):
    """One fully-connected layer, INT8 in / INT8 out (matches CIM datapath)."""
    x_eff = apply_zero_point(x_uint8, zp)
    acc = w_int8.astype(np.int32) @ x_eff + b_int32.astype(np.int32)
    if relu:
        acc = np.maximum(acc, 0)
    return requantize_int32_to_int8(acc, mult, shift)


def im2col(feat_u8, K, stride, pad):
    """feat_u8: [C,H,W] uint8 -> col [C*K*K, n_pix] uint8, plus (out_h,out_w)."""
    C, H, W = feat_u8.shape
    if pad:
        feat_u8 = np.pad(feat_u8, ((0, 0), (pad, pad), (pad, pad)))
        H, W = H + 2 * pad, W + 2 * pad
    oh = (H - K) // stride + 1
    ow = (W - K) // stride + 1
    col = np.empty((C * K * K, oh * ow), dtype=np.uint8)
    idx = 0
    for y in range(oh):
        for x in range(ow):
            patch = feat_u8[:, y * stride : y * stride + K, x * stride : x * stride + K]
            col[:, idx] = patch.reshape(-1)
            idx += 1
    return col, oh, ow


def maxpool2x2(feat_i8):
    """feat_i8: [C,H,W] -> [C,H//2,W//2] 2x2 stride-2 max. Inputs are >=0 (post-ReLU)."""
    C, H, W = feat_i8.shape
    f = feat_i8[:, : H // 2 * 2, : W // 2 * 2]
    f = f.reshape(C, H // 2, 2, W // 2, 2)
    return f.max(axis=(2, 4))


def conv_layer_seq(feat_u8, w2d, b, zp, mult, shift, K, stride, pad, relu):
    """Sequential conv: one MVM per output pixel (matches hardware)."""
    col, oh, ow = im2col(feat_u8, K, stride, pad)
    n_pix = oh * ow
    C_out = w2d.shape[0]
    out = np.empty((C_out, n_pix), dtype=np.int8)
    for p in range(n_pix):
        out[:, p] = fc_layer(col[:, p], w2d, b, zp, mult, shift, relu)
    return out.reshape(C_out, oh, ow)


def conv_layer_batched(feat_u8, w2d, b, zp, mult, shift, K, stride, pad, relu):
    """Batched conv: single GEMM over all pixels (ARM BLAS best case)."""
    col, oh, ow = im2col(feat_u8, K, stride, pad)
    x_eff = apply_zero_point(col, zp)  # [col_len, n_pix]
    acc = w2d.astype(np.int32) @ x_eff + b.astype(np.int32)[:, None]
    if relu:
        acc = np.maximum(acc, 0)
    flat = requantize_int32_to_int8(acc.reshape(-1), mult, shift)
    return flat.reshape(w2d.shape[0], oh, ow)


# ============================================================================
# Per-model forward passes (return prediction; used for both accuracy + timing)
# ============================================================================
def forward_mlp(img_u8, P):
    h = fc_layer(img_u8, P["w1"], P["b1"], P["zp1"], P["m1"], P["s1"], relu=True)
    o = fc_layer(
        h.view(np.uint8), P["w2"], P["b2"], P["zp2"], P["m2"], P["s2"], relu=False
    )
    return int(np.argmax(o))


def forward_lenet(img_u8, P, conv_mode):
    conv = conv_layer_seq if conv_mode == "sequential" else conv_layer_batched
    feat = img_u8.reshape(1, 28, 28)
    c1 = conv(
        feat, P["w_c1"], P["b_c1"], P["zp_c1"], P["m_c1"], P["s_c1"], 5, 1, 0, True
    )
    p1 = maxpool2x2(c1)
    c2 = conv(
        p1.view(np.uint8),
        P["w_c2"],
        P["b_c2"],
        P["zp_c2"],
        P["m_c2"],
        P["s_c2"],
        5,
        1,
        0,
        True,
    )
    p2 = maxpool2x2(c2)
    flat = p2.reshape(-1).view(np.uint8)  # 16*4*4 = 256
    f3 = fc_layer(
        flat, P["w_f3"], P["b_f3"], P["zp_f3"], P["m_f3"], P["s_f3"], relu=True
    )
    f4 = fc_layer(
        f3.view(np.uint8),
        P["w_f4"],
        P["b_f4"],
        P["zp_f4"],
        P["m_f4"],
        P["s_f4"],
        relu=True,
    )
    f5 = fc_layer(
        f4.view(np.uint8),
        P["w_f5"],
        P["b_f5"],
        P["zp_f5"],
        P["m_f5"],
        P["s_f5"],
        relu=False,
    )
    return int(np.argmax(f5))


# ============================================================================
# Model loaders — read the SAME quant params the HW benchmarks use
# ============================================================================
def load_mlp_params(data_dir):
    """mnist_real_data / small_mlp_data: hex tiles + quant_params.hex.
    We need raw INT8 weight matrices (not tile chunks) for NumPy GEMV, so we
    rebuild them from the per-layer .npy if present, else from *_weight.hex."""
    # Prefer a plain .npz/.npy dump if the data dir has one
    npz = os.path.join(data_dir, "mlp_qparams.npz")
    if os.path.exists(npz):
        d = np.load(npz)
        return {
            "w1": d["fc1_weight"].astype(np.int8),
            "b1": d["fc1_bias"].astype(np.int32),
            "zp1": int(d["fc1_zp"]),
            "m1": int(d["fc1_mult"]),
            "s1": int(d["fc1_shift"]),
            "w2": d["fc2_weight"].astype(np.int8),
            "b2": d["fc2_bias"].astype(np.int32),
            "zp2": int(d["fc2_zp"]),
            "m2": int(d["fc2_mult"]),
            "s2": int(d["fc2_shift"]),
        }
    raise FileNotFoundError(
        f"{npz} not found.\n"
        "This SW baseline needs the raw INT8 weight matrices, not the packed "
        "tile .hex files. Re-export them from your quantize script, e.g. add at "
        "the end of mnist_quantize.py / small_mlp_quantize.py:\n"
        "    np.savez('mlp_qparams.npz', fc1_weight=w1, fc1_bias=b1, fc1_zp=zp1,\n"
        "             fc1_mult=m1, fc1_shift=s1, fc2_weight=w2, fc2_bias=b2,\n"
        "             fc2_zp=zp2, fc2_mult=m2, fc2_shift=s2)\n"
        "(w1 shape [hidden,784] INT8, w2 shape [10,hidden] INT8.)"
    )


def load_lenet_params(data_dir):
    d = np.load(os.path.join(data_dir, "lenet5_qparams.npz"))

    def w2d(key):  # [C_out,C_in,K,K] -> [C_out, C_in*K*K]
        w = d[key]
        return w.reshape(w.shape[0], -1).astype(np.int8)

    return {
        "w_c1": w2d("conv1_weight"),
        "b_c1": d["conv1_bias"].astype(np.int32),
        "zp_c1": int(d["conv1_zp"]),
        "m_c1": int(d["conv1_mult"]),
        "s_c1": int(d["conv1_shift"]),
        "w_c2": w2d("conv2_weight"),
        "b_c2": d["conv2_bias"].astype(np.int32),
        "zp_c2": int(d["conv2_zp"]),
        "m_c2": int(d["conv2_mult"]),
        "s_c2": int(d["conv2_shift"]),
        "w_f3": d["fc3_weight"].astype(np.int8),
        "b_f3": d["fc3_bias"].astype(np.int32),
        "zp_f3": int(d["fc3_zp"]),
        "m_f3": int(d["fc3_mult"]),
        "s_f3": int(d["fc3_shift"]),
        "w_f4": d["fc4_weight"].astype(np.int8),
        "b_f4": d["fc4_bias"].astype(np.int32),
        "zp_f4": int(d["fc4_zp"]),
        "m_f4": int(d["fc4_mult"]),
        "s_f4": int(d["fc4_shift"]),
        "w_f5": d["fc5_weight"].astype(np.int8),
        "b_f5": d["fc5_bias"].astype(np.int32),
        "zp_f5": int(d["fc5_zp"]),
        "m_f5": int(d["fc5_mult"]),
        "s_f5": int(d["fc5_shift"]),
    }


# ============================================================================
# Data loading (same test_images/img_????.hex convention as HW benchmarks)
# ============================================================================
def load_images(data_dir, n):
    img_dir = os.path.join(data_dir, "test_images")
    files = sorted(glob.glob(os.path.join(img_dir, "img_????.hex")))
    if not files:
        print(f"ERROR: no images in {img_dir}", file=sys.stderr)
        sys.exit(1)
    files = files[:n]
    imgs, labels = [], []
    for f in files:
        with open(f) as fh:
            px = [int(l.strip(), 16) & 0xFF for l in fh if l.strip()]
        imgs.append(np.array(px, dtype=np.uint8))
        name = os.path.basename(f).replace(".hex", "")
        labels.append(
            int(open(os.path.join(img_dir, f"{name}_label.txt")).read().strip())
        )
    return imgs, labels


# ============================================================================
# Timing core
# ============================================================================
def time_image(fn, n_runs):
    """Return median microseconds over n_runs (median = robust to OS jitter)."""
    for _ in range(WARMUP):
        fn()
    ts = []
    for _ in range(n_runs):
        t0 = time.perf_counter()
        fn()
        ts.append((time.perf_counter() - t0) * 1e6)
    return float(np.median(ts))


def read_hw_csv(path):
    """Read a HW benchmark CSV (from benchmark_e2e.py / benchmark_rv32.py).

    Returns dict with at least {ms_per_img, fps, accuracy_pct, total_s}.
    Both the e2e and rv32 CSV layouts share these leading columns:
      model,n_img,total_s,ms_per_img,fps,correct,accuracy_pct[,min_ms,...]
    """
    import csv as _csv

    with open(path) as f:
        rows = list(_csv.DictReader(f))
    if not rows:
        raise ValueError(f"empty CSV: {path}")
    row = rows[0]
    return {
        "path": path,
        "ms_per_img": float(row["ms_per_img"]),
        "fps": float(row["fps"]) if row.get("fps") else None,
        "accuracy_pct": float(row["accuracy_pct"]) if row.get("accuracy_pct") else None,
        "total_s": float(row["total_s"]) if row.get("total_s") else None,
    }


def run_model(model, data_dir, n_images, n_runs):
    imgs, labels = load_images(data_dir, n_images)
    n = len(imgs)

    if model in ("mlp", "small_mlp"):
        P = load_mlp_params(data_dir)
        regimes = {
            "sequential": lambda im: forward_mlp(im, P)
        }  # FC-only: single regime
    elif model == "lenet5":
        P = load_lenet_params(data_dir)
        regimes = {
            "sequential": lambda im: forward_lenet(im, P, "sequential"),
            "batched": lambda im: forward_lenet(im, P, "batched"),
        }
    else:
        raise ValueError(model)

    # ---- accuracy (sanity: must match the HW benchmark accuracy) ----
    correct = 0
    ref_fn = regimes["sequential"]
    for im, lab in zip(imgs, labels):
        if ref_fn(im) == lab:
            correct += 1
    acc = correct / n * 100

    # ---- per-image SW timing, per regime ----
    per_image_us = {}
    for rname, rfn in regimes.items():
        ts = [time_image(lambda im=im: rfn(im), n_runs) for im in imgs]
        per_image_us[rname] = {
            "mean_us": float(np.mean(ts)),
            "median_us": float(np.median(ts)),
            "min_us": float(np.min(ts)),
            "max_us": float(np.max(ts)),
        }

    # ---- HW compute-core latency @ HW_FREQ_MHZ (from perf-counter cycles) ----
    hw_cyc = HW_CYCLES.get(model, {}).get("total", 0)
    hw_compute_us = hw_cyc / (HW_FREQ_MHZ * 1e6) * 1e6 if hw_cyc else 0.0

    return {
        "model": model,
        "n_images": n,
        "n_runs": n_runs,
        "accuracy_pct": round(acc, 2),
        "correct": correct,
        "hw_freq_mhz": HW_FREQ_MHZ,
        "hw_compute_cycles": hw_cyc,
        "hw_compute_us": hw_compute_us,
        "sw_per_image_us": per_image_us,
    }


def compute_speedups(r, hw_endtoend_csv=None, sw_regime="sequential"):
    """Attach speedup comparisons to the SW result `r`.

    Two clearly-distinguished calibers:

    1. PURE-COMPUTE speedup  (HW快多少倍, 仅算乘加):
         HW = perf-counter MAC cycles / freq      (compute only, NO DMA)
         SW = NumPy matrix-op time                (compute only)
         speedup_compute = SW_compute / HW_compute   (>1 => HW faster)
       Both sides are compute-only => a fair, symmetric "compute core" ratio.
       This is the 43.0x / 34.8x / 6.0x family in the thesis.

    2. END-TO-END comparison (系统级, HW含DMA/调度):
         HW = ms_per_img from the actual HW CSV    (FULL end-to-end wall time)
         SW = NumPy matrix-op time                 (compute only)
         ratio_endtoend = SW_compute / HW_endtoend  (>1 => HW system faster)
       NOTE the asymmetry: HW carries DMA + Python scheduling, SW carries only
       the matmul. This ratio is therefore CONSERVATIVE for the hardware
       (HW is handicapped). It reproduces the thesis 0.75x / 0.93x / 0.16x.
       Interpret as "even with all data-movement overhead, HW system time vs
       the leanest SW compute time" — not a like-for-like end-to-end race.
    """
    sw = r["sw_per_image_us"]
    hw_compute_us = r["hw_compute_us"]

    out = {"pure_compute": {}, "end_to_end": {}}

    # ---- pure-compute (symmetric) ----
    for rname, v in sw.items():
        sw_us = v["mean_us"]
        out["pure_compute"][rname] = {
            "sw_compute_us": sw_us,
            "hw_compute_us": hw_compute_us,
            "speedup_hw_over_sw": (sw_us / hw_compute_us) if hw_compute_us else None,
        }

    # ---- end-to-end (HW from CSV) ----
    if hw_endtoend_csv is not None:
        hw_ms = hw_endtoend_csv["ms_per_img"]
        hw_us = hw_ms * 1000.0
        for rname, v in sw.items():
            sw_us = v["mean_us"]
            out["end_to_end"][rname] = {
                "sw_compute_us": sw_us,
                "hw_endtoend_us": hw_us,
                "hw_endtoend_ms": hw_ms,
                "hw_csv": hw_endtoend_csv["path"],
                # ratio = SW / HW : >1 HW faster, <1 SW faster
                "ratio_sw_over_hw": (sw_us / hw_us) if hw_us else None,
                # also give HW/SW so both directions are explicit
                "ratio_hw_over_sw": (hw_us / sw_us) if sw_us else None,
            }
        # accuracy cross-check vs the CSV
        if hw_endtoend_csv.get("accuracy_pct") is not None:
            out["accuracy_match"] = {
                "sw_accuracy_pct": r["accuracy_pct"],
                "hw_csv_accuracy_pct": hw_endtoend_csv["accuracy_pct"],
                "match": abs(r["accuracy_pct"] - hw_endtoend_csv["accuracy_pct"])
                < 0.01,
            }

    r["speedups"] = out
    return r


def print_report(r):
    print("\n" + "=" * 64)
    print(
        f"  SW BASELINE  model={r['model']}  n={r['n_images']}  runs/img={r['n_runs']}"
    )
    print("=" * 64)
    print(
        f"  Accuracy (vs label)            : {r['accuracy_pct']:.2f}% "
        f"({r['correct']}/{r['n_images']})"
    )

    acc = r.get("speedups", {}).get("accuracy_match")
    if acc:
        flag = "OK ✓" if acc["match"] else "MISMATCH! ✗"
        print(
            f"  Accuracy vs HW CSV             : SW={acc['sw_accuracy_pct']:.2f}%  "
            f"HW={acc['hw_csv_accuracy_pct']:.2f}%  [{flag}]"
        )
        if not acc["match"]:
            print("    -> SW and HW are NOT the same model. Speedups not comparable.")

    print(
        f"  HW compute core @ {r['hw_freq_mhz']}MHz     : "
        f"{r['hw_compute_cycles']} cyc = {r['hw_compute_us']:.1f} us/img (MAC only, no DMA)"
    )

    print("\n  --- SW compute time (ARM Cortex-A9, NumPy/BLAS) ---")
    for rname, v in r["sw_per_image_us"].items():
        print(
            f"    {rname:<10s} mean={v['mean_us']:10.1f} us  "
            f"median={v['median_us']:10.1f}  min={v['min_us']:10.1f}"
        )

    sp = r.get("speedups", {})

    print(
        "\n  --- (1) PURE-COMPUTE speedup  [HW MAC-only  vs  SW matmul]  symmetric ---"
    )
    for rname, d in sp.get("pure_compute", {}).items():
        s = d["speedup_hw_over_sw"]
        if s:
            print(
                f"    {rname:<10s} SW {d['sw_compute_us']:9.1f}us / HW {d['hw_compute_us']:7.1f}us "
                f"=> HW {s:6.1f}x faster"
            )

    if sp.get("end_to_end"):
        print(
            "\n  --- (2) END-TO-END comparison  [HW full(+DMA)  vs  SW matmul]  HW handicapped ---"
        )
        for rname, d in sp["end_to_end"].items():
            print(
                f"    {rname:<10s} HW e2e {d['hw_endtoend_ms']:8.2f}ms  "
                f"SW {d['sw_compute_us'] / 1000.0:8.3f}ms  =>  "
                f"SW/HW={d['ratio_sw_over_hw']:.2f}x  (HW/SW={d['ratio_hw_over_sw']:.2f}x)"
            )
            print(f"      (HW csv: {os.path.basename(d['hw_csv'])})")
        print("    NOTE: SW side is compute-only; HW side includes DMA+scheduling.")
        print(
            "          SW/HW<1 => HW system slower than lean SW compute (conservative for HW)."
        )
    print("=" * 64)


def autodiscover_hw_csv(model, data_dir, hw_csv_path):
    """Resolve the HW DMA+batch end-to-end CSV for this model.

    `hw_csv_path` may be EITHER:
      - a file  -> use it directly (no search), or
      - a directory -> search inside it for the matching auto-named CSV.

    Directory search order:
      1. arm_dma_batch_<data_dir>.csv          (new auto-naming, this spec)
      2. arm_100mhz_dma_batch_<short>.csv        (existing Thesis/data naming)
      3. arm_dma_batch_<short>.csv
    where <short> is mlp/small_mlp/lenet5.
    """
    if not hw_csv_path:
        return None

    # Case 1: an explicit file was passed -> use it directly.
    if os.path.isfile(hw_csv_path):
        return hw_csv_path

    # Case 2: a directory -> search for the matching CSV.
    if os.path.isdir(hw_csv_path):
        data_tag = os.path.basename(os.path.normpath(data_dir))
        short = {"mlp": "mlp", "small_mlp": "small_mlp", "lenet5": "lenet5"}.get(
            model, model
        )
        candidates = [
            f"arm_dma_batch_{data_tag}.csv",
            f"arm_100mhz_dma_batch_{short}.csv",
            f"arm_dma_batch_{short}.csv",
        ]
        for c in candidates:
            p = os.path.join(hw_csv_path, c)
            if os.path.exists(p):
                return p
        return None

    # Neither an existing file nor dir (maybe a path that doesn't exist yet)
    return None


def main():
    ap = argparse.ArgumentParser(
        description="ARM pure-software INT8 inference baseline"
    )
    ap.add_argument(
        "--model", default="all", choices=["mlp", "small_mlp", "lenet5", "all"]
    )
    ap.add_argument(
        "--data-dir",
        default=None,
        help="Override data dir (default: per-model standard dir)",
    )
    ap.add_argument("--n-images", type=int, default=200)
    ap.add_argument(
        "--n-runs",
        type=int,
        default=N_RUNS_DEFAULT,
        help=f"timing repeats per image, median taken (default {N_RUNS_DEFAULT})",
    )
    ap.add_argument("--out-dir", default="results")
    ap.add_argument(
        "--hw-csv",
        default=None,
        help="Path to a specific HW end-to-end CSV to compare against "
        "(e.g. results/arm_dma_batch_mlp_data_42.csv). Takes "
        "precedence over --hw-csv-dir. With --model all this single "
        "file is used for every model, which usually only makes "
        "sense for one model, so prefer per-model runs.",
    )
    ap.add_argument(
        "--hw-csv-dir",
        default=None,
        help="EITHER a directory holding the HW CSVs (e.g. results/ or "
        "../Thesis/data — the matching arm_dma_batch_* file is "
        "auto-found per model from --data-dir), OR a path to a "
        "single CSV file (used directly). Passing a file here is "
        "equivalent to --hw-csv.",
    )
    args = ap.parse_args()

    default_dirs = {
        "mlp": "mnist_real_data",
        "small_mlp": "small_mlp_data",
        "lenet5": "lenet5_data",
    }
    models = ["mlp", "small_mlp", "lenet5"] if args.model == "all" else [args.model]

    os.makedirs(args.out_dir, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    all_results = []

    for m in models:
        dd = args.data_dir or default_dirs[m]
        print(f"\n>>> {m}  (data_dir={dd})")
        r = run_model(m, dd, args.n_images, args.n_runs)

        # Resolve which HW CSV to compare against.
        # Priority: explicit --hw-csv  >  --hw-csv-dir (file or directory).
        hw_csv_path = None
        if args.hw_csv:
            if os.path.isfile(args.hw_csv):
                hw_csv_path = args.hw_csv
                print(f"    HW CSV (explicit): {hw_csv_path}")
            else:
                print(
                    f"    HW CSV: --hw-csv '{args.hw_csv}' is not a file "
                    f"(end-to-end comparison skipped)"
                )
        elif args.hw_csv_dir:
            hw_csv_path = autodiscover_hw_csv(m, dd, args.hw_csv_dir)
            if hw_csv_path:
                kind = "file" if os.path.isfile(args.hw_csv_dir) else "auto"
                print(f"    HW CSV ({kind}): {hw_csv_path}")
            else:
                print(
                    f"    HW CSV: nothing matched under '{args.hw_csv_dir}' for {m} "
                    f"(end-to-end comparison skipped)"
                )

        hw_csv = read_hw_csv(hw_csv_path) if hw_csv_path else None
        compute_speedups(r, hw_endtoend_csv=hw_csv)

        print_report(r)
        all_results.append(r)

        out = os.path.join(args.out_dir, f"sw_baseline_{m}_{ts}.json")
        with open(out, "w", encoding="utf-8") as f:
            json.dump(r, f, indent=2, ensure_ascii=False)
        print(f"  saved: {out}")

    # ---- combined JSON ----
    combined = os.path.join(args.out_dir, f"sw_baseline_ALL_{ts}.json")
    with open(combined, "w", encoding="utf-8") as f:
        json.dump(all_results, f, indent=2, ensure_ascii=False)

    # ---- summary CSV (one row per model x regime) ----
    summary_csv = os.path.join(args.out_dir, f"sw_baseline_summary_{ts}.csv")
    import csv as _csv

    with open(summary_csv, "w", newline="") as f:
        w = _csv.writer(f)
        w.writerow(
            [
                "model",
                "regime",
                "n_images",
                "sw_compute_us",
                "hw_compute_us",
                "compute_speedup_hw_over_sw",
                "hw_endtoend_ms",
                "endtoend_ratio_sw_over_hw",
                "endtoend_ratio_hw_over_sw",
                "hw_csv",
                "sw_accuracy_pct",
            ]
        )
        for r in all_results:
            sp = r.get("speedups", {})
            for regime in r["sw_per_image_us"].keys():
                pc = sp.get("pure_compute", {}).get(regime, {})
                ee = sp.get("end_to_end", {}).get(regime, {})
                w.writerow(
                    [
                        r["model"],
                        regime,
                        r["n_images"],
                        f"{pc.get('sw_compute_us', ''):.1f}"
                        if pc.get("sw_compute_us")
                        else "",
                        f"{pc.get('hw_compute_us', ''):.1f}"
                        if pc.get("hw_compute_us")
                        else "",
                        f"{pc.get('speedup_hw_over_sw'):.2f}"
                        if pc.get("speedup_hw_over_sw")
                        else "",
                        f"{ee.get('hw_endtoend_ms'):.2f}"
                        if ee.get("hw_endtoend_ms")
                        else "",
                        f"{ee.get('ratio_sw_over_hw'):.3f}"
                        if ee.get("ratio_sw_over_hw")
                        else "",
                        f"{ee.get('ratio_hw_over_sw'):.3f}"
                        if ee.get("ratio_hw_over_sw")
                        else "",
                        os.path.basename(ee["hw_csv"]) if ee.get("hw_csv") else "",
                        f"{r['accuracy_pct']:.2f}",
                    ]
                )

    print(f"\nCombined JSON : {combined}")
    print(f"Summary CSV   : {summary_csv}")
    print("Copy these into Thesis/data/ alongside the arm_*.csv files.")


if __name__ == "__main__":
    main()
