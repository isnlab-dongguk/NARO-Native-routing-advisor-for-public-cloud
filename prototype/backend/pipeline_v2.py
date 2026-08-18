"""Revised (v2) decision pipeline: merged operator input -> filtering -> TOPSIS.

Implements the paper's Section 4 as revised in 2026-08: a structured form
(baseline preference profile + operator profile) merged with an optional
free-form request (extract_v2), five feasibility rules (target scale,
traffic-path transparency, self-managed Kubernetes, budget limit, required
routing control), and importance-level criterion weights (ignore/low/medium/
high = 0-3). No deployment-parameter stage.

The v1 modules (constraints.py, topsis.py numeric path) remain for the legacy
endpoints; this module is the paper-faithful path used by /api/v2/recommend.
"""
import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from pydantic import BaseModel, Field

from config import (DECISION_MATRIX, WEIGHT_PRESETS,
                    CONFIG_META, cost_of, headroom_of, EFFECTIVE_QUOTA)
from extract_v2 import ExtractedFields

NAME = {"B1": "B-VXLAN", "N1": "N-Cloud", "N2": "N-Static", "N3": "N-Dynamic"}
ALL = ["B1", "N1", "N2", "N3"]

# Paper criterion ids c1..c4 -> code-order column index [tput, conv, fee, provisioning, headroom]
# (convergence, code index 1, is no longer a paper criterion; presets assign it level 0)
PAPER_TO_CODE = {"c1": 0, "c2": 3, "c3": 4, "c4": 2}
CODE_CRIT_NAMES = ["TCP throughput", "Routing convergence time", "Monthly routing cost",
                   "Provisioning time", "Routing scalability"]
CODE_BENEFIT = [True, False, False, False, True]


class OperatorForm(BaseModel):
    """Structured form: canonical interface for the seven input-model fields.

    Every field of Table tab:req-dims can be entered here directly; the
    free-form request only auto-fills the same fields (extract_v2)."""
    scale: Optional[int] = Field(None, description="Target worker-node count")
    transparency_required: bool = Field(False, description="Traffic-path transparency required")
    self_managed_required: bool = Field(False, description="Self-managed Kubernetes required")
    budget_limit_usd: Optional[float] = Field(None, description="Strict monthly budget limit (USD)")
    pod_renumbering: str = Field("unspecified", description="required | automated | unspecified")
    preset: str = Field("balanced", description="cost_first | balanced | perf_first")
    preset_explicit: bool = Field(False, description="True when the operator actively chose the preset")
    expertise: str = Field("unspecified", description="beginner | intermediate | expert | unspecified")


class OperatorInputV2(BaseModel):
    form: OperatorForm = Field(default_factory=OperatorForm)
    freeform_text: Optional[str] = None


class ClarificationNeeded(Exception):
    def __init__(self, question: str):
        self.question = question
        super().__init__(question)


@dataclass
class MergedInput:
    scale: Optional[int]
    transparency_required: bool
    self_managed_required: bool
    budget_limit_usd: Optional[float]
    priority: str                   # cost_first | balanced | perf_first
    pod_renumbering: str = "unspecified"    # required | automated | unspecified
    routing_expertise: str = "unspecified"  # beginner | intermediate | expert | unspecified
    unresolved: List[str] = field(default_factory=list)


