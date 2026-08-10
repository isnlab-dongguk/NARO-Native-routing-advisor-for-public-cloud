# NARO: NAtive ROuting Advisor for Public-Cloud Kubernetes

Artifact for the paper **"Understanding and Selecting Native Routing for Kubernetes in Public Clouds: Empirical Characterization and Design of an LLM-Assisted Decision-Support Framework"** (under submission).

NARO is a decision-support framework that recommends a pod-networking configuration
(VXLAN overlay, static VPC routes, dynamic BGP via a cloud-managed router, or
provider-managed native routing) for a Kubernetes deployment on a public cloud.
It filters infeasible configurations against the operator's mandatory constraints,
ranks the remainder with TOPSIS over a measurement-grounded decision matrix, and
uses an LLM only as a natural-language interface for requirement extraction and
explanation generation.

## Repository layout

```
prototype/            Web prototype (FastAPI backend + single-page frontend)
  backend/            Decision engine (pipeline_v2.py = the paper-faithful path,
                      served at POST /api/v2/recommend), LLM extraction/explanation
  static/             Browser UI
analysis/             Measurement data (CSV) and figure/analysis scripts
  llm_benchmark/      LLM extraction benchmark (50 scenarios) and its results
figure/               Output directory for the figure scripts (generated, not tracked)
```

## Measurement data

All measurements were taken on Google Cloud (`asia-northeast3`) with Cilium;
values are from three repetitions per configuration and scenario (see the paper
for the full methodology).

| File | Contents |
|---|---|
| `analysis/dataplane_v3_data.csv` | TCP throughput and CPU shares (3-run means) |
| `analysis/convergence_fig4_data.csv` | Route convergence time per scenario (3-run means) |
| `analysis/routing_convergence.xlsx` | Raw convergence measurements, per repetition |
| `analysis/provisioning_raw.xlsx` | Raw provisioning measurements, per repetition |
| `analysis/provisioning_time_raw.csv` | Deployment/scale-up phase times, per repetition |
| `analysis/provisioning_time_summary.csv` | The same, as mean and SD (n = 3) |
| `analysis/provisioning_fig3_data.csv`, `analysis/fig3-gke.csv` | Provisioning phase data used by Figure 3 (GKE values in `fig3-gke.csv`) |
| `analysis/cost_model_data.csv` | Monthly configuration-specific fee vs. cluster size (list prices) |
| `analysis/sensitivity_margin_data.csv` | Recommendation margins under weight perturbations (`CS1..CS5` = paper Cases 1–5) |
| `analysis/llm_benchmark/scenarios_v2.json` | 50 benchmark scenarios with ground truth |
| `analysis/llm_benchmark/results_v2/` | Raw extraction runs, scores, generated explanations, faithfulness verification |
| `analysis/llm_benchmark/direct_decision/` | Direct LLM-decision comparison for Case 5 (scripts, raw runs, README) |

## Reproducing the paper's numbers and figures

The decision engine is deterministic and needs no LLM access; every score and
elimination in the paper reproduces from the operator input alone.

```bash
pip install -r prototype/requirements.txt matplotlib numpy
cd analysis
python3 regen_eval.py         # Case-study phi scores, eliminations (Tables 8-9, Appendix D)
python3 dataplane_fig.py      # Figure 2
python3 provisioning_fig.py   # Figure 3
python3 convergence_fig.py    # Figure 4
python3 cost_model.py         # Figure 5
python3 sensitivity_fig.py    # Figure 7 (runs the engine per perturbation)
python3 llm_eval_fig.py       # Figure 8 (from stored benchmark results)
```

Re-running the LLM benchmark itself (`analysis/llm_benchmark/run_benchmark_v2.py`,
then `score_benchmark_v2.py`) requires API access; see below.

## Running the prototype

```bash
cd prototype
pip install -r requirements.txt
cp .env.example .env          # optional: fill in for free-form input + explanations
cd backend && uvicorn app:app --port 8000
```

Open `http://localhost:8000`. The structured form works fully offline;
the free-form request and the generated explanation call an OpenAI-compatible
LLM endpoint configured through `prototype/.env` (`LLM_BASE_URL`,
`GATEWAY_API_KEY`, `LLM_MODEL`).

## License

Code is released under the MIT License (see `LICENSE`).
The measurement data (`analysis/*.csv`, `analysis/llm_benchmark/`) may be reused
under CC BY 4.0 with citation of the paper.
