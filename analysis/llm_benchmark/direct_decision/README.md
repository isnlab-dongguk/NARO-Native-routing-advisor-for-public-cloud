# Direct-decision comparison (paper Case 5)

These scripts ask an LLM to choose a pod-networking configuration directly from
the Case 5 operator request, bypassing the NARO pipeline. Each script runs 10
repetitions without and 10 with the measured decision-matrix values in the
prompt (20 calls per variant).

| Variant | Request wording | LLM choice (20 runs) | NARO |
|---|---|---|---|
| `run_perf_first.py` | performance-first, "over BGP" wording | 20/20 N-Dynamic | N-Dynamic (0.508 vs 0.492) |
| `run_cost_first.py` | cost-first, "over BGP" wording | 20/20 N-Dynamic | N-Static (0.720 vs 0.280) |
| `run_cost_first_neutral.py` | cost-first, BGP wording neutralized | 20/20 N-Static | N-Static (same input as above) |

The stored `results_*.json` files were produced with `LLM_MODEL=gpt-5.6-luna`
through an OpenAI-compatible endpoint (see `prototype/.env.example`). Re-running
requires API access; NARO's reference scores reproduce offline via
`analysis/regen_eval.py` and the engine in `prototype/backend/`.
