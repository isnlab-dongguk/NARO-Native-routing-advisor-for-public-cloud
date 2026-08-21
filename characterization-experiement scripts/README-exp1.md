# Experiment 1 — provisioning time

Measures T0→T4 per method at 4 and 8 nodes. T5 is retained as a required
post-measurement connectivity validation point, but no T4→T5 duration is recorded.

| Boundary | Meaning |
| --- | --- |
| T0 | `terraform apply` started |
| T1 | VM creation finished |
| T2 | all nodes registered and Ready |
| T3 | Cilium ready |
| T4 | method-specific VPC task finished (no-op for VXLAN, Host and GKE) |
| T5 | cross-node connectivity verified (validation only, outside the metric) |

Prerequisites: [README.md](README.md), a `terraform.tfvars` in
`infra/<method>/`, and the Docker daemon running.

## Run

### 1. Confirm the VPC MTU is 1500

```bash
gcloud compute networks describe <NETWORK_NAME> --project <GCP_PROJECT_ID> --format="value(mtu)"
```

```bash
gcloud compute networks update <NETWORK_NAME> --mtu 1500 --project <GCP_PROJECT_ID>
```

Restart running VMs after changing it. `expected_network_mtu = null` in tfvars
skips the check.

### 2. Build the 4-node cluster

| Method | Command |
| --- | --- |
| VXLAN | `.\provision.ps1 -Mode vxlan -NodeCount 4` |
| HOST | `.\provision.ps1 -Mode host -NodeCount 4` |
| STATIC | `.\provision.ps1 -Mode static -NodeCount 4` |
| DYNAMIC | `.\provision.ps1 -Mode dynamic -NodeCount 4` |
| GKE | `.\provision-gke.ps1 -NodeCount 4` |

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\provision.ps1 -Mode vxlan -NodeCount 4
```

Starts from an empty Terraform state. `-SkipApply` runs the preflights, plan and
plan guard without creating anything.

### 3. Run experiments 2 and 3

[README-exp2.md](README-exp2.md) and [README-exp3.md](README-exp3.md), before
expanding.

### 4. Expand to 8 nodes

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\provision.ps1 -Mode vxlan -NodeCount 8
```

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\provision-gke.ps1 -NodeCount 8
```

Continues from the 4-node state (GKE: 2 workers) and adds workers to it.

### 5. Run experiments 2 and 3 again

### 6. Fetch the experiment 2 results

[README-exp2.md](README-exp2.md), before tearing the cluster down.

### 7. Destroy

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\destroy.ps1 -Mode vxlan
```

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\destroy-gke.ps1
```

Deletes without confirmation, then verifies against GCP that the state, VMs,
disks, firewall rules, placement policy and method-specific T4 resources are all
gone.

## GKE

Build the tool image once before provisioning — `provision-gke.ps1` loads it with
`docker save`.

```bash
docker build --platform linux/amd64 --provenance=false --sbom=false --output type=docker -t localhost/exp2-tools:iperf3-3.21 .\exp2\image
```

`-NodeCount 4` is 1 managed control plane + 1 benchmark + 2 workers, i.e. 3 real
nodes labelled as 4. Results carry the method label `GKE`.

## Parameters

| Parameter | Applies to | Default | Purpose |
| --- | --- | --- | --- |
| `-Mode` | `provision.ps1`, `destroy.ps1` | required | `vxlan` \| `host` \| `static` \| `dynamic` |
| `-NodeCount` | both provisioners | `4` | `4` builds, `8` expands |
| `-SkipApply` | both provisioners | off | plan only |
| `-SkipQuotaPreflight` | both provisioners | off | skip quota checks |
| `-CiliumVersion`, `-KubernetesVersion` | `provision.ps1` | from Terraform | version override |
| `-ExperimentLabel` | both provisioners | `exp1` | CSV filename token |
| `-AllowRackSpread` | `provision-gke.ps1` | off | record a rack-spread deviation instead of failing |
| `-TfDir`, `-VarFile`, `-OutDir` | all | `infra/<method>`, `results/<method>/…` | path overrides |

## Output

`results/<method>/provisioning-<n>node/`

| File | Contents |
| --- | --- |
| `<method>_<nodes>_exp1_iter<n>.csv` | 6 POINT rows (T0–T5) and 6 DURATION rows (`script_total`, T0→T1…T3→T4, T0→T4) |
| `provisioning-summary.json` | the same data with status and failure details |
| `command-timings.{json,csv}` | per-command process boundaries |
| `control-vars-<method>_<nodes>_iter<n>.csv` | machine type, CPU platform, rack, image, MTU |
| `quota-check.csv`, `native-routing-quota-check.csv` | preflight results |
| `inventory.json`, `*.log` | node inventory and per-step logs |
| `failure-report.json` | written on failure |

The iteration number is the highest existing one plus 1, and a `.inprogress`
claim file marks the run in progress.

## Failure handling

A run that fails after `apply` destroys its resources automatically and keeps the
partial timeline plus a `FAILURE` row in the iteration CSV. A run that fails
before T0 leaves the iteration number unused. Ctrl+C hands the destroy to a
separate window.
