# Experiment 3 — route convergence time

Withdraws the PodCIDR advertisement of the benchmark node and worker-0, waits for
packet loss, re-advertises, and measures until traffic recovers. Every other node
is left untouched.

| Boundary | Meaning | Clock |
| --- | --- | --- |
| T0 | last essential command of the re-advertisement fired | control plane VM (GKE: ops VM) |
| T1 | last gcloud command finished | same |
| T2 | first successful TCP probe after T0 | benchmark pod |

Convergence time is T2 − T0.

Applies to N-Static, N-Dynamic and GKE. VXLAN and Host have no VPC advertisement
to withdraw.

| Method | Withdraw | Re-advertise |
| --- | --- | --- |
| N-Static | delete the 2 PodCIDR static routes | `routes create` ×2, concurrent |
| N-Dynamic | remove the 4 BGP peers, drop both VMs from the NCC spoke | restore the spoke, then `add-bgp-peer` ×4, sequential |
| GKE | clear the nic0 Alias IP on both VMs | `network-interfaces update --aliases` ×2, concurrent |

## Prerequisites

1. Experiment 1 finished, with the T4 marker present at
   `infra/<method>/.native-routing-t4-<method>.json`. GKE has no T4 task and
   discovers its nodes through the ops VM instead.

2. Experiment 2 pods created with a normal profile. hostNetwork pods have no
   PodCIDR path to converge and are rejected.

   ```bash
   bash /opt/experiment/scripts/exp2/exp2_create_normal_min.sh -m Static
   bash /opt/experiment/scripts/exp2_create_normal_min.sh -m Cloud     # GKE
   ```

3. `service_account_email` set in `terraform.tfvars` before the cluster was
   provisioned, so the VM can run the timed gcloud commands itself.

   ```hcl
   service_account_email = "<PROJECT_NUMBER>-compute@developer.gserviceaccount.com"
   ```

4. A project IAM role on that service account, granted once.

   ```bash
   gcloud projects add-iam-policy-binding <GCP_PROJECT_ID> --member="serviceAccount:<PROJECT_NUMBER>-compute@developer.gserviceaccount.com" --role="roles/editor"
   ```

   Least-privilege alternative: `roles/compute.networkAdmin`,
   `roles/compute.instanceAdmin.v1` and `roles/networkconnectivity.hubAdmin`.
   GKE also needs `roles/container.developer` for the ops VM kubectl.

5. gcloud on the VM. Ubuntu GCE images ship it as a snap; if the preflight
   reports it missing, `sudo snap install google-cloud-cli --classic`.

## Run

### 1. Check the restore path

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\exp3\exp3-static.ps1 -RestoreOnly
```

Builds the context and restores the advertisement idempotently, without
measuring. Useful as the first command on a new cluster.

### 2. Measure

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\exp3\exp3-static.ps1
```

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\exp3\exp3-dynamic.ps1
```

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\gke\exp3\exp3-cloud-gke.ps1
```

3 repetitions by default. Each one runs withdraw → confirm packet loss → T0
re-advertise → T2 first successful probe → restore check, and leaves the
advertisement as it found it.

### 3. Repeat at 8 nodes

After `provision.ps1 -Mode <method> -NodeCount 8`.

### 4. Restore after an interrupted run

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File .\exp3\exp3-dynamic.ps1 -RestoreOnly
```

The script already attempts this on its way out.

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Repetitions` | `3` | measured repetitions |
| `-RestoreOnly` | off | restore the advertisement and exit |
| `-Namespace` | `exp2-bench` | namespace created by experiment 2 |
| `-ProbePort` | `10002` | must not collide with 10000/10001 |
| `-ProbeIntervalSeconds` | `0.02` | probe interval, and the T2 resolution |
| `-ProbeTimeoutSeconds` | `0.5` | per-probe connect timeout |
| `-LossConfirmProbes`, `-LossConfirmSeconds` | `10`, `5` | consecutive FAIL that confirms the withdrawal |
| `-StableOkProbes` | `5` | consecutive OK after the first OK |
| `-LossTimeoutSeconds` | `300`; dynamic `900`, GKE `600` | wait for packet loss |
| `-ConvergenceTimeoutSeconds` | `300`; dynamic `1200`, GKE `900` | wait for the first OK |
| `-SessionWaitSeconds` | `600` | N-Dynamic only: wait for BGP Established |
| `-TfDir`, `-VarFile`, `-OutDir` | `infra/<method>`, `results/exp3` | path overrides |

## Output

`results/exp3/`

| File | Contents |
| --- | --- |
| `{method}_{nodes}_exp3_iter{n}.csv` | a `MEASUREMENT` row per repetition with T0/T1/T2, `t0_to_t1_ms`, `t1_to_t2_ms`, `t0_to_t2_ms` and the clock offsets; an `AVERAGE` row; a `FAILURE` row on failure |
| `raw/<iteration>/` | probe log, per-command gcloud logs, clock offset samples, timing JSON, `summary.json` |

`t0_to_t2_ms` is the convergence time. Reporting `t0_to_t1_ms` and
`t1_to_t2_ms` alongside it separates the task time from the convergence itself.

## Notes

- The N-Dynamic withdraw is an NCC spoke update and can take minutes. It is not
  part of the measurement.
- The T4 marker is read, never modified, so this does not interfere with
  `destroy.ps1`.
