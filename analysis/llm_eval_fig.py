#!/usr/bin/env python3
"""E5 LLM-evaluation figure (candidate for Section 5.5).

Produces two PDFs for a single-column subfigure layout:
  figure/llm_eval_extraction.pdf — (a) extraction accuracy, schema-constrained
                                    vs free-form ablation, per field + exact vector
  figure/llm_eval_audit.pdf      — (b) explanation-faithfulness audit, checkable
                                    statements per case study (supported/flawed)

Data: llm_benchmark/results/summary.json (extraction) and the claim tallies of
llm_benchmark/results/faithfulness_audit.md (audit).
Style matches dataplane_fig.py / convergence_fig.py.
"""
import json
import os
import re
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))

# ── (a) extraction accuracy, v2 benchmark (results_v2/summary.txt) ───────────
with open(os.path.join(HERE, "llm_benchmark", "results_v2", "summary.txt")) as f:
    txt = f.read()

def parse_mode(name):
    block = txt.split(f"=== {name} ===")[1].split("===")[0]
    runs = int(re.search(r"specified runs: (\d+)", block).group(1))
    exact = float(re.search(r"exact-vector: \d+ \((\d+\.\d)%\)", block).group(1))
    m = re.search(r"errors by field: (\{[^}]*\})", block)
    errors = eval(m.group(1)) if m else {}
    return runs, exact, errors

FIELDS = ["scale", "transparency_required", "self_managed_required", "budget_limit_usd",
          "control_capability_required", "control_direction", "stated_priority", "routing_expertise"]
LABELS = ["Scale", "Transparency", "Self-managed", "Budget", "Capability", "Direction",
          "Priority", "Expertise", "Exact vector"]

def acc(name):
    runs, exact, errors = parse_mode(name)
    # count scale errors only among specified runs (clarification runs scored separately)
    vals = [100.0 * (runs - errors.get(f, 0)) / runs for f in FIELDS]
    vals.append(exact)
    return vals

plt.rcParams.update({
    "font.size": 7,
    "font.family": "sans-serif",
    "font.sans-serif": ["Arial", "Liberation Sans", "DejaVu Sans"],
    "mathtext.fontset": "dejavusans",
    "hatch.linewidth": 0.4,
})

C_SCHEMA = "#E8860B"
C_FREE = "#C7CDD6"
C_OK = "#8D96A3"
C_FLAW = "#B5453C"

schema_v, free_v = acc("schema"), acc("freeform")

fig, ax = plt.subplots(figsize=(3.3, 1.55))
x = range(len(LABELS))
w = 0.38
ax.bar([i - w / 2 for i in x], free_v, width=w, color=C_FREE,
       edgecolor="white", linewidth=0.5, label="w/o function calling")
ax.bar([i + w / 2 for i in x], schema_v, width=w, color=C_SCHEMA,
       edgecolor="white", linewidth=0.5, hatch="////", label="NARO")
ax.set_ylabel("Accuracy (%)", fontsize=6.5, labelpad=1)
ax.set_ylim(0, 112)
ax.set_yticks([0, 25, 50, 75, 100])
ax.set_xticks(list(x))
ax.set_xticklabels(LABELS, fontsize=5.3, rotation=30, ha="right")
ax.minorticks_off()
ax.tick_params(axis="y", labelsize=6)
ax.tick_params(axis="x", length=0)
ax.grid(axis="y", alpha=0.25, lw=0.4)
ax.set_axisbelow(True)
ax.legend(fontsize=5.3, frameon=False, loc="lower left",
          bbox_to_anchor=(0.0, 1.0), ncol=2, borderpad=0.1,
          handlelength=1.1, handletextpad=0.4, columnspacing=0.8)
fig.tight_layout(pad=0.25)
fig.savefig(os.path.join(HERE, "..", "figure", "llm_eval_extraction.pdf"))
fig.savefig(os.path.join(HERE, "..", "figure", "llm_eval_extraction_preview.png"), dpi=300)
plt.close(fig)
print("wrote figure/llm_eval_extraction.pdf")

# (b) faithfulness audit: checkable statements per case (results_v2/faithfulness_audit_v2.md;
# paper labels — Case 5 is the 200-node contested case)
CASES = ["Case 1", "Case 2", "Case 3", "Case 4", "Case 5"]
OK = [8, 11, 10, 8, 10]
FLAW = [0, 0, 0, 0, 0]

fig, ax = plt.subplots(figsize=(1.55, 1.55))
y = range(len(CASES))
ax.barh(list(y), OK, height=0.62, color=C_OK, edgecolor="white",
        linewidth=0.5, label="Supported")
ax.barh(list(y), FLAW, left=OK, height=0.62, color=C_FLAW,
        edgecolor="white", linewidth=0.5, label="Flawed")
ax.set_xlabel("Checkable statements", fontsize=6.5, labelpad=1)
ax.set_xlim(0, 11.6)
ax.set_xticks([0, 4, 8])
ax.set_yticks(list(y))
ax.set_yticklabels(CASES, fontsize=5.3)
ax.invert_yaxis()
ax.minorticks_off()
ax.tick_params(axis="x", labelsize=6)
ax.tick_params(axis="y", length=0)
ax.grid(axis="x", alpha=0.25, lw=0.4)
ax.set_axisbelow(True)
ax.legend(fontsize=5.3, frameon=False, loc="lower center",
          bbox_to_anchor=(0.5, 1.0), ncol=2, borderpad=0.1,
          handlelength=1.1, handletextpad=0.4, columnspacing=0.8)
fig.tight_layout(pad=0.25)
fig.savefig(os.path.join(HERE, "..", "figure", "llm_eval_audit.pdf"))
fig.savefig(os.path.join(HERE, "..", "figure", "llm_eval_audit_preview.png"), dpi=300)
plt.close(fig)
print("wrote figure/llm_eval_audit.pdf")
