#!/usr/bin/env python3
"""
benchmark_e2e.py  —  End-to-end batch benchmark for thesis Chapter 5.

Usage (on PYNQ, run from sw/):
    python scripts/benchmark_e2e.py
    python scripts/benchmark_e2e.py --model lenet5 --n_images 200 --data_dir lenet5_data
    python scripts/benchmark_e2e.py --model mlp    --n_images 200 --data_dir mnist_real_data

Output:
    Console: formatted table  (Model / n_img / total_s / ms_per_img / fps / accuracy)
    File:    results/benchmark_<model>_<timestamp>.csv

The --n_images argument is capped at the number of available test images.
"""

import argparse
import glob
import os
import sys
import time
import csv
from datetime import datetime

import numpy as np

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
def parse_args():
    p = argparse.ArgumentParser(description="CIM SoC end-to-end batch benchmark")
    p.add_argument("--model",     default="lenet5", choices=["lenet5", "mlp"],
                   help="Model architecture (default: lenet5)")
    p.add_argument("--n_images",  type=int, default=200,
                   help="Number of test images (default: 200; capped by available images)")
    p.add_argument("--data_dir",  default=None,
                   help="Data directory (default: lenet5_data / mnist_real_data)")
    p.add_argument("--bitstream", default="cim_soc.bit",
                   help="Bitstream path (default: cim_soc.bit)")
    p.add_argument("--out_dir",   default="results",
                   help="Directory for CSV output (default: results/)")
    p.add_argument("--verbose",   action="store_true",
                   help="Print per-image prediction")
    return p.parse_args()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def read_hex_u8(path):
    with open(path) as f:
        return [int(line.strip(), 16) & 0xFF for line in f if line.strip()]


def load_lenet5_model(drv, data_dir):
    from cim_driver import CIMModel, weight_to_chunks, bias_to_u32

    d = np.load(os.path.join(data_dir, "lenet5_qparams.npz"))
    model = CIMModel(drv)

    model.add_conv(d["conv1_weight"], d["conv1_bias"],
                   zp=int(d["conv1_zp"]), mult=int(d["conv1_mult"]),
                   shift=int(d["conv1_shift"]), stride=1, padding=0, relu=True)
    model.add_pool(2, 2)

    model.add_conv(d["conv2_weight"], d["conv2_bias"],
                   zp=int(d["conv2_zp"]), mult=int(d["conv2_mult"]),
                   shift=int(d["conv2_shift"]), stride=1, padding=0, relu=True)
    model.add_pool(2, 2)

    model.add_fc(256, 120, weight_to_chunks(d["fc3_weight"]), bias_to_u32(d["fc3_bias"]),
                 zp=int(d["fc3_zp"]), mult=int(d["fc3_mult"]), shift=int(d["fc3_shift"]),
                 relu=True, weight_int8=d["fc3_weight"], bias_int32=d["fc3_bias"])
    model.add_fc(120, 84, weight_to_chunks(d["fc4_weight"]), bias_to_u32(d["fc4_bias"]),
                 zp=int(d["fc4_zp"]), mult=int(d["fc4_mult"]), shift=int(d["fc4_shift"]),
                 relu=True, weight_int8=d["fc4_weight"], bias_int32=d["fc4_bias"])
    model.add_fc(84, 10, weight_to_chunks(d["fc5_weight"]), bias_to_u32(d["fc5_bias"]),
                 zp=int(d["fc5_zp"]), mult=int(d["fc5_mult"]), shift=int(d["fc5_shift"]),
                 relu=False, weight_int8=d["fc5_weight"], bias_int32=d["fc5_bias"])

    return model


