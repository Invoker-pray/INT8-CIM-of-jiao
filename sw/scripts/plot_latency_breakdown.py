#!/usr/bin/env python3
"""Generate a stacked bar chart of LeNet-5 per-layer latency breakdown.

Output: Thesis/middle/paper/fig/latency_breakdown.{pdf,png}
"""

import os
import matplotlib.pyplot as plt
import numpy as np

# ---------- data from profiler table ----------
layers = [
    "Conv1 (1->6, 5x5)",
    "MaxPool 2x2",
    "Conv2 (6->16, 5x5)",
    "MaxPool 2x2 ",        # trailing space to avoid duplicate label
    "FC3 (256->120)",
    "FC4 (120->84)",
    "FC5 (84->10)",
]

setup_ms   = [315.8, 53.5, 283.0, 15.9, 155.9, 58.1,  7.7]
load_x_ms  = [332.9,  0.0, 219.0,  0.0,   6.0,  2.9,  2.2]
compute_ms = [  4.6,  0.0,   1.9,  0.0,   0.1,  0.1,  0.1]
read_ms    = [194.2,  0.0,  56.5,  0.0,   6.5,  4.7,  0.6]

totals = [s + l + c + r for s, l, c, r in
          zip(setup_ms, load_x_ms, compute_ms, read_ms)]

# ---------- plot ----------
fig, ax = plt.subplots(figsize=(10, 5))

y = np.arange(len(layers))
bar_h = 0.55

# stacked segments (left-to-right: setup, load_x, compute, read)
left = np.zeros(len(layers))

colors  = ["#4C72B0", "#DD8452", "#55A868", "#C44E52"]
labels  = ["Setup (CSR cfg + weight DMA)", "Load input vector",
           "Compute (MVM)", "Read output"]
datasets = [setup_ms, load_x_ms, compute_ms, read_ms]

for data, color, label in zip(datasets, colors, labels):
    ax.barh(y, data, height=bar_h, left=left, color=color, label=label,
            edgecolor="white", linewidth=0.4)
    left += np.array(data)

# total annotation at end of each bar
for i, total in enumerate(totals):
    ax.text(total + 8, i, f"{total:.1f} ms",
            va="center", fontsize=9, fontweight="bold")

ax.set_yticks(y)
ax.set_yticklabels([l.rstrip() for l in layers])  # strip trailing space
ax.invert_yaxis()          # Conv1 on top
ax.set_xlabel("Latency (ms)", fontsize=11)
ax.set_title("LeNet-5 Per-Layer Latency Breakdown (PYNQ-Z2, 60 MHz)",
             fontsize=13, fontweight="bold")
ax.legend(loc="lower right", fontsize=9, framealpha=0.9)

# leave room for total annotations
ax.set_xlim(0, max(totals) * 1.15)
ax.grid(axis="x", linestyle="--", alpha=0.3)

fig.tight_layout()

# ---------- save ----------
out_dir = os.path.join(os.path.dirname(__file__),
                       "../../Thesis/middle/paper/fig")
out_dir = os.path.normpath(out_dir)
os.makedirs(out_dir, exist_ok=True)

for ext in ("pdf", "png"):
    path = os.path.join(out_dir, f"latency_breakdown.{ext}")
    fig.savefig(path, dpi=300, bbox_inches="tight")
    print(f"Saved: {path}")

plt.close(fig)
