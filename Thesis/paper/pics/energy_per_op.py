import matplotlib
matplotlib.use("Agg")

import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

# --- Data ---
ops = [
    ("8-bit INT ADD",       0.03,  "compute"),
    ("32-bit INT ADD",      0.1,   "compute"),
    ("8-bit INT MULT",      0.2,   "compute"),
    ("32-bit INT MULT",     3.1,   "compute"),
    ("32-bit FP MULT",      3.7,   "compute"),
    ("8 KB SRAM Read",      5.0,   "sram"),
    ("32 KB Cache Read",    10.0,  "sram"),
    ("1 MB SRAM Read",      100.0, "sram"),
    ("DRAM Read",           640.0, "dram"),
]

labels   = [o[0] for o in ops]
values   = [o[1] for o in ops]
categories = [o[2] for o in ops]

color_map = {
    "compute": "#F5B461",
    "sram":    "#A8D5E2",
    "dram":    "#C0392B",
}
edge_map = {
    "compute": "#B86B1F",
    "sram":    "#2E5C8A",
    "dram":    "#8B1A1A",
}
bar_colors = [color_map[c] for c in categories]
bar_edges  = [edge_map[c] for c in categories]

# --- Style ---
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "DejaVu Serif"],
    "font.size": 10,
    "mathtext.fontset": "stix",
    "axes.titlesize": 14,
    "axes.labelsize": 11,
    "xtick.labelsize": 9,
    "ytick.labelsize": 10,
    "legend.fontsize": 9,
    "figure.dpi": 150,
    "savefig.dpi": 300,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.05,
})

# --- Figure ---
fig, ax = plt.subplots(figsize=(8, 4.5))

y_pos = np.arange(len(ops))
bars = ax.barh(y_pos, values, height=0.55, color=bar_colors, edgecolor=bar_edges,
               linewidth=0.75, zorder=3)

# Log scale
ax.set_xscale("log")
ax.set_xlim(0.008, 12000)

# Y-axis
ax.set_yticks(y_pos)
ax.set_yticklabels(labels)
ax.invert_yaxis()

# X-axis grid on log decades
ax.xaxis.set_major_locator(ticker.LogLocator(base=10.0, numticks=20))
ax.xaxis.set_minor_locator(ticker.LogLocator(base=10.0, subs=np.arange(2, 10) * 0.1,
                                              numticks=20))
ax.grid(axis="x", which="major", linewidth=0.5, color="#cccccc", zorder=0)
ax.grid(axis="x", which="minor", linewidth=0.2, color="#e0e0e0", zorder=0)
ax.set_axisbelow(True)

# Value labels at bar tips
for i, (v, cat) in enumerate(zip(values, categories)):
    if cat == "dram":
        ax.text(v * 1.08, i, f"{v:g} pJ", va="center", fontsize=9,
                color="#C0392B", fontweight="bold")
    else:
        ax.text(v * 1.08, i, f"{v:g} pJ", va="center", fontsize=9, color="#333333")

# --- Memory wall threshold ---
ax.axvline(x=100, color="#C0392B", linewidth=1.2, linestyle="--", zorder=2)
ax.text(100 * 1.05, len(ops) - 0.35, "Memory wall\nthreshold", fontsize=9,
        color="#C0392B", fontstyle="italic", va="top")

# --- DRAM annotation ---
# Arrow from DRAM bar pointing to the label area
arrow_x = 640
arrow_y = 0  # DRAM bar index (bottom after invert)
dram_annot = ax.annotate(
    "DRAM access ~200× more expensive\nthan 8-bit MAC",
    xy=(640, 0),
    xytext=(1200, 2.0),
    fontsize=9,
    color="#C0392B",
    fontstyle="italic",
    arrowprops=dict(arrowstyle="->", color="#C0392B", lw=1.2,
                    connectionstyle="arc3,rad=0.3"),
    bbox=dict(boxstyle="round,pad=0.3", facecolor="white", edgecolor="#C0392B",
              linewidth=0.8, alpha=0.9),
)

# --- Legend ---
from matplotlib.patches import Patch
legend_patches = [
    Patch(facecolor="#F5B461", edgecolor="#B86B1F", linewidth=0.75, label="Arithmetic (INT/FP)"),
    Patch(facecolor="#A8D5E2", edgecolor="#2E5C8A", linewidth=0.75, label="On-chip SRAM / Cache"),
    Patch(facecolor="#C0392B", edgecolor="#8B1A1A", linewidth=0.75, label="Off-chip DRAM"),
]
legend = ax.legend(handles=legend_patches, loc="upper center",
                    bbox_to_anchor=(0.5, -0.22), ncol=3,
                    frameon=True, fancybox=False, edgecolor="#aaaaaa", fontsize=8)

# --- Labels ---
ax.set_xlabel("Energy per Operation (pJ, log scale)")
ax.set_title("Energy Cost of Compute vs. Memory Operations")

# Remove spines
ax.spines["top"].set_visible(False)
ax.spines["right"].set_visible(False)
ax.spines["left"].set_linewidth(0.5)
ax.spines["bottom"].set_linewidth(0.5)

fig.tight_layout(rect=[0, 0.12, 1, 1])
fig.savefig("energy_per_op.pdf", format="pdf", bbox_extra_artists=(legend, dram_annot))
fig.savefig("energy_per_op.png", format="png", bbox_extra_artists=(legend, dram_annot))
print("Saved: energy_per_op.pdf, energy_per_op.png")