def merge(form: OperatorForm, extracted: Optional[ExtractedFields]) -> MergedInput:
    """Merge the structured form (canonical input) with free-form statements.

    Extracted free-form statements fill fields the operator left at their form
    defaults; a conflicting value for a field the operator explicitly set in
    the form raises ClarificationNeeded. Unstated fields stay at their
    unspecified defaults and never eliminate downstream.
    """
    e = extracted
    explicit = form.model_fields_set

    def resolve(name, extr_val, extr_stated, label):
        form_val = getattr(form, name)
        if not extr_stated:
            return form_val
        if name in explicit and form_val != extr_val:
            raise ClarificationNeeded(
                f"The request states {label}, but the form explicitly sets a "
                f"different value ({form_val!r}). Which should apply?")
        return extr_val

    priority = form.preset
    if e and e.stated_priority != "unspecified":
        if (form.preset_explicit or "preset" in explicit) and e.stated_priority != form.preset:
            raise ClarificationNeeded(
                f"The request states a {e.stated_priority.replace('_', '-')} priority, but the form "
                f"explicitly selects the {form.preset.replace('_', '-')} preset. Which should apply?")
        priority = e.stated_priority

    e_expertise = getattr(e, "routing_expertise", "unspecified") if e else "unspecified"
    e_renumbering = getattr(e, "pod_renumbering", "unspecified") if e else "unspecified"

    return MergedInput(
        scale=resolve("scale", e.scale if e else None, bool(e and e.scale is not None),
                      f"a target scale of {e.scale if e else None} nodes"),
        transparency_required=resolve("transparency_required", True,
                                      bool(e and e.transparency_required),
                                      "a traffic-path transparency requirement"),
        self_managed_required=resolve("self_managed_required", True,
                                      bool(e and e.self_managed_required),
                                      "a self-managed Kubernetes requirement"),
        budget_limit_usd=resolve("budget_limit_usd", e.budget_limit_usd if e else None,
                                 bool(e and e.budget_limit_usd is not None),
                                 f"a budget limit of ${e.budget_limit_usd if e else 0}"),
        priority=priority,
        pod_renumbering=resolve("pod_renumbering", e_renumbering,
                                e_renumbering != "unspecified",
                                f"a {e_renumbering} pod-CIDR renumbering requirement"),
        routing_expertise=resolve("expertise", e_expertise, e_expertise != "unspecified",
                                  f"{e_expertise} routing expertise"),
    )


def apply_rules(m: MergedInput) -> Tuple[List[str], Dict[str, str]]:
    """Six feasibility rules of Section 4.3. Unspecified fields never eliminate."""
    eliminated: Dict[str, str] = {}

    if m.pod_renumbering in ("required", "automated") and "N1" not in eliminated:
        eliminated["N1"] = ("in-place pod-CIDR renumbering is required and N-Cloud's pod "
                            "range cannot be changed in place (migration required)")
    if m.pod_renumbering == "automated" and "N2" not in eliminated:
        eliminated["N2"] = ("automated pod-CIDR renumbering is required and N-Static "
                            "requires manual replacement of every per-node route")

    if m.routing_expertise == "beginner" and "N3" not in eliminated:
        eliminated["N3"] = ("beginner routing expertise is stated and N-Dynamic requires "
                            "BGP operation (AS numbers, timers, per-node peer maintenance)")

    if m.scale is not None:  # target scale
        for c, q in EFFECTIVE_QUOTA.items():
            if m.scale > q:
                eliminated[c] = {
                    "N2": f"target scale of {m.scale} nodes exceeds the 200-route static-route quota",
                    "N3": f"target scale of {m.scale} nodes exceeds the 250-prefix learned-route quota",
                }.get(c, f"target scale of {m.scale} nodes exceeds the {q}-node ceiling")

    if m.transparency_required and "B1" not in eliminated:
        eliminated["B1"] = ("traffic-path transparency is required and B-VXLAN carries "
                            "pod traffic inside VXLAN encapsulation")

    if m.self_managed_required and "N1" not in eliminated:
        eliminated["N1"] = ("self-managed Kubernetes is required and N-Cloud is realized "
                            "as a provider-managed cluster")

    if m.budget_limit_usd is not None:
        if m.scale is None:
            raise ClarificationNeeded(
                "A strict monthly budget is stated, but the target cluster scale is needed "
                "to evaluate it. How many worker nodes do you plan to run?")
        for c in ALL:
            if c not in eliminated and cost_of(c, m.scale) > m.budget_limit_usd:
                eliminated[c] = (f"monthly routing fee ${cost_of(c, m.scale):.2f} exceeds the "
                                 f"stated ${m.budget_limit_usd:.2f} budget limit at {m.scale} nodes")

    feasible = [c for c in ALL if c not in eliminated]
    return feasible, eliminated