def load_mlp_model(drv, data_dir):
    from cim_driver import CIMModel, weight_to_chunks, bias_to_u32

    # mnist_real_data: quant_params.hex + fc1/fc2 weight/bias tiles
    qp_path = os.path.join(data_dir, "quant_params.hex")
    with open(qp_path) as f:
        vals = [int(l.strip(), 16) for l in f if l.strip()]
    # [fc1_mult, fc1_shift, fc2_mult, fc2_shift]
    fc1_mult, fc1_shift, fc2_mult, fc2_shift = vals[:4]

    zp_path = os.path.join(data_dir, "zero_points.hex")
    if os.path.exists(zp_path):
        with open(zp_path) as f:
            zp_vals = [int(l.strip(), 16) for l in f if l.strip()]
        fc1_zp = zp_vals[0] if zp_vals else -128
        fc2_zp = zp_vals[1] if len(zp_vals) > 1 else -128
    else:
        fc1_zp = fc2_zp = -128

    # Load weight tiles as raw chunk lists
    def load_hex_u32(path):
        with open(path) as f:
            return [int(l.strip(), 16) for l in f if l.strip()]

    fc1_chunks = load_hex_u32(os.path.join(data_dir, "fc1_weight_tiles.hex"))
    fc2_chunks = load_hex_u32(os.path.join(data_dir, "fc2_weight_tiles.hex"))
    fc1_bias   = load_hex_u32(os.path.join(data_dir, "fc1_bias.hex"))
    fc2_bias   = load_hex_u32(os.path.join(data_dir, "fc2_bias.hex"))

    model = CIMModel(drv)
    model.add_fc(784, 128, fc1_chunks, fc1_bias,
                 zp=fc1_zp, mult=fc1_mult, shift=fc1_shift, relu=True)
    model.add_fc(128, 10, fc2_chunks, fc2_bias,
                 zp=fc2_zp, mult=fc2_mult, shift=fc2_shift, relu=False)
    return model


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    args = parse_args()

    if args.data_dir is None:
        args.data_dir = "lenet5_data" if args.model == "lenet5" else "mnist_real_data"

    img_dir = os.path.join(args.data_dir, "test_images")
    img_files = sorted(glob.glob(os.path.join(img_dir, "img_????.hex")))
    if not img_files:
        print(f"ERROR: no test images found in {img_dir}", file=sys.stderr)
        sys.exit(1)

    n = min(args.n_images, len(img_files))
    img_files = img_files[:n]
    print(f"Benchmark: model={args.model}, n_images={n}, data_dir={args.data_dir}")

    # Load driver + model
    from cim_driver import CIMDriver
    print(f"Loading bitstream {args.bitstream} ...")
    drv = CIMDriver(args.bitstream)

    if args.model == "lenet5":
        model = load_lenet5_model(drv, args.data_dir)
        input_shape = (1, 28, 28)
    else:
        model = load_mlp_model(drv, args.data_dir)
        input_shape = (784,)

    print(f"Model loaded. Starting benchmark on {n} images ...\n")

    # ---------------------------------------------------------------------------
    # Inference loop
    # ---------------------------------------------------------------------------
    correct = 0
    wrong_list = []
    t_start = time.time()

    for img_path in img_files:
        name = os.path.basename(img_path).replace(".hex", "")
        img_u8 = np.array(read_hex_u8(img_path), dtype=np.uint8)
        label_path = os.path.join(img_dir, f"{name}_label.txt")
        label = int(open(label_path).read().strip())

        pred, _ = model.predict(img_u8.reshape(input_shape))

        if pred == label:
            correct += 1
        else:
            wrong_list.append((name, pred, label))
            if args.verbose:
                print(f"  WRONG {name}: pred={pred} label={label}")

    t_end = time.time()

    # ---------------------------------------------------------------------------
    # Results
    # ---------------------------------------------------------------------------
    total_s    = t_end - t_start
    ms_per_img = total_s / n * 1000
    fps        = n / total_s
    accuracy   = correct / n * 100

    # Table header
    col = [("Model", 10), ("n_img", 6), ("total_s", 9), ("ms/img", 9),
           ("fps", 7), ("accuracy", 10)]
    hdr  = "  ".join(f"{name:<{w}}" for name, w in col)
    sep  = "  ".join("-" * w for _, w in col)
    vals = [args.model, str(n),
            f"{total_s:.2f}s",
            f"{ms_per_img:.1f}",
            f"{fps:.2f}",
            f"{correct}/{n} ({accuracy:.1f}%)"]
    row  = "  ".join(f"{v:<{w}}" for v, (_, w) in zip(vals, col))

    print(sep)
    print(hdr)
    print(sep)
    print(row)
    print(sep)

    if wrong_list:
        print(f"\nWrong predictions ({len(wrong_list)}):")
        for name, pred, label in wrong_list:
            print(f"  {name}: pred={pred} label={label}")

    # ---------------------------------------------------------------------------
    # CSV output
    # ---------------------------------------------------------------------------
    os.makedirs(args.out_dir, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    csv_path = os.path.join(args.out_dir, f"benchmark_{args.model}_{ts}.csv")
    with open(csv_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["model", "n_img", "total_s", "ms_per_img", "fps",
                         "correct", "accuracy_pct"])
        writer.writerow([args.model, n, f"{total_s:.3f}", f"{ms_per_img:.2f}",
                         f"{fps:.3f}", correct, f"{accuracy:.2f}"])
    print(f"\nCSV saved: {csv_path}")


if __name__ == "__main__":
    main()
