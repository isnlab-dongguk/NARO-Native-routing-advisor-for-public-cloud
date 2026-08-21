# NARO: NAtive ROuting Advisor for Public-Cloud Kubernetes

Artifact for the paper **"NaRo: An LLM-Assisted Framework for
Characterization-Grounded Native Routing Selection in Public-Cloud
Kubernetes"** (under submission).

Pod CIDRs that are not drawn from the cloud provider's subnet address space are
invisible to the provider-managed forwarding plane, so a Kubernetes cluster must
either encapsulate pod traffic or register its pod routes with the cloud. NARO
turns that choice into an explicit procedure: it removes configurations that
violate the operator's mandatory constraints, ranks the rest with TOPSIS over a
decision matrix filled from measurements, and uses an LLM only as a
natural-language interface, never as the decision maker.

The repository holds the two halves of the artifact: the prototype that
implements the framework, and the scripts that produced the measurements behind
its decision matrix.

## Repository layout

```
prototype/                            Web prototype (FastAPI + single-page frontend)
  backend/                            Decision engine and LLM interface
  static/                             Browser UI
characterization-experiement scripts/ Measurement harness for the five configurations
  infra/<method>/                     Terraform root, one per configuration
  exp2/, exp3/                        Experiment engines and wrappers
  gke/                                GKE variants of experiments 2 and 3
```

## Configurations

The same five configurations appear throughout the paper, the prototype, and the
measurement scripts.

| Configuration | Routing mechanism | Script token |
|---|---|---|
| B-Host | Host network, no pod overlay | `host` |
| B-VXLAN | Cilium VXLAN overlay | `vxlan` |
| N-Static | Static VPC routes | `static` |
| N-Dynamic | BGP through a cloud-managed router | `dynamic` |
| N-Cloud | Provider-managed native routing (GKE alias IP) | `cloud` |

## Prototype

```bash
cd prototype
cp .env.example .env      # optional; see below
./run.sh
```

Open `http://localhost:8000`. `run.sh` loads `.env`, installs the dependencies in
`requirements.txt` if they are missing, and starts uvicorn. `HOST` and `PORT`
override the defaults.

The structured form runs fully offline and needs no API key. Free-form input and
the generated explanation call an OpenAI-compatible endpoint configured through
`.env` (`GATEWAY_API_KEY`, `LLM_BASE_URL`, `LLM_MODEL`); without a key the server
still starts and `GET /api/health` reports `llm_enabled: false`.

| Endpoint | Purpose |
|---|---|
| `POST /api/v2/recommend` | Recommendation from a filled form, free-form text, or both |
| `GET /api/configs` | The candidate configurations and their descriptions |
| `GET /api/health` | Liveness and whether LLM access is configured |

Inside `backend/`, `pipeline_v2.py` is the decision path described in the paper:
it merges the form with any extracted fields, applies the feasibility rules,
drops criteria that no longer separate the survivors, renormalizes the weights,
and ranks with TOPSIS. `config.py` holds the decision matrix, the criterion
definitions, and the three weight presets (cost-first, balanced,
performance-first). `extract_v2.py` and `explain_v2.py` hold the two LLM prompts,
and `llm.py` the client. Requirement extraction is constrained by function
calling, so the model can only fill declared fields with declared values.

## Characterization experiments

`characterization-experiement scripts/` provisions each configuration on Google
Cloud and measures it. Three experiments run in order, at 4 nodes and again at 8.

| Experiment | Measures | Guide |
|---|---|---|
| 1 | Provisioning wall-clock time, per phase | `README-exp1.md` |
| 2 | TCP/UDP throughput, CPU shares, TCP_RR latency | `README-exp2.md` |
| 3 | Route convergence time | `README-exp3.md` |

Provisioning and teardown are driven from PowerShell (`provision.ps1`,
`provision-gke.ps1`, `destroy.ps1`, `destroy-gke.ps1`), the in-cluster benchmarks
from bash. The `check-*.ps1` scripts verify quota, guard the Terraform plan, and
record control variables so repetitions stay comparable. `test-new-scripts.ps1`
is a smoke test that touches no cloud resources.

Running them needs Windows PowerShell 5.1, Terraform, the Google Cloud CLI,
Windows OpenSSH, and a running Docker daemon for the experiment 2 tool image,
plus a `terraform.tfvars` per configuration copied from the `.example` beside it.
`characterization-experiement scripts/README.md` documents the setup in full.

Measurement output is written to `results/` and is not tracked here: it carries
project identifiers, node names, and Terraform plans specific to the account that
produced it. The paper reports the values derived from those runs.

## License

Code is released under the MIT License (see `LICENSE`). Measurement data derived
from these scripts may be reused under CC BY 4.0 with citation of the paper.
