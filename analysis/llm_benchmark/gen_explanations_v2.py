#!/usr/bin/env python3
"""Generate v2 explanations for the paper's case studies (faithfulness audit input).

Matches the revised Section 4.6 contract: the explanation stage receives only
the deterministic decision record — the feasible set with an elimination
reason per removed configuration, the instantiated criterion values and
weights, the resulting phi scores, and any unresolved assumptions — plus the
operator's routing expertise, which controls technical depth. No deployment
parameters are supplied or requested. Output: results_v2/explanations.json.
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

from models import (RequirementVector, InfraPreference, ChurnProfile,  # noqa: E402
                    MaintenancePreference, BgpExpertise, CostSensitivity, PerfPriority)
from constraints import apply_constraints  # noqa: E402
from config import DECISION_MATRIX, MAINTENANCE_FIT, cost_of, headroom_of  # noqa: E402
import topsis as T  # noqa: E402
import llm  # noqa: E402

NAME = {"B1": "B-VXLAN", "N1": "N-Cloud", "N2": "N-Static", "N3": "N-Dynamic"}

# Paper-rule wording for elimination reasons (constraints.py wording is legacy)
def paper_reason(config, raw):
    if "Native" in raw:
        return "traffic-path transparency is required and B-VXLAN carries pod traffic inside VXLAN encapsulation"
    if "requires GKE" in raw:
        return "self-managed Kubernetes is required and N-Cloud is realized as a provider-managed cluster"
    return raw  # scale-quota reasons are already accurate


def req(scale, native, infra, maint, bgp, cost):
    return RequirementVector(
        scale=scale, autoscale=ChurnProfile("none"), native_required=native,
        infra=InfraPreference(infra), maintenance=MaintenancePreference(maint),
        bgp_expertise=BgpExpertise(bgp), cost_sensitivity=CostSensitivity(cost),
        perf_priority=PerfPriority("general"))


CASES = {
    "CS1": req(30, False, "self_managed", "low", "beginner", "cost_first"),
    "CS2": req(150, True, "self_managed", "medium", "intermediate", "cost_first"),
    "CS3": req(400, True, "any", "low", "beginner", "perf_first"),
    "CS4": req(120, True, "any", "low", "intermediate", "perf_first"),
    "CS5": req(200, True, "self_managed", "high", "expert", "perf_first"),
}

# Paper criterion order c1..c6 mapped from code order [tput, conv, fee, effort, fit, headroom]
PAPER_ORDER = [("c1 TCP throughput (Gbps)", 0), ("c2 operational effort (1-4)", 3),
               ("c3 scalability headroom", 5), ("c4 routing convergence time (s)", 1),
               ("c5 routing-control fit", 4), ("c6 monthly routing cost (USD)", 2)]


def build_context(label, r):
    feasible, eliminated = apply_constraints(r)
    scored, weights, preset, active_names = T.score(feasible, r)
    m = {k: list(v) for k, v in DECISION_MATRIX.items()}
    fit = MAINTENANCE_FIT.get(r.maintenance.value)
    for k in m:
        if fit:
            m[k][4] = fit[k]
        m[k][2] = cost_of(k, r.scale)
        m[k][5] = headroom_of(k, r.scale)

    elim_lines = "\n".join(
        f"  - {NAME[c]}: removed because {paper_reason(c, why)}" for c, why in eliminated.items()) or "  none"
    matrix_lines = ""
    for name, j in PAPER_ORDER:
        vals = ", ".join(f"{NAME[c]}={round(m[c][j], 3)}" for c in feasible)
        matrix_lines += f"  - {name}: {vals}\n"
    if len(feasible) > 1:
        score_lines = "\n".join(
            f"  - {NAME[s.config_id]}: phi={s.topsis_score:.3f} (rank {s.rank})" for s in scored)
        decision = f"TOPSIS ranking; recommended: {NAME[scored[0].config_id]}"
        weight_line = f"active criteria after zero-variance removal: {active_names}; normalized weights {[round(w,3) for w in weights]} (preset {preset})"
    else:
        score_lines = "  (single feasible configuration; no scores computed)"
        decision = f"decided by feasibility filtering alone; recommended: {NAME[feasible[0]]}"
        weight_line = "not applicable (singleton feasible set)"

    context = f"""Operator input:
- target cluster scale: {r.scale} worker nodes
- traffic-path transparency required: {r.native_required}
- self-managed Kubernetes required: {r.infra.value == 'self_managed'}
- routing-control direction: {{'low':'delegated','medium':'neutral','high':'direct'}}['{r.maintenance.value}']
- stated priority: {r.cost_sensitivity.value}
- routing expertise: {r.bgp_expertise.value}

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
    return context, feasible, eliminated, scored


PROMPT = (
    "Generate a concise natural-language recommendation explanation (4-6 sentences) "
    "for a Kubernetes operator, based ONLY on the decision record below. "
    "Tie every stated reason to a filtering rule, a criterion value, or a score from "
    "the record. You may outline the major components the recommendation entails "
    "(for example, Cloud Router provisioning and per-node BGP peering for N-Dynamic), "
    "but do not prescribe concrete deployment parameter values such as timers, CIDR "
    "sizes, or thresholds. Match the technical depth to the operator's routing "
    "expertise level. Do not invent measurements or rationale beyond the record.\n\n"
)


def main():
    out = {}
    client = llm._get_client()
    for label, r in CASES.items():
        context, feasible, eliminated, scored = build_context(label, r)
        resp = client.chat.completions.create(
            model=llm._MODEL,
            messages=[
                {"role": "system", "content": llm._SYSTEM_PROMPT},
                {"role": "user", "content": PROMPT + context},
            ],
        )
        text = resp.choices[0].message.content
        out[label] = {"context": context, "explanation": text}
        print(f"=== {label} ===\n{text}\n")
    path = os.path.join(HERE, "results_v2", "explanations.json")
    json.dump(out, open(path, "w"), indent=1)
    print("wrote", path)


if __name__ == "__main__":
    main()
