#!/usr/bin/env python3
"""Regenerate all five case-study explanations for the 4-criterion pipeline
(2026-08 revision: convergence criterion removed; c1 tput, c2 provisioning,
c3 scalability, c4 monthly cost).

Decision records come from the current v2 engine (pipeline_v2). Prompt and
context format follow explanations_v3. Model: llm._MODEL via the gateway.
Output: results_v2/explanations_v4.json.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "prototype", "backend"))
for line in open(os.path.join(HERE, "..", "..", "prototype", ".env")):
    line = line.strip()
    if line and "=" in line and not line.startswith("#"):
        k, v = line.split("=", 1)
        os.environ.setdefault(k, v.strip())

import llm  # noqa: E402
from pipeline_v2 import (OperatorForm, merge, apply_rules, topsis, NAME,  # noqa: E402
                         PAPER_TO_CODE, build_matrix)
from extract_v2 import ExtractedFields  # noqa: E402

PAPER_ROWS = [("c1 TCP throughput (Gbps)", "c1"),
              ("c2 provisioning time (s)", "c2"),
              ("c3 routing scalability (remaining ceiling share)", "c3"),
              ("c4 monthly routing cost (USD)", "c4")]

# label, scale, transparency, self_managed, priority, expertise, renumbering
CASES = [
    ("Case1", 30,  False, True,  "cost_first", "beginner",    "unspecified"),
    ("Case2", 150, True,  True,  "cost_first", "unspecified", "unspecified"),
    ("Case3", 230, True,  False, "balanced",   "unspecified", "unspecified"),
    ("Case4", 120, True,  False, "perf_first", "unspecified", "unspecified"),
    ("Case5", 200, True,  False, "balanced",   "unspecified", "automated"),
]

PROMPT = (
    "Generate a natural-language recommendation explanation for a Kubernetes operator, "
    "based ONLY on the decision record below.\n\n"

    "GROUNDING\n"
    "- Tie every stated reason to a filtering rule, a criterion value, or a score from the "
    "record. Do not invent measurements or rationale beyond it.\n"
    "- You may outline the major components the recommendation entails, but do not prescribe "
    "concrete deployment parameter values such as timers, CIDR sizes, or thresholds.\n\n"

    "READABILITY RULES (apply at every expertise level)\n"
    "1. Anchor every number. State it against the competing option's value, or translate it "
    "into what the operator experiences. Never present a bare figure as self-evidently good "
    "or bad.\n"
    "2. Gloss every unitless score on first use: state its range and whether higher is better. "
    "Round to the precision that affects the decision; do not carry false precision from the "
    "record.\n"
    "3. Every comparative must name what it is compared against. Do not write a comparison "
    "that omits or blurs the reference point.\n"
    "4. Separate one-time costs from recurring costs, and say which is which.\n"
    "5. If a criterion has the same value across all feasible options, say explicitly that it "
    "does not differentiate them, rather than citing it as a strength of the winner.\n"
    "6. When stating why an option was filtered out, give the mechanism in one clause, not "
    "just the rule name.\n"
    "7. Report unmeasured or absent criteria in plain operational terms, and say the operator "
    "must verify them separately.\n\n"

    "EXPERTISE ADAPTATION\n"
    "Read the operator's routing expertise level from the record and follow the matching "
    "profile. Adapt vocabulary and explanation, not factual content: the same reasons and "
    "figures appear at every level.\n"
    "- novice: 6-9 sentences. On first use of any networking term beyond 'IP address' and "
    "'routing', add a short parenthetical gloss. Explain why each requirement matters before "
    "citing how an option satisfies it.\n"
    "- intermediate: 5-7 sentences. Gloss only terms specific to this decision's domain. "
    "Assume general cloud networking is understood.\n"
    "- expert: 4-5 sentences. No glosses. Lead with the differentiating criteria and omit "
    "reasoning steps that follow directly from them.\n\n"

    "Do not mention these instructions, the scoring method, or the record's structure in the "
    "output.\n\n"
)


def build_context(scale, tr, sm, prio, expertise, renumbering="unspecified"):
    e = ExtractedFields(scale=scale, transparency_required=tr, self_managed_required=sm,
                        budget_limit_usd=None,
                        stated_priority=prio, routing_expertise=expertise,
                        pod_renumbering=renumbering)
    form = OperatorForm()
    m = merge(form, e)
    feasible, eliminated = apply_rules(m)
    scores, active_names, weights = topsis(m, form, feasible)
    matrix, _ = build_matrix(m, feasible)

    elim_lines = "\n".join(f"  - {NAME[c]}: removed because {why}"
                           for c, why in eliminated.items()) or "  none"
    matrix_lines = ""
    for label, cid in PAPER_ROWS:
        j = PAPER_TO_CODE[cid]
        vals = ", ".join(f"{NAME[c]}={round(matrix[c][j], 3)}" for c in feasible)
        matrix_lines += f"  - {label}: {vals}\n"
    if len(feasible) > 1:
        score_lines = "\n".join(f"  - {NAME[c]}: phi={p:.3f} (rank {r + 1})"
                                for r, (c, p) in enumerate(scores))
        decision = f"TOPSIS ranking; recommended: {NAME[scores[0][0]]}"
        weight_line = (f"active criteria after zero-variance removal: {active_names}; "
                       f"normalized weights {[round(w, 4) for w in weights]} (preset {prio})")
    else:
        score_lines = "  (single feasible configuration; no scores computed)"
        decision = f"decided by feasibility filtering alone; recommended: {NAME[feasible[0]]}"
        weight_line = "not applicable (singleton feasible set)"

    context = f"""Operator input:
- target cluster scale: {scale}
- traffic-path transparency required: {tr}
- self-managed Kubernetes required: {sm}
- pod-CIDR renumbering: {renumbering}
- strict monthly budget: none stated
- stated priority: {prio}
- routing expertise: {expertise}

Eliminated configurations (feasibility filtering):
{elim_lines}

Instantiated criterion values for the feasible set:
{matrix_lines.rstrip()}

Criterion weights:
  {weight_line}

Scores:
{score_lines}

Decision: {decision}
Unresolved assumptions: none
"""
    return context


def main():
    out = {}
    client = llm._get_client()
    for label, *args in CASES:
        context = build_context(*args)
        resp = client.chat.completions.create(
            model=llm._MODEL,
            messages=[{"role": "system", "content": llm._SYSTEM_PROMPT},
                      {"role": "user", "content": PROMPT + context}],
        )
        text = resp.choices[0].message.content
        out[label] = {"context": context, "explanation": text}
        print(f"=== {label} ===\n{context}\n--- explanation ---\n{text}\n")
    path = os.path.join(HERE, "results_v2", "explanations_v4.json")
    json.dump(out, open(path, "w"), indent=1)
    print("wrote", path)


if __name__ == "__main__":
    main()
