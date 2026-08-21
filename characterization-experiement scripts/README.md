# Routing method benchmark

Compares five Kubernetes pod-routing methods on GCP across three experiments.

| Method | Token | Terraform root |
| --- | --- | --- |
| VXLAN (Cilium tunnel) | `vxlan` | `infra/vxlan` |
| Host network | `host` | `infra/host` |
| N-Static (static VPC routes) | `static` | `infra/static` |
| N-Dynamic (Cloud Router BGP) | `dynamic` | `infra/dynamic` |
| GKE Standard (N-Cloud) | `cloud` | `infra/gke` |

| Experiment | Measures | Guide |
| --- | --- | --- |
| 1 | Provisioning time (T0–T4; T5 validation) | [README-exp1.md](README-exp1.md) |
| 2 | TCP/UDP throughput, CPU, TCP_RR latency | [README-exp2.md](README-exp2.md) |
| 3 | Route convergence time | [README-exp3.md](README-exp3.md) |

Run them in order — exp1 → exp2 → exp3 — at 4 nodes, then expand to 8 nodes and
repeat.

## Requirements

| Tool | Note |
| --- | --- |
| Windows PowerShell 5.1 | |
| Terraform | |
| Google Cloud CLI | |
| Windows OpenSSH (`ssh`, `scp`, `ssh-keygen`) | PuTTY is not supported |
| Docker Desktop | the daemon must be running; provisioning builds the experiment 2 tool image |
| Git Bash | optional, for `bash -n` in the smoke test |

## Setup

Authenticate. `gcloud auth login` covers the scripts, `application-default`
covers Terraform.

```bash
gcloud auth login
gcloud auth application-default login
```

Create a passphrase-less OpenSSH key.

```bash
ssh-keygen -t ed25519 -N '""' -f $HOME\.ssh\experiment_ed25519
```

Confirm the Docker daemon answers.

```bash
docker info --format "{{.ServerVersion}}"
```

Create a `terraform.tfvars` for each method.

```bash
copy infra\vxlan\terraform.tfvars.example infra\vxlan\terraform.tfvars
```

Repeat for `host`, `static`, `dynamic` and `gke`.

| Key | Value |
| --- | --- |
| `project_id` | GCP project |
| `network_name`, `subnetwork_name` | existing VPC and subnet, MTU 1500 |
| `experiment_name` | the method token (`cloud` for GKE) |
| `ssh_user` | Linux account name, lowercase first character |
| `ssh_public_key_path` | absolute path to the `.pub` created above |
| `service_account_email` | used by experiment 3 |

Optional keys are documented in each `terraform.tfvars.example`.

## Layout

```
.
├── provision.ps1                 exp1: vxlan / host / static / dynamic
├── provision-gke.ps1             exp1: GKE
├── destroy.ps1, destroy-gke.ps1  teardown and leftover verification
├── check-*.ps1                   quota, plan guard, control variables
├── infra/<method>/               Terraform root and state per method
├── exp2_benchmark.sh, exp2/      exp2 engine, wrappers, result fetch, tool image
├── exp3/                         exp3 for N-Static and N-Dynamic
├── gke/                          GKE build of exp2 and exp3
└── results/                      all output
```

Every path resolves against this directory, so the folder can be copied
anywhere. The SSH key, `terraform.tfvars`, the CLI tools and GCP are the only
things that come from outside.

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\test-new-scripts.ps1
```
