#!/usr/bin/env python3
"""Score the v2 extraction benchmark (results_v2/raw_runs.jsonl)."""
import json
import os
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
FIELDS = ["scale", "transparency_required", "self_managed_required", "budget_limit_usd",
          "control_capability_required", "stated_priority", "routing_expertise"]


def norm(v, field):
    if field == "budget_limit_usd":
        return None if v in (None, "null") else float(v)
    if field == "scale":
        return None if v is None else int(v)
    return v


def match(vec, truth):
    errs = []
    for f in FIELDS:
        got = norm(vec.get(f), f)
        want = norm(truth.get(f), f)
        if got != want:
            errs.append((f, want, got))
    return errs


def main():
    scen = {x["id"]: x for x in json.load(open(os.path.join(HERE, "scenarios_v2.json")))["scenarios"]}
    runs = [json.loads(l) for l in open(os.path.join(HERE, "results_v2", "raw_runs.jsonl"))]

    for mode in ("schema", "freeform"):
        sel = [r for r in runs if r["mode"] == mode]
        clar_ids = {sid for sid, x in scen.items() if x["expect_clarification"]}
        spec = [r for r in sel if r["id"] not in clar_ids]
        clar = [r for r in sel if r["id"] in clar_ids]

        exact = 0
        parse_err = 0
        spurious_clar = 0
        field_errors = []
        per_field = defaultdict(int)
        for r in spec:
            if r["outcome"] == "clarification":
                spurious_clar += 1
                continue
            if r["outcome"] == "parse_error":
                parse_err += 1
                continue
            errs = match(r["vector"], scen[r["id"]]["truth"])
            if not errs:
                exact += 1
            else:
                field_errors.append((r["id"], r["repeat"], errs))
                for f, _, _ in errs:
                    per_field[f] += 1
        clar_ok = sum(1 for r in clar if r["outcome"] == "clarification")

        # per-scenario consistency across repeats (schema mode)
        incons = []
        if mode == "schema":
            by_id = defaultdict(list)
            for r in spec:
                key = json.dumps(r.get("vector"), sort_keys=True) if r["outcome"] == "vector" else r["outcome"]
                by_id[r["id"]].append(key)
            incons = [sid for sid, ks in by_id.items() if len(set(ks)) > 1]

        n = len(spec)
        print(f"\n=== {mode} ===")
        print(f"specified runs: {n}; exact-vector: {exact} ({exact/n*100:.1f}%)"
              f"; parse errors: {parse_err}; spurious clarifications: {spurious_clar}")
        print(f"clarification runs: {len(clar)}; correctly clarified: {clar_ok}")
        if mode == "schema":
            print(f"repeat-inconsistent scenarios: {incons or 'none'}")
        if per_field:
            print("errors by field:", dict(per_field))
        for sid, rep, errs in field_errors:
            print(f"  {sid}#{rep}: " + "; ".join(f"{f}: want={w!r} got={g!r}" for f, w, g in errs))


if __name__ == "__main__":
    main()
