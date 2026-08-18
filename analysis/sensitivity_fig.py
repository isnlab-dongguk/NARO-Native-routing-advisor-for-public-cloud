#!/usr/bin/env python3
"""Sensitivity-analysis figure (candidate for Section 5.4).

For each scored case study, perturbs one base-preset weight at a time by
+-0.05 (mirroring regen_eval.py), recomputes TOPSIS with the actual engine
code paths, and plots the margin of the base winner over its best challenger:
  margin = phi(base winner) - max phi(other feasible configuration)
Negative margin = the perturbation flips the recommendation.

Outputs figure/sensitivity_margin.pdf (+ preview PNG) and
sensitivity_margin_data.csv.
Style matches dataplane_fig.py / llm_eval_fig.py.
"""
import csv
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "prototype", "backend"))

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CRIT = ["Tput", "Conv", "Fee", "Prov", "Scal"]  # code order

import os, sys
sys.path.insert(0, os.path.join(HERE, "..", "prototype", "backend"))
from config import DECISION_MATRIX, CRITERIA_BENEFIT, WEIGHT_PRESETS, cost_of, headroom_of

# case -> (feasible ids, scale, preset)
CASES = {
    # CS1: beginner routing expertise removes N3 during filtering (Section 4.3)
    "CS1": (["B1", "N2"], 30,  "cost_first"),
    "CS2": (["N2", "N3"],       150, "cost_first"),
    # CS3: scale rule removes N2 at 230 nodes (201-250 window); transparency removes B1
    "CS3": (["N1", "N3"],       230, "balanced"),
    "CS4": (["N1", "N2", "N3"], 120, "perf_first"),
}

def eff_matrix(feas, n):
    m = {c: list(DECISION_MATRIX[c]) for c in feas}
    for c in feas:
        m[c][2] = cost_of(c, n)
        m[c][4] = headroom_of(c, n)
    return m

def topsis_with_weights(feasible, weights, m):
    active = [j for j in range(5)
              if len({round(m[c][j], 9) for c in feasible}) > 1 and weights[j] > 0]
    wsum = sum(weights[j] for j in active)
    w = [weights[j] / wsum for j in active]
    ben = [CRITERIA_BENEFIT[j] for j in active]
    sub = {c: [m[c][j] for j in active] for c in feasible}
    nc = len(active)
    norms = [math.sqrt(sum(sub[c][j] ** 2 for c in feasible)) for j in range(nc)]
    wt = {c: [w[j] * sub[c][j] / norms[j] if norms[j] else 0 for j in range(nc)]
          for c in feasible}
    ip = [max(wt[c][j] for c in feasible) if ben[j] else min(wt[c][j] for c in feasible)
          for j in range(nc)]
    inn = [min(wt[c][j] for c in feasible) if ben[j] else max(wt[c][j] for c in feasible)
           for j in range(nc)]
    res = {}
    for c in feasible:
        dp = math.sqrt(sum((wt[c][j] - ip[j]) ** 2 for j in range(nc)))
        dn = math.sqrt(sum((wt[c][j] - inn[j]) ** 2 for j in range(nc)))
        res[c] = dn / (dp + dn) if dp + dn else 0.0
    return res

rows = []
margins = {}
for label, (feasible, n, preset) in CASES.items():
    lv = WEIGHT_PRESETS[preset]
    t = float(sum(lv))
    weights = [x / t for x in lv]
    M = eff_matrix(feasible, n)
    # Drop zero-variance criteria first, then normalize over the active set, so the
    # +-0.05 step is applied to the weights the ranking actually uses (Section 5.4).
    active = [j for j in range(5)
              if len({round(M[c][j], 9) for c in feasible}) > 1 and weights[j] > 0]
    weights = [weights[j] if j in active else 0.0 for j in range(5)]
    t = sum(weights)
    weights = [x / t for x in weights]
    base_phi = topsis_with_weights(feasible, weights, M)
    base_winner = max(base_phi, key=base_phi.get)
    base_margin = base_phi[base_winner] - max(v for c, v in base_phi.items() if c != base_winner)
    pts = []
    for j in range(5):
        if weights[j] == 0:  # inactive: zero-variance or not in the paper's criterion set
            continue
        for delta in (+0.05, -0.05):
            w = list(weights)
            w[j] = max(0.0, w[j] + delta)
            t2 = sum(w)
            w = [x / t2 for x in w]
            phi = topsis_with_weights(feasible, w, M)
            margin = phi[base_winner] - max(v for c, v in phi.items() if c != base_winner)
            pts.append((f"{CRIT[j]}{'+' if delta > 0 else '-'}", margin))
            rows.append([label, CRIT[j], f"{delta:+.2f}", f"{margin:.4f}"])
    margins[label] = (base_margin, pts)
    rows.append([label, "base", "0.00", f"{base_margin:.4f}"])

