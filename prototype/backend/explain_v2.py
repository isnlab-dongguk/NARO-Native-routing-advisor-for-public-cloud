"""Explanation generation for the v2 pipeline (Section 4.6 contract).

The generator receives only the deterministic decision record: elimination
reasons, instantiated criterion values, weights, scores, and unresolved
inputs, No deployment parameters.
"""
from typing import Optional

import llm
from config import DECISION_MATRIX, cost_of, headroom_of
from pipeline_v2 import MergedInput, NAME, PAPER_TO_CODE

PAPER_ORDER = [("c1 TCP throughput (Gbps)", 0), ("c2 provisioning time (s)", 3),
               ("c3 routing scalability (remaining ceiling share)", 4),
               ("c4 monthly routing cost (USD)", 2)]

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


def build_context(m: MergedInput, result: dict, feasible_ids) -> str:
    mat = {c: list(DECISION_MATRIX[c]) for c in feasible_ids}
    for c in feasible_ids:
        if m.scale is not None:
            mat[c][2] = cost_of(c, m.scale)
            mat[c][4] = headroom_of(c, m.scale)
    matrix_lines = ""
    for name, j in PAPER_ORDER:
        if m.scale is None and j in (2, 4):
            continue
        vals = ", ".join(f"{NAME[c]}={round(mat[c][j], 3)}" for c in feasible_ids)
        matrix_lines += f"  - {name}: {vals}\n"
    elim = "\n".join(f"  - {c}: removed because {r}" for c, r in result["eliminated"].items()) or "  none"
    if result.get("single_feasible"):
        scores = "  (single feasible configuration; no scores computed)"
        weights = "not applicable (singleton feasible set)"
    else:
        scores = "\n".join(f"  - {s['config']}: phi={s['phi']}" for s in result["scores"])
        weights = f"active criteria {result['active_criteria']}; normalized weights {result['weights']}"
    unresolved = "\n".join(f"  - {u}" for u in result["unresolved"]) or "  none"
    return f"""Operator input:
- target cluster scale: {m.scale if m.scale is not None else 'unspecified'}
- traffic-path transparency required: {m.transparency_required}
- self-managed Kubernetes required: {m.self_managed_required}
- strict monthly budget: {m.budget_limit_usd if m.budget_limit_usd is not None else 'none stated'}
- stated priority: {m.priority}

Eliminated configurations (feasibility filtering):
{elim}

Instantiated criterion values for the feasible set:
{matrix_lines.rstrip()}

Criterion weights:
  {weights}

Scores:
{scores}

Recommended: {result['recommended_name']}
Unresolved inputs:
{unresolved}
"""


def generate(m: MergedInput, result: dict, feasible_ids,
             original_text: Optional[str] = None) -> str:
    context = build_context(m, result, feasible_ids)
    if original_text:
        context = f'Operator\'s original request:\n"{original_text}"\n\n' + context
    client = llm._get_client()
    resp = client.chat.completions.create(
        model=llm._MODEL,
        messages=[
            {"role": "system", "content": llm._SYSTEM_PROMPT},
            {"role": "user", "content": PROMPT + context},
        ],
    )
    return resp.choices[0].message.content
