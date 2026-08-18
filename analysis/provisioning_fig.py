#!/usr/bin/env python3
"""T2: Node provisioning wall-clock time, per phase.

Produces three PDFs for the single-column side-by-side subfigure layout:
  figure/provisioning_legend.pdf   — legend only (placed above the panels)
  figure/provisioning_initial.pdf  — (a) initial 4-worker deployment (with config labels)
  figure/provisioning_scaleup.pdf  — (b) incremental scale-up 4 -> 8 workers
                                     (added time only, per phase; no labels)
Data: analysis/Exp_provisioning time.xlsx (3 repetitions per cell, ms).

Design: the three shared phases (VM creation, Kubernetes setup, CNI setup)
are configuration-invariant and drawn in muted slates; the mechanism-specific
VPC task carries the accent color, since it alone separates the
configurations. Error caps show the SD of the total.
"""
import os
import openpyxl, statistics as st
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CFGS = ["HOST", "VXLAN", "STATIC", "DYNAMIC", "CLOUD"]  # unified config order
LABEL = {"VXLAN": "B-VXLAN", "HOST": "B-Host", "STATIC": "N-Static",
         "DYNAMIC": "N-Dynamic", "CLOUD": "N-Cloud"}
PHASES = ["T0_to_T1", "T1_to_T2", "T2_to_T3", "T3_to_T4", "T4_to_T5"]
# T3_to_T4 (mechanism-specific cloud-routing work) and T4_to_T5 (wait until pods
# first reach each other) are plotted as one segment, so the four bars still sum
# to the same total wall-clock time.
MERGE_LAST_TWO = True
PNAME = ["Infrastructure provisioning", "Kubernetes setup", "CNI setup",
         "Routing setup"]
COLOR = ["#9AA7B6", "#5A6B7E", "#0EB4FC", "#1B9E77"]

wb = openpyxl.load_workbook("Exp_provisioning time.xlsx", data_only=True)

# GKE re-run (fig3-gke.csv, 2026-07-30) supersedes the alias-IP CLOUD sheet:
# same layout — cols 1-3 = initial 4-worker reps, cols 6-8 = scale-up reps (ms).
import csv as _csv
GKE_ROWS = {}
with open("fig3-gke.csv") as _fh:
    for _row in _csv.reader(_fh):
        if _row and _row[0].startswith("T"):
            def _num(x):
                try:
                    return float(x)
                except ValueError:
                    return 0.0
            GKE_ROWS[_row[0]] = [_row[0]] + [_num(x) for x in _row[1:]]

def phase_stats(cfg, offs):
    """Phase means and total mean/SD summed over the runs at column offsets
    `offs` (repetitions paired by index for the SD of the sum)."""
    rows = (GKE_ROWS if cfg == "CLOUD" else
            {r[0]: r for r in wb[cfg].iter_rows(values_only=True)
             if r[0] and str(r[0]).startswith("T")})
    means = [sum(st.mean(rows[p][off + i] for i in range(3)) for off in offs) / 1000
             for p in PHASES]
    if MERGE_LAST_TWO:
        means = means[:3] + [means[3] + means[4]]
    tot = [sum(rows["T0_to_T5"][off + i] for off in offs) / 1000 for i in range(3)]
    return means, st.mean(tot), st.stdev(tot)

plt.rcParams.update({
    "font.size": 7,
    "font.family": "sans-serif",
    "font.sans-serif": ["Arial", "Liberation Sans", "DejaVu Sans"],
    "mathtext.fontset": "dejavusans",
})

def panel(offs, outfile, ylabels, figw, xlim, xticks):
    fig, ax = plt.subplots(figsize=(figw, 1.75))
    ys = range(len(CFGS))[::-1]
    for yi, cfg in zip(ys, CFGS):
        means, tot, sd = phase_stats(cfg, offs)
        left = 0.0
        for m, c in zip(means, COLOR):
            if m > 0:
                ax.barh(yi, m, left=left, height=0.62, color=c,
                        edgecolor="white", linewidth=0.6)
            left += m
        ax.annotate(f"{tot:.1f}", xy=(tot + 0.015 * xlim, yi), va="center",
                    fontsize=6, color="#333333")
    ax.set_yticks(list(ys))
    if ylabels:
        ax.set_yticklabels([LABEL[c] for c in CFGS], fontstyle="italic", fontsize=7)
    else:
        ax.set_yticklabels([])
    ax.set_xlim(0, xlim)
    ax.set_xticks(xticks)
    ax.set_xlabel("Wall-clock time (s)", fontsize=7)
    ax.minorticks_off()
    ax.tick_params(axis="y", length=0)
    ax.tick_params(axis="x", labelsize=6.5)
    ax.grid(axis="x", alpha=0.25, lw=0.4)
    ax.set_axisbelow(True)
    fig.tight_layout(pad=0.2)
    for d in ("../figure/", "../jnca/figure/"):
        if os.path.isdir(d):
            fig.savefig(d + outfile)
            print("wrote", d + outfile)
    plt.close(fig)

# Both panels share the same x-range so bar lengths are visually comparable
# across (a) and (b) — (b) is cumulative and must LOOK longer than (a).
panel([1], "provisioning_initial.pdf", True, 2.05, 900, [0, 300, 600, 900])
# (b) cumulative: initial deployment + incremental scale-up, summed per phase
panel([6], "provisioning_scaleup.pdf", False, 1.45, 900, [0, 300, 600, 900])

# legend-only figure, included at natural size (no stretching)
figl = plt.figure(figsize=(3.4, 0.5))
handles = [plt.Rectangle((0, 0), 1, 1, color=c, ec="white") for c in COLOR]
figl.legend(handles, PNAME, loc="center", ncol=4, fontsize=6.5,
            frameon=False, handlelength=1.1, columnspacing=0.9, handletextpad=0.5)
for d in ("../figure/", "../jnca/figure/"):
    if os.path.isdir(d):
        figl.savefig(d + "provisioning_legend.pdf", bbox_inches="tight", pad_inches=0.02)
        print("wrote", d + "provisioning_legend.pdf")
