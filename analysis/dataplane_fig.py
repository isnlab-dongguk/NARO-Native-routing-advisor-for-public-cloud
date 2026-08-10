#!/usr/bin/env python3
"""E1 v3 (GKE round): Data-plane performance of the five configurations.

Produces three PDFs for a single-column subfigure layout:
  figure/dataplane_legend.pdf — legend only (placed above the panels)
  figure/dataplane_tcp.pdf    — (a) iperf3 TCP throughput
  figure/dataplane_cpu.pdf    — (b) softirq CPU share, sender vs receiver
(netperf latency was dropped from the paper in the GKE round; the earlier
4-scenario dataplane_v2.xlsx campaign is superseded.)
Data: dataplane_v3_data.csv — single client/server pod pair on different
worker nodes, averages of three runs; N-Cloud = real GKE cluster.

Style matches provisioning_fig.py / convergence_fig.py.
"""
import csv
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CFGS = ["B-Host", "B-VXLAN", "N-Static", "N-Dynamic", "N-Cloud"]
COLOR = {"B-Host": "#D4DAE2", "B-VXLAN": "#8D99A6", "N-Cloud": "#FFA500",
         "N-Static": "#920923", "N-Dynamic": "#000080"}

data = {}
with open("dataplane_v3_data.csv") as f:
    for row in csv.DictReader(r for r in f if not r.startswith("#")):
        data[row["config"]] = {k: float(v) for k, v in row.items() if k != "config"}

plt.rcParams.update({
    "font.size": 7,
    "font.family": "sans-serif",
    "font.sans-serif": ["Arial", "Liberation Sans", "DejaVu Sans"],
    "mathtext.fontset": "dejavusans",
})

# (a) TCP throughput
fig, ax = plt.subplots(figsize=(1.4, 1.55))
for i, c in enumerate(CFGS):
    m = data[c]["tcp_gbps"]
    ax.bar(i, m, width=0.72, color=COLOR[c], edgecolor="white", linewidth=0.5)
    lift = 0.25 if i % 2 == 0 else 0.9
    # natives labeled uniformly as 9.7 (9.735-9.752, spread < 0.2%): the
    # figure's message is their equality, and 9.75 would round up to 9.8
    label = "9.7" if c.startswith("N-") else f"{m:.1f}"
    ax.annotate(label, xy=(i, m + lift), ha="center",
                fontsize=5.5, color="#333333")
ax.set_ylabel("Throughput (Gbps)", fontsize=6.5, labelpad=1)
ax.set_ylim(0, 12.4)
ax.set_yticks([0, 4, 8])
ax.set_xticks([])
ax.minorticks_off()
ax.tick_params(axis="y", labelsize=6)
ax.grid(axis="y", alpha=0.25, lw=0.4)
ax.set_axisbelow(True)
fig.tight_layout(pad=0.25)
fig.savefig("../figure/dataplane_tcp.pdf")
plt.close(fig)
print("wrote ../figure/dataplane_tcp.pdf")

# (b) softirq CPU share, sender (solid) vs receiver (hatched)
fig, ax = plt.subplots(figsize=(1.4, 1.55))
for i, c in enumerate(CFGS):
    snd = data[c]["snd_softirq_pct"]
    rcv = data[c]["rcv_softirq_pct"]
    ax.bar(i - 0.19, snd, width=0.34, color=COLOR[c],
           edgecolor="white", linewidth=0.5)
    ax.bar(i + 0.19, rcv, width=0.34, color=COLOR[c],
           edgecolor="white", linewidth=0.5, hatch="////", alpha=0.75)
    for x, v in ((i - 0.19, snd), (i + 0.19, rcv)):
        ax.annotate(f"{v:.1f}", xy=(x, v + 1.0), ha="center",
                    fontsize=4.6, color="#333333", rotation=90, va="bottom")
snd_h = plt.Rectangle((0, 0), 1, 1, facecolor="#8A8A8A", edgecolor="white")
rcv_h = plt.Rectangle((0, 0), 1, 1, facecolor="#8A8A8A", edgecolor="white",
                      hatch="////", alpha=0.75)
ax.legend([snd_h, rcv_h], ["Sender", "Receiver"], loc="upper right",
          fontsize=5, frameon=False, handlelength=1.0, handletextpad=0.35,
          borderaxespad=0.15, labelspacing=0.25)
ax.set_ylabel("Softirq CPU share (%)", fontsize=6.5, labelpad=1)
ax.set_ylim(0, 56)
ax.set_yticks([0, 15, 30, 45])
ax.set_xticks([])
ax.minorticks_off()
ax.tick_params(axis="y", labelsize=6)
ax.grid(axis="y", alpha=0.25, lw=0.4)
ax.set_axisbelow(True)
fig.tight_layout(pad=0.25)
fig.savefig("../figure/dataplane_cpu.pdf")
plt.close(fig)
print("wrote ../figure/dataplane_cpu.pdf")

# legend-only figure, included at natural size
figl = plt.figure(figsize=(3.2, 0.35))
handles = [plt.Rectangle((0, 0), 1, 1, color=COLOR[c], ec="white") for c in CFGS]
figl.legend(handles, CFGS, loc="center", ncol=3,
            fontsize=6.5, frameon=False, handlelength=1.1,
            columnspacing=0.8, handletextpad=0.4)
figl.savefig("../figure/dataplane_legend.pdf", bbox_inches="tight", pad_inches=0.02)
print("wrote ../figure/dataplane_legend.pdf")