with open(os.path.join(HERE, "fig6_sensitivity_margin.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["# Figure 6 data: recommendation margin under +-0.05 perturbations of one active criterion weight."])
    w.writerow(["# Computed by the decision engine, not measured; delta 0.00 is the unperturbed base."])
    w.writerow(["figure", "case", "perturbed_criterion", "delta", "margin"])
    w.writerows(rows)

plt.rcParams.update({
    "font.size": 8,
    "font.family": "sans-serif",
    "font.sans-serif": ["Arial", "Liberation Sans", "DejaVu Sans"],
    "mathtext.fontset": "dejavusans",
})

C_STABLE = "#5B7A9D"
C_FLIP = "#B5453C"

fig, ax = plt.subplots(figsize=(3.3, 1.55))
order = ["CS1", "CS2", "CS3", "CS4"]
for i, label in enumerate(order):
    base_margin, pts = margins[label]
    for name, m in pts:
        color = C_FLIP if m < 0 else C_STABLE
        ax.plot(m, i, "o", ms=3.6, mfc=color, mec="white", mew=0.4, zorder=3)
    ax.plot(base_margin, i, "D", ms=4.2, mfc="none", mec="#333333", mew=0.7, zorder=4)
ax.axvline(0, color="#333333", lw=0.7, zorder=2)
ax.set_yticks(range(len(order)))
ax.set_yticklabels([l.replace("CS", "Case ") for l in order], fontsize=7)
ax.invert_yaxis()
ax.set_ylim(3.5, -0.5)
ax.set_xlim(-0.2, 1.0)
ax.set_xticks([-0.2, 0.0, 0.2, 0.4, 0.6, 0.8, 1.0])
ax.set_xlabel("Margin $\\Delta$", fontsize=8, labelpad=1)
ax.tick_params(axis="x", labelsize=7)
ax.tick_params(axis="y", length=0)
ax.minorticks_off()
ax.grid(axis="x", alpha=0.25, lw=0.4)
ax.set_axisbelow(True)
handles = [
    plt.Line2D([], [], marker="o", ls="", ms=3.6, mfc=C_STABLE, mec="white", mew=0.4,
               label="Stable"),
    plt.Line2D([], [], marker="o", ls="", ms=3.6, mfc=C_FLIP, mec="white", mew=0.4,
               label="Flips"),
    plt.Line2D([], [], marker="D", ls="", ms=4.2, mfc="none", mec="#333333", mew=0.7,
               label="Base"),
]
ax.legend(handles=handles, fontsize=7, frameon=False, loc="lower center",
          bbox_to_anchor=(0.5, 1.0), ncol=3, borderpad=0.1,
          handlelength=0.9, handletextpad=0.3, columnspacing=0.7)
fig.tight_layout(pad=0.25)
for figdir in (os.path.join(HERE, "..", "figure"),
               os.path.join(HERE, "..", "jnca", "figure")):  # both builds read their own copy
    if os.path.isdir(figdir):
        fig.savefig(os.path.join(figdir, "sensitivity_margin.pdf"))
        print("wrote", os.path.relpath(os.path.join(figdir, "sensitivity_margin.pdf"),
                                       os.path.join(HERE, "..")))
fig.savefig(os.path.join(HERE, "..", "figure", "sensitivity_margin_preview.png"), dpi=300)
plt.close(fig)
for label in order:
    b, pts = margins[label]
    neg = [p for p in pts if p[1] < 0]
    print(f"{label}: base margin {b:+.3f}, perturbed range "
          f"[{min(m for _, m in pts):+.3f}, {max(m for _, m in pts):+.3f}], flips={neg}")
