# Experiment 2 — throughput, CPU and latency

TCP/UDP throughput, node-wide CPU and TCP_RR latency between a Benchmark pod and
a Server pod, per method × node count × pod density.

| Condition | Value |
| --- | --- |
| iperf3 TCP/UDP | port 10000, `-P 4 -O 10 -t 60` |
| netserver | port 10001 |
| TCP_RR | 1/1 B and 1024/1024 B, 10s warm-up + 50s measured |
| CPU | `mpstat -P ALL 1 60` inside both pods, node-wide |
| Runs | 3 by default (`-r` accepts any positive integer), plus a SUMMARY average row |
| Placement | Benchmark pod on `*-bench-0`, Server pod on `*-worker-0` |

Prerequisite: experiment 1 finished for this method and node count. Its post-T5
phase installs these scripts and the tool image on the control plane (GKE: the
ops VM) and taints the benchmark node.

## Run

### 1. Connect to the control plane

```bash
gcloud compute instances describe <method>-cp-0 --zone <ZONE> --project <GCP_PROJECT_ID> --format="value(networkInterfaces[0].accessConfigs[0].natIP)"
```

GKE uses the ops VM `cloud-ops-0`.

```bash
ssh -i $HOME/.ssh/experiment_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL <SSH_USER>@<IP>
```

`/etc/profile.d` puts `/opt/experiment/scripts` on `PATH`. A session opened
before provisioning picks it up with
`source /etc/profile.d/experiment-scripts.sh`.

### 2. Create the pods

| Profile | Script | hostNetwork | Dummy pods per worker |
| --- | --- | --- | ---: |
| normal, minimum | `exp2_create_normal_min.sh -m <METHOD>` | false | 1 |
| normal, medium | `exp2_create_normal_medium.sh -m <METHOD>` | false | 50 |
| hostNetwork, minimum | `exp2_create_hostnetwork_min.sh` | true | 1 |
| hostNetwork, medium | `exp2_create_hostnetwork_medium.sh` | true | 50 |

```bash
# VXLAN / STATIC / DYNAMIC
bash /opt/experiment/scripts/exp2/exp2_create_normal_min.sh -m VXLAN

# HOST, where the method is fixed
bash /opt/experiment/scripts/exp2/exp2_create_hostnetwork_min.sh

# GKE, flat path on the ops VM
bash /opt/experiment/scripts/exp2_create_normal_min.sh -m Cloud
```

`-m` is compared with the node name prefix (`vxlan-*`, `static-*`, `dynamic-*`,
`gke-cloud-*`), so results cannot be recorded under the wrong method.

```bash
kubectl get pods -n exp2-bench -o custom-columns=NODE:.spec.nodeName --no-headers | sort | uniq -c | sort -nr
```

### 3. Benchmark

Same profile and method as the create step; about 15 minutes with the default 3 runs.

```bash
bash /opt/experiment/scripts/exp2/exp2_run_normal_min.sh -m VXLAN
bash /opt/experiment/scripts/exp2/exp2_run_hostnetwork_min.sh
bash /opt/experiment/scripts/exp2_run_normal_min.sh -m Cloud
```

The benchmark verifies the existing deployment and measures; it never creates or
deletes a pod.

### 4. Repeat for the other density

`exp2_create_*_medium.sh` then `exp2_run_*_medium.sh`.

### 5. Keep the pods for experiment 3

### 6. Fetch the results

From local PowerShell:

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\exp2\fetch_exp2_results.ps1 -TfvarsPath .\infra\vxlan\terraform.tfvars
```

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\gke\exp2\fetch_exp2_results_gke.ps1 -TfvarsPath .\infra\gke\terraform.tfvars
```

Project, zone, target VM, SSH user and key, and the remote path all come from the
tfvars. Each fetch creates a new snapshot directory. `-ControlPlane`, `-Zone`,
`-Project`, `-SshUser`, `-SshKeyFile`, `-RemoteResultsDir` and `-LocalRoot`
override the derived values; `-TunnelThroughIap` covers a VM without an external
IPv4.

### 7. Clean up, after experiment 3

```bash
bash /opt/experiment/scripts/exp2/exp2_cleanup.sh
bash /opt/experiment/scripts/exp2_cleanup.sh          # GKE
```

Deletes the namespace only when it starts with `exp2-` and carries
`managed-by=exp2-benchmark`. Result files and the node label and taint stay.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `-m`, `--method` | — | `VXLAN` \| `Host` \| `Static` \| `Dynamic` (GKE: `Cloud`) |
| `-n`, `--namespace` | `exp2-bench` | must start with `exp2-` |
| `-i`, `--iteration` | `auto` | iteration number |
| `-o`, `--outdir` | `/var/lib/experiment/results/exp2` | result directory |
| `-r`, `--runs` | `3` | positive-integer repeat count |

Density, and the method for the hostNetwork profiles, are fixed by the script
name.

Environment variables, all optional: `KUBECONFIG`, `NS`, `RESULTS_DIR`,
`EXPERIMENT_RESULTS_ROOT`, `TOOL_IMAGE`, `ALPINE_IMAGE`, `WAIT_TIMEOUT`,
`PAUSE_BETWEEN_TESTS`, `PAUSE_BETWEEN_RUNS`.

## Output

On the control plane, `/var/lib/experiment/results/exp2`:

| File | Contents |
| --- | --- |
| `<method>_<total>n_<workers>w_p<density>_exp2_iter<n>.csv` | one row per requested run and a SUMMARY row |
| `…_tcp.csv`, `…_udp.csv`, `…_tcp_rr_1b.csv`, `…_tcp_rr_1024b.csv` | one file per metric group |
| `raw/<tag>/` | iperf3 JSON, netperf CSV, mpstat, per-run server UID/IP, stderr, deployment snapshots |
| `…_FAILED.csv`, `runN_failure.txt` | written on failure, without an average row |

Columns: `tcp_gbps`, `tcp_retrans`, `tcp_{cli,srv}_{usr,sys,iowait,soft}`,
`udp_gbps`, `udp_jitter_ms`, `udp_lost`, `udp_total`, `udp_lost_pct`,
`udp_{cli,srv}_{usr,sys,iowait,soft}`, `netperf_{1b,1024b}_tps`,
`rtt_{1b,1024b}_{mean,p50,p99}_us`. Latencies are microseconds.

Locally, `results/exp2-from-cp/` and `results/gke/exp2-from-ops/`.

## Notes

- One benchmark runs per cluster at a time, held by the `exp2-benchmark-lock`
  ConfigMap in `default`.
- Any workload other than the experiment pods on the benchmark node or a worker
  stops the run. Platform namespaces are allowed: `kube-system`, plus
  `gmp-system` and `gke-managed-*` on GKE.
