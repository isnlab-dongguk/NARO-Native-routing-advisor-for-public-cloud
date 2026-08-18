#!/usr/bin/env python3
"""E5 extraction benchmark, v2 schema (revised input model).

For each scenario in scenarios_v2.json:
  - 3 schema-constrained runs through the engine extractor (extract_v2.extract)
  - 1 free-form ablation run (same model/system prompt, JSON requested as text)

Raw outcomes are appended to results_v2/raw_runs.jsonl as they complete.
Re-running skips (scenario, mode, repeat) combinations already present.
"""
import json
import os
import re
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "prototype", "backend"))

# .env for the gateway key
for line in open(os.path.join(HERE, "..", "..", "prototype", ".env")):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        os.environ.setdefault(k, v.strip().strip('"'))

import llm  # noqa: E402
import extract_v2 as ex  # noqa: E402

RESULTS_DIR = os.path.join(HERE, "results_v2")
RAW_PATH = os.path.join(RESULTS_DIR, "raw_runs.jsonl")
N_REPEATS = 3
_write_lock = threading.Lock()

FREEFORM_INSTRUCTIONS = (
    "Extract the deployment requirements from the following operator description. "
    "Respond with only a JSON object with keys: scale (integer worker-node count or null), "
    "transparency_required (boolean), self_managed_required (boolean), "
    "budget_limit_usd (number or null; only a strict monthly limit on routing-/managed-service fees), "
    "stated_priority ('cost_first', 'balanced', 'perf_first', or 'unspecified'), "
    "pod_renumbering ('required', 'automated', or 'unspecified'; only when in-place pod-CIDR renumbering is stated as a requirement), "
    "routing_expertise ('beginner', 'intermediate', 'expert', or 'unspecified'). "
    "If the cluster size is not stated, respond instead with "
    '{"clarification": "<your question to the operator>"}.'
    "\n\nOperator description:\n\n"
)


def call_schema(text):
    try:
        r = ex.extract(text)
        return {"outcome": "vector", "vector": r.as_dict()}
    except ex.ClarificationNeeded as e:
        return {"outcome": "clarification", "question": e.question}


def call_freeform(text):
    client = llm._get_client()
    resp = client.chat.completions.create(
        model=llm._MODEL,
        messages=[
            {"role": "system", "content": ex.SYSTEM_PROMPT},
            {"role": "user", "content": FREEFORM_INSTRUCTIONS + text},
        ],
    )
    raw = resp.choices[0].message.content or ""
    m = re.search(r"\{.*\}", raw, re.S)
    if not m:
        return {"outcome": "parse_error", "raw": raw[:500]}
    try:
        data = json.loads(m.group(0))
    except json.JSONDecodeError:
        return {"outcome": "parse_error", "raw": raw[:500]}
    if "clarification" in data:
        return {"outcome": "clarification", "question": data["clarification"]}
    return {"outcome": "vector", "vector": data}


def main():
    os.makedirs(RESULTS_DIR, exist_ok=True)
    scen = json.load(open(os.path.join(HERE, "scenarios_v2.json")))["scenarios"]
    done = set()
    if os.path.exists(RAW_PATH):
        for line in open(RAW_PATH):
            r = json.loads(line)
            done.add((r["id"], r["mode"], r["repeat"]))
    jobs = []
    for x in scen:
        for i in range(N_REPEATS):
            if (x["id"], "schema", i) not in done:
                jobs.append((x, "schema", i))
        if (x["id"], "freeform", 0) not in done:
            jobs.append((x, "freeform", 0))
    print(f"{len(jobs)} calls to run ({len(done)} already done)")

    def work(job):
        x, mode, rep = job
        out = call_schema(x["text"]) if mode == "schema" else call_freeform(x["text"])
        rec = {"id": x["id"], "mode": mode, "repeat": rep, **out}
        with _write_lock:
            with open(RAW_PATH, "a") as f:
                f.write(json.dumps(rec) + "\n")
        return x["id"], mode, rep, out["outcome"]

    with ThreadPoolExecutor(max_workers=2) as pool:
        futs = [pool.submit(work, j) for j in jobs]
        for n, fut in enumerate(as_completed(futs), 1):
            sid, mode, rep, oc = fut.result()
            print(f"[{n}/{len(jobs)}] {sid} {mode}#{rep}: {oc}", flush=True)


if __name__ == "__main__":
    main()
