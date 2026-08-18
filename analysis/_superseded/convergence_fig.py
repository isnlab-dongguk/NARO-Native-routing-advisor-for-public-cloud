#!/usr/bin/env python3
"""E3: Route convergence time upon node addition.

Produces figure/convergence.pdf: grouped bars for the three native
route-registration mechanisms at 4 and 8 worker nodes (50 pods per node).
Data: routing_convergence.xlsx (repo root; per-scenario means over 3 reps, ms).
T0 = final route-registration action, T2 = first successful TCP probe response.

Style matches provisioning_fig.py: sans-serif (Arial stack), plain frame,
no minor ticks, one-decimal value labels.
"""
import openpyxl
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

wb = openpyxl.load_workbook("routing_convergence.xlsx", data_only=True)
ws = wb["Sheet1"]
rows = {r[0]: r for r in ws.iter_rows(values_only=True) if r[0]}
# header: ['실험3', '4node×1p', '4node×50p', '8node×1p', '8node×50p', 'Average', ...]
COLS = {"4 nodes": 2, "8 nodes": 4}  # 50-pod scenarios only
MECHS = [("STATIC", "N-Static"), ("DYNAMIC", "N-Dynamic"), ("CLOUD", "N-Cloud")]
COLOR = {"N-Static": "#920923", "N-Dynamic": "#000080", "N-Cloud": "#FFA500"}

data = {label: [rows[key][c] / 1000 for c in COLS.values()] for key, label in MECHS}
# GKE re-run (2026-07-30) supersedes the alias-IP CLOUD measurements for the
# plotted 50-pod scenarios (ms): 4node 5103.667, 8node 5224.667.
data["N-Cloud"] = [5103.667 / 1000, 5224.667 / 1000]

plt.rcParams.update({
    "font.size": 7,
    "font.family": "sans-serif",
    "font.sans-serif": ["Arial", "Liberation Sans", "DejaVu Sans"],
    "mathtext.fontset": "dejavusans",
})

fig, ax = plt.subplots(figsize=(2.7, 1.75))
x = np.arange(len(COLS))
w = 0.24
for i, (_, label) in enumerate(MECHS):
    xs = x + (i - 1) * w
    ax.bar(xs, data[label], width=w, color=COLOR[label],
           edgecolor="white", linewidth=0.6, label=label)
    for xi, v in zip(xs, data[label]):
        ax.annotate(f"{v:.1f}", xy=(xi, v + 0.35), ha="center",
                    fontsize=6, color="#333333")
ax.set_xticks(x)
ax.set_xticklabels(list(COLS), fontsize=7)
ax.set_ylim(0, 21.5)
ax.set_yticks([0, 5, 10, 15, 20])
ax.set_ylabel("Route convergence time (s)", fontsize=7)
ax.minorticks_off()
ax.tick_params(axis="x", length=0)
ax.tick_params(axis="y", labelsize=6.5)
ax.grid(axis="y", alpha=0.25, lw=0.4)
ax.set_axisbelow(True)
ax.legend(fontsize=6.5, frameon=False, loc="upper center", ncol=3,
          handlelength=1.1, columnspacing=0.9, handletextpad=0.5)
fig.tight_layout(pad=0.2)
fig.savefig("../figure/convergence.pdf")
print("wrote ../figure/convergence.pdf")
