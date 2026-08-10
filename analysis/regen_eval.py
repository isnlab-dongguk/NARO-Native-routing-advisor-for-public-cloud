#!/usr/bin/env python3
"""Regenerate the paper's case-study numbers from the v2 decision engine
(five measured criteria: c1 tput, c2 provisioning, c3 scalability,
c4 convergence, c5 monthly cost)."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "prototype", "backend"))
from pipeline_v2 import OperatorForm, merge, apply_rules, topsis, NAME
from extract_v2 import ExtractedFields

# name, scale, transparency, self_managed, capability, priority, expertise
CASES = [
    ("Case 1 startup",        30,  False, True,  False, "cost_first", "beginner"),
    ("Case 2 fintech",        150, True,  True,  False, "cost_first", "intermediate"),
    ("Case 3 e-commerce",     400, True,  False, False, "perf_first", "beginner"),
    ("Case 4 SaaS",           120, True,  False, False, "perf_first", "intermediate"),
    ("Case 5 spot batch",     200, True,  True,  True,  "perf_first", "expert"),
]

def run_case(scale, tr, sm, cap, prio, exp):
    e = ExtractedFields(scale=scale, transparency_required=tr, self_managed_required=sm,
                        budget_limit_usd=None, control_capability_required=cap,
                        stated_priority=prio, routing_expertise=exp)
    form = OperatorForm()
    m = merge(form, e)
    feas, elim = apply_rules(m)
    scores, names, w = topsis(m, form, feas)
    return feas, elim, scores, names, w

if __name__ == "__main__":
    for name, *args in CASES:
        feas, elim, scores, names, w = run_case(*args)
        print(f"### {name}  [{args[4]}]")
        print(f"  eliminated: {[NAME[c] for c in elim]}")
        print(f"  weights: {dict(zip(names, w))}")
        for c, p in scores:
            print(f"    {NAME[c]:<10} phi={'-' if p is None else round(p,3)}")
        print()
    # Case 4 cost-first variant (Section 5.4 robustness remark)
    feas, elim, scores, names, w = run_case(120, True, False, False, "cost_first", "intermediate")
    print("### Case 4 variant (cost-first)")
    for c, p in scores:
        print(f"    {NAME[c]:<10} phi={round(p,3)}")