LEVEL = {"ignore": 0, "low": 1, "medium": 2, "high": 3}
# code-order index -> paper id
CODE_TO_PAPER = {v: k for k, v in PAPER_TO_CODE.items()}


def derive_levels(m: MergedInput, form: OperatorForm) -> List[int]:
    """Importance levels in code order, taken from the selected preset."""
    return list(WEIGHT_PRESETS[m.priority])


def build_matrix(m: MergedInput, feasible: List[str]) -> Tuple[Dict[str, List[float]], List[str]]:
    """Instantiated decision matrix (code order) and the list of dropped criteria."""
    mat = {c: list(DECISION_MATRIX[c]) for c in feasible}
    dropped = []
    for c in feasible:
        if m.scale is not None:
            mat[c][2] = cost_of(c, m.scale)
            mat[c][4] = headroom_of(c, m.scale)
    if m.scale is None:
        dropped = ["c3", "c4"]  # cannot be instantiated without a scale
    return mat, dropped


def topsis(m: MergedInput, form: OperatorForm, feasible: List[str]):
    mat, uninstantiable = build_matrix(m, feasible)
    levels = derive_levels(m, form)
    active = []
    for j in range(5):
        if levels[j] == 0 or CODE_TO_PAPER.get(j) in uninstantiable:
            continue
        if len({round(mat[c][j], 9) for c in feasible}) > 1:
            active.append(j)
    total = sum(levels[j] for j in active)
    if not active or total == 0:
        return [(feasible[0], None)], [], []
    w = {j: levels[j] / total for j in active}
    norm = {j: math.sqrt(sum(mat[c][j] ** 2 for c in feasible)) or 1.0 for j in active}
    v = {c: {j: w[j] * mat[c][j] / norm[j] for j in active} for c in feasible}
    ideal, worst = {}, {}
    for j in active:
        col = [v[c][j] for c in feasible]
        ideal[j], worst[j] = (max(col), min(col)) if CODE_BENEFIT[j] else (min(col), max(col))
    res = []
    for c in feasible:
        dp = math.sqrt(sum((v[c][j] - ideal[j]) ** 2 for j in active))
        dn = math.sqrt(sum((v[c][j] - worst[j]) ** 2 for j in active))
        res.append((c, dn / (dp + dn) if dp + dn else 0.0))
    res.sort(key=lambda x: x[1], reverse=True)
    return res, [CODE_CRIT_NAMES[j] for j in active], [round(w[j], 4) for j in active]


def run(m: MergedInput, form: OperatorForm):
    """Full deterministic pipeline for a merged input. Returns a result dict."""
    feasible, eliminated = apply_rules(m)
    if not feasible:
        relax = {
            "B1": "allowing overlay encapsulation admits B-VXLAN",
            "N1": "accepting a provider-managed cluster admits N-Cloud",
            "N2": "reducing the target scale or raising the route quota retains N-Static",
            "N3": "reducing the target scale or raising the prefix quota retains N-Dynamic",
        }
        return {"infeasible": True,
                "eliminated": {NAME[c]: r for c, r in eliminated.items()},
                "relaxations": [relax[c] for c in eliminated]}
    if m.scale is None:
        m.unresolved.append("target cluster scale unspecified; routing scalability and "
                            "monthly cost criteria omitted from ranking")
    scores, active_names, weights = topsis(m, form, feasible)
    recommended = scores[0][0]
    return {
        "infeasible": False,
        "recommended": recommended,
        "recommended_name": NAME[recommended],
        "description": CONFIG_META[recommended]["description"],
        "scores": [{"config": NAME[c], "phi": (round(p, 3) if p is not None else None)} for c, p in scores],
        "eliminated": {NAME[c]: r for c, r in eliminated.items()},
        "active_criteria": active_names,
        "weights": weights,
        "unresolved": list(m.unresolved),
        "single_feasible": len(feasible) == 1,
    }
