#!/usr/bin/env bash
#===============================================================================
# exp2_benchmark.sh
# Experiment 2 - TCP/UDP/CPU/TCP_RR per routing method x node count x pod density
#
# Canonical engine. The create and benchmark wrappers under exp2/ each call one
# stage only, so pod lifetime and measurement stay separate.
#
# Fixed measurement conditions
#   - iperf3 server : TCP/UDP 10000
#   - netserver     : TCP control 10001
#   - placement     : Benchmark Pod=*-bench-0, Server Pod=*-worker-0
#   - TCP/UDP       : -P 4 -O 10 -t 60
#                     (10s pre-test, then 60s measured; about 70s total)
#   - CPU           : raw node-wide mpstat -P ALL 1 60 from both pods
#   - TCP_RR        : payload 1/1 byte and 1024/1024 byte, each measured for
#                     50s after a 10s warm-up
#   - repeats       : 3 by default; -r accepts any positive integer
#                     (a missing required metric fails the iteration)
#
# Where to run
#   Any Bash 4+ environment (Linux / Git Bash) whose kubectl points at the target
#   cluster. With the Terraform provisioning flow the simplest choice is the
#   control plane VM itself, using its ~/.kube/config.
#
# Examples
#   ./scripts/exp2_benchmark.sh create -m VXLAN -d 1
#   ./scripts/exp2_benchmark.sh benchmark -m VXLAN -d 1
#   ./scripts/exp2_benchmark.sh verify -m VXLAN
#   ./scripts/exp2_benchmark.sh cleanup
#===============================================================================
set -Eeuo pipefail
umask 022

# Stop Git Bash from rewriting arguments such as /tmp into Windows paths.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Only used for the local default result root; on the control plane the shared
# /var/lib/experiment/results wins below.
ROOT_DIR="$SCRIPT_DIR"

# Fixed ports. Not overridable by environment, so iterations cannot drift.
readonly IPERF_PORT=10000
readonly NETPERF_PORT=10001

METHOD_PROVIDED=false
[[ -z "${METHOD:-}" ]] || METHOD_PROVIDED=true
METHOD="${METHOD:-VXLAN}"
MODE=""
DENSITY="${DENSITY:-1}"
RUNS="${RUNS:-3}"
ITERATION="${ITERATION:-auto}"
NS="${NS:-exp2-bench}"
if [[ -n "${EXPERIMENT_RESULTS_ROOT:-}" ]]; then
  DEFAULT_RESULTS_ROOT="$EXPERIMENT_RESULTS_ROOT"
elif [[ "$SCRIPT_DIR" == "/opt/experiment/scripts" ]]; then
  DEFAULT_RESULTS_ROOT="/var/lib/experiment/results"
else
  DEFAULT_RESULTS_ROOT="${ROOT_DIR}/results"
fi
RESULTS_DIR="${RESULTS_DIR:-${DEFAULT_RESULTS_ROOT}/exp2}"
# The default tool image is the prebuilt image experiment 1 provisioning loaded
# into the containerd of the benchmark and worker-0 nodes (ubuntu:22.04 +
# iperf3 3.21 built from source, exp2/image/Dockerfile). The Jammy APT iperf3
# 3.9 runs -P single-threaded and has no UDP GSO, so one sending core caps the
# measurement, and its socket teardown race raises
# "control socket has closed unexpectedly" (exit 1).
TOOL_IMAGE="${TOOL_IMAGE:-localhost/exp2-tools:iperf3-3.21}"
ALPINE_IMAGE="${ALPINE_IMAGE:-alpine:3.20}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-900s}"
PAUSE_BETWEEN_TESTS="${PAUSE_BETWEEN_TESTS:-5}"
PAUSE_BETWEEN_RUNS="${PAUSE_BETWEEN_RUNS:-10}"

readonly IPERF_OMIT_SECONDS=10
readonly IPERF_MEASURE_SECONDS=60
readonly NETPERF_WARMUP_SECONDS=10
readonly NETPERF_MEASURE_SECONDS=50
readonly NETPERF_PAYLOAD_1B=1
readonly NETPERF_PAYLOAD_1024B=1024
readonly NETPERF_VERSION=2.7.0
# iperf3 comes from the prebuilt image (/usr/local/bin/iperf3 3.21), not APT.
readonly EXP2_IPERF3_VERSION="3.21"
readonly IPERF3_INSTALL_MODE=prebuilt-image
# Every tool is preinstalled in the image; pods never run APT at startup.
# This list must match TOOL_PACKAGES in exp2/image/Dockerfile, otherwise the
# dpkg-query check in the pod startup command fails immediately.
readonly TOOL_INSTALL_MODE=prebuilt-image
readonly TOOL_PACKAGES="ca-certificates netcat-openbsd netperf python3 socat sysstat"

readonly BENCH_POD=benchmark-pod
readonly SERVER_POD=server-pod
readonly CONFIG_MAP=exp2-config
# Retry cap for fetching a CPU sample. It only copies a file that already
# exists in the container - nothing is re-measured - so it stays short.
readonly CPU_SAMPLE_FETCH_ATTEMPTS=3
readonly CPU_SAMPLE_FETCH_DELAY=2
readonly CLUSTER_LOCK_NAMESPACE=default
readonly CLUSTER_LOCK_NAME=exp2-benchmark-lock

CMD=""
METHOD_SLUG=""
HOST_NETWORK="false"
DNS_POLICY="ClusterFirst"
BENCH_NODE=""
CONTROL_PLANE_NODE=""
CLUSTER_PREFIX=""
WORKERS=()
WORKER_COUNT=0
TOTAL_NODE_COUNT=0
SERVER_NODE=""
SERVER_IP=""
SERVER_POD_UID=""
PYTHON_BIN=""
TOOL_IMAGE_ID=""
ALPINE_IMAGE_ID=""

TAG=""
RAW_DIR=""
FINAL_CSV=""
FAILED_CSV=""
WORK_CSV=""
TCP_CSV=""
UDP_CSV=""
TCP_RR_1B_CSV=""
TCP_RR_1024B_CSV=""
TCP_WORK_CSV=""
UDP_WORK_CSV=""
TCP_RR_1B_WORK_CSV=""
TCP_RR_1024B_WORK_CSV=""
CLAIM_DIR=""
RESULT_ACTIVE=false
RESULT_COMPLETE=false
CPU_CLIENT_PID=""
CPU_SERVER_PID=""
CPU_SAMPLE_LABEL=""
CPU_CLIENT_FILE=""
CPU_SERVER_FILE=""
NETPERF_RESULT=""
CLUSTER_LOCK_TOKEN=""
CLUSTER_LOCK_HELD=false

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required."; }

cleanup_local_state() {
  local rc=$? current_lock_token="" split_file
  if [[ -n "${CPU_CLIENT_PID:-}" || -n "${CPU_SERVER_PID:-}" ]]; then
    kill ${CPU_CLIENT_PID:+"$CPU_CLIENT_PID"} ${CPU_SERVER_PID:+"$CPU_SERVER_PID"} 2>/dev/null || true
    [[ -z "${CPU_CLIENT_PID:-}" ]] || wait "$CPU_CLIENT_PID" 2>/dev/null || true
    [[ -z "${CPU_SERVER_PID:-}" ]] || wait "$CPU_SERVER_PID" 2>/dev/null || true
  fi
  if [[ "$RESULT_ACTIVE" == true && "$RESULT_COMPLETE" != true && -n "${WORK_CSV:-}" && -f "$WORK_CSV" ]]; then
    if [[ -n "${FAILED_CSV:-}" && ! -e "$FAILED_CSV" ]]; then
      mv -- "$WORK_CSV" "$FAILED_CSV" || true
      printf '[WARN] failed-iteration CSV kept: %s\n' "$FAILED_CSV" >&2
    fi
  fi
  if [[ "$RESULT_ACTIVE" == true && "$RESULT_COMPLETE" != true ]]; then
    for split_file in \
      "${TCP_WORK_CSV:-}" "${UDP_WORK_CSV:-}" "${TCP_RR_1B_WORK_CSV:-}" "${TCP_RR_1024B_WORK_CSV:-}" \
      "${TCP_CSV:-}" "${UDP_CSV:-}" "${TCP_RR_1B_CSV:-}" "${TCP_RR_1024B_CSV:-}"; do
      [[ -z "$split_file" ]] || rm -f -- "$split_file"
    done
  fi
  if [[ -n "${CLAIM_DIR:-}" && -d "$CLAIM_DIR" ]]; then
    rmdir -- "$CLAIM_DIR" 2>/dev/null || true
  fi
  if [[ "$CLUSTER_LOCK_HELD" == true ]]; then
    current_lock_token="$(kubectl -n "$CLUSTER_LOCK_NAMESPACE" get configmap "$CLUSTER_LOCK_NAME" \
      -o jsonpath='{.data.token}' 2>/dev/null || true)"
    if [[ "$current_lock_token" == "$CLUSTER_LOCK_TOKEN" ]]; then
      kubectl -n "$CLUSTER_LOCK_NAMESPACE" delete configmap "$CLUSTER_LOCK_NAME" \
        --ignore-not-found --wait=false >/dev/null 2>&1 || \
        printf '[WARN] could not release the cluster run lock: %s/%s\n' \
          "$CLUSTER_LOCK_NAMESPACE" "$CLUSTER_LOCK_NAME" >&2
    fi
  fi
  exit "$rc"
}

usage() {
  cat <<'USAGE'
Usage:
  exp2_benchmark.sh create    -m <method> -d <1|50> [options]
  exp2_benchmark.sh benchmark -m <method> -d <1|50> [options]
  exp2_benchmark.sh verify  -m <method> [-n namespace]
  exp2_benchmark.sh cleanup [-n namespace]

Subcommands:
  create    recreate the namespace, deploy and verify the workload, keep pods
  benchmark strictly compare the existing deployment, measure the requested runs, keep pods
  verify    check pod count, placement, hostNetwork and taint of the deployment
  cleanup   delete the namespace, only when explicitly requested

Options:
  -m, --method      VXLAN | Host | Static | Dynamic (same token as the node prefix)
  -d, --density     dummy pods per worker: 1 | 50
  -r, --runs        repeat count (positive integer, default 3)
  -i, --iteration   result iteration number, or auto (default auto)
  -n, --namespace   dedicated namespace (must start with exp2-, default exp2-bench)
  -o, --outdir      result directory (default /var/lib/experiment/results/exp2)
  -h, --help        this help

Topology:
  4 nodes = 1 control plane + 1 benchmark + 2 workers
  8 nodes = 1 control plane + 1 benchmark + 6 workers
  experiment-role=control-plane|benchmark|worker labels must be exact.
  Node names must follow the experiment 1 rule: *-bench-0, *-worker-0, ...
  The shared node prefix is compared with -m (vxlan/host/static/dynamic).
  Benchmark Pod runs on *-bench-0, Server Pod on *-worker-0.

Results:
  <method>_<total>n_<workers>w_p<density>_exp2_iter<iteration>.csv (combined)
  <same base>_{tcp,udp,tcp_rr_1b,tcp_rr_1024b}.csv (per metric group)
  raw/<same tag>/ holds iperf3 JSON, netperf, node-wide mpstat, per-run server
  UID/IP, stderr and deployment snapshots
  On failure the CSV is kept as *_FAILED.csv and no average row is written.
  create and benchmark never delete the namespace or the pods.
USAGE
}

require_value() {
  local option="$1" remaining="$2"
  (( remaining >= 2 )) || die "${option} requires a value."
}

parse_args() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi
  CMD="${1:-}"
  [[ $# -gt 0 ]] && shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--method)    require_value "$1" "$#"; METHOD="$2"; METHOD_PROVIDED=true; shift 2 ;;
      -d|--density)   require_value "$1" "$#"; DENSITY="$2"; shift 2 ;;
      -r|--runs)      require_value "$1" "$#"; RUNS="$2"; shift 2 ;;
      -i|--iteration) require_value "$1" "$#"; ITERATION="$2"; shift 2 ;;
      -n|--namespace) require_value "$1" "$#"; NS="$2"; shift 2 ;;
      -o|--outdir)    require_value "$1" "$#"; RESULTS_DIR="$2"; shift 2 ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "unknown option: $1" ;;
    esac
  done
}

normalize_and_validate() {
  (( BASH_VERSINFO[0] >= 4 )) \
    || die "Bash 4 or newer is required (current ${BASH_VERSION})."
  # The -m token is the node-name prefix of the experiment 1 Terraform root
  # (infra/<method>): vxlan/host/static/dynamic. N-Static and N-Dynamic are the
  # names used in the report, never on the CLI or in result filenames.
  case "${METHOD,,}" in
    vxlan)   METHOD="VXLAN" ;;
    host)    METHOD="Host" ;;
    static)  METHOD="Static" ;;
    dynamic) METHOD="Dynamic" ;;
    *) die "method must be one of VXLAN|Host|Static|Dynamic: $METHOD" ;;
  esac
  METHOD_SLUG="${METHOD,,}"

  if [[ "$METHOD" == "Host" ]]; then
    MODE="host"
    HOST_NETWORK="true"
    # Host has no cross-node PodCIDR path, so a hostNetwork pod using
    # ClusterFirstWithHostNet cannot reach CoreDNS (another node's PodCIDR).
    # Default inherits the node resolv.conf and uses the GCP internal DNS.
    # Measurement talks to pod IPs only, so cluster DNS is not needed.
    DNS_POLICY="Default"
  else
    MODE="normal"
    HOST_NETWORK="false"
    DNS_POLICY="ClusterFirst"
  fi

  [[ "$DENSITY" == "1" || "$DENSITY" == "50" ]] \
    || die "density must be 1 or 50: $DENSITY"
  [[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || die "runs must be a positive integer: $RUNS"
  [[ "$ITERATION" == "auto" || "$ITERATION" =~ ^[1-9][0-9]*$ ]] \
    || die "iteration must be auto or a positive integer: $ITERATION"
  validate_experiment_namespace
  [[ "$PAUSE_BETWEEN_TESTS" =~ ^[0-9]+$ ]] \
    || die "PAUSE_BETWEEN_TESTS must be a non-negative integer."
  [[ "$PAUSE_BETWEEN_RUNS" =~ ^[0-9]+$ ]] \
    || die "PAUSE_BETWEEN_RUNS must be a non-negative integer."
}

validate_experiment_namespace() {
  case "$NS" in
    default|kube-system|kube-public|kube-node-lease)
      die "reserved Kubernetes namespaces cannot be used: $NS"
      ;;
  esac
  (( ${#NS} <= 63 )) \
    || die "namespace name must be 63 characters or fewer: $NS"
  [[ "$NS" =~ ^exp2-[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
    || die "for safety the experiment namespace must be a DNS name starting with exp2-: $NS"
}

detect_python() {
  local candidate
  for candidate in python3 python; do
    if command -v "$candidate" >/dev/null 2>&1 \
       && "$candidate" -c 'import json,sys' >/dev/null 2>&1; then
      PYTHON_BIN="$candidate"
      return 0
    fi
  done
  die "Python 3 is required to parse the iperf3 JSON."
}

preflight() {
  need kubectl
  need awk
  need grep
  need sed
  need sort
  need mktemp
  need seq
  need tr
  need uniq
  need basename
  kubectl cluster-info >/dev/null 2>&1 \
    || die "kubectl is not connected to a cluster (check KUBECONFIG)."
  kubectl -n kube-system get daemonset cilium >/dev/null 2>&1 \
    || die "kube-system/cilium DaemonSet not found."
}

acquire_cluster_lock() {
  local holder
  CLUSTER_LOCK_TOKEN="${HOSTNAME:-unknown}-$$-$(date -u '+%Y%m%dT%H%M%SZ')"
  if kubectl -n "$CLUSTER_LOCK_NAMESPACE" create configmap "$CLUSTER_LOCK_NAME" \
      --from-literal="token=${CLUSTER_LOCK_TOKEN}" \
      --from-literal="experimentNamespace=${NS}" \
      --from-literal="startedAt=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >/dev/null 2>&1; then
    CLUSTER_LOCK_HELD=true
    return 0
  fi
  holder="$(kubectl -n "$CLUSTER_LOCK_NAMESPACE" get configmap "$CLUSTER_LOCK_NAME" \
    -o jsonpath='{.data.token}{"|"}{.data.experimentNamespace}{"|"}{.data.startedAt}' \
    2>/dev/null || true)"
  die "another experiment 2 job is using the cluster (lock=${CLUSTER_LOCK_NAMESPACE}/${CLUSTER_LOCK_NAME}, holder=${holder:-unknown}). If nothing is running, inspect the stale lock and delete it manually."
}

array_contains() {
  local target="$1" item
  shift
  for item in "$@"; do
    [[ "$item" == "$target" ]] && return 0
  done
  return 1
}

discover_nodes() {
  local output duplicates not_ready expected_workers method_prefix_matches=false
  local node
  local -a bench_nodes=() cp_nodes=() all_nodes=() worker_zero_nodes=()

  output="$(kubectl get nodes -l experiment-role=benchmark \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" \
    || die "failed to list benchmark nodes"
  mapfile -t bench_nodes < <(printf '%s\n' "$output" | sed '/^$/d' | sort)
  (( ${#bench_nodes[@]} == 1 )) \
    || die "exactly one experiment-role=benchmark node is required (found ${#bench_nodes[@]})."
  BENCH_NODE="${bench_nodes[0]}"
  [[ "$BENCH_NODE" =~ (^|-)bench-0$ ]] \
    || die "benchmark node name does not follow the experiment 1 rule (*-bench-0): $BENCH_NODE"
  CLUSTER_PREFIX="${BENCH_NODE%-bench-0}"
  [[ -n "$CLUSTER_PREFIX" && "${CLUSTER_PREFIX}-bench-0" == "$BENCH_NODE" ]] \
    || die "could not derive the cluster prefix from the benchmark node: $BENCH_NODE"

  output="$(kubectl get nodes -l experiment-role=control-plane \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" \
    || die "failed to list control plane nodes"
  mapfile -t cp_nodes < <(printf '%s\n' "$output" | sed '/^$/d' | sort)
  (( ${#cp_nodes[@]} == 1 )) \
    || die "exactly one experiment-role=control-plane node is required (found ${#cp_nodes[@]})."
  CONTROL_PLANE_NODE="${cp_nodes[0]}"
  [[ "$CONTROL_PLANE_NODE" == "${CLUSTER_PREFIX}-cp-0" ]] \
    || die "control plane and benchmark nodes have different cluster prefixes: ${CONTROL_PLANE_NODE}, ${BENCH_NODE}"

  output="$(kubectl get nodes -l experiment-role=worker \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" \
    || die "failed to list worker nodes"
  mapfile -t WORKERS < <(printf '%s\n' "$output" | sed '/^$/d' | sort)
  WORKER_COUNT=${#WORKERS[@]}

  output="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" \
    || die "failed to list all nodes"
  mapfile -t all_nodes < <(printf '%s\n' "$output" | sed '/^$/d' | sort)
  TOTAL_NODE_COUNT=${#all_nodes[@]}

  [[ "$TOTAL_NODE_COUNT" == "4" || "$TOTAL_NODE_COUNT" == "8" ]] \
    || die "experiment 2 requires a 4-node or 8-node cluster (found ${TOTAL_NODE_COUNT})."
  if [[ "$TOTAL_NODE_COUNT" == "4" ]]; then expected_workers=2; else expected_workers=6; fi
  (( WORKER_COUNT == expected_workers )) \
    || die "a ${TOTAL_NODE_COUNT}-node topology needs ${expected_workers} workers (found ${WORKER_COUNT})."

  # The experiment 1 Terraform root (infra/<method>) names nodes
  # <method>-<role>-<n>, so the -m token is compared with the node prefix
  # directly: accepting any -m value would silently corrupt the independent
  # variable in the results. A suffixed prefix override (vxlan-a) is allowed.
  [[ "$CLUSTER_PREFIX" == "$METHOD_SLUG" || "$CLUSTER_PREFIX" == "${METHOD_SLUG}-"* ]] \
    && method_prefix_matches=true
  [[ "$method_prefix_matches" == true ]] \
    || die "requested method=${METHOD} does not match the cluster prefix=${CLUSTER_PREFIX}. Stopping so results are not recorded under the wrong method."

  duplicates="$(printf '%s\n' "$BENCH_NODE" "$CONTROL_PLANE_NODE" "${WORKERS[@]}" | sort | uniq -d)"
  [[ -z "$duplicates" ]] || die "duplicate node role labels: $duplicates"
  (( TOTAL_NODE_COUNT == WORKER_COUNT + 2 )) \
    || die "some nodes have no role label (total=${TOTAL_NODE_COUNT}, roles=$((WORKER_COUNT + 2)))."

  not_ready="$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}' \
    | awk -F'|' '$2 != "True" { print $1 }')"
  [[ -z "$not_ready" ]] || die "some nodes are not Ready: $(printf '%s' "$not_ready" | tr '\n' ' ')"

  # Experiment 1 Terraform creates Kubernetes nodes as <prefix>-worker-0. The
  # labels carry no role index, so the role label and the name rule are used
  # together instead of relying on a plain sort index.
  for node in "${WORKERS[@]}"; do
    [[ "$node" == "${CLUSTER_PREFIX}-worker-"* ]] \
      || die "worker and benchmark nodes have different cluster prefixes: ${node}, ${BENCH_NODE}"
    [[ "$node" =~ (^|-)worker-0$ ]] && worker_zero_nodes+=("$node")
  done
  (( ${#worker_zero_nodes[@]} == 1 )) \
    || die "exactly one worker must match the experiment 1 name rule (*-worker-0) (found ${#worker_zero_nodes[@]})."
  SERVER_NODE="${worker_zero_nodes[0]}"
  TAG="${METHOD_SLUG}_${TOTAL_NODE_COUNT}n_${WORKER_COUNT}w_p${DENSITY}"
  log "topology ok: total=${TOTAL_NODE_COUNT}, cp=${CONTROL_PLANE_NODE}, benchmark=${BENCH_NODE}, workers=${WORKER_COUNT}, server=${SERVER_NODE}"
}

dump_pod_startup_diagnostics() {
  local pod="$1"
  {
    printf '\n===== startup diagnostics: %s/%s =====\n' "$NS" "$pod"
    kubectl -n "$NS" get pod "$pod" -o wide || true
    printf '%s\n' '----- container startup logs -----'
    kubectl -n "$NS" logs "$pod" --all-containers=true --tail=200 || true
    printf '%s\n' '----- pod status/events -----'
    kubectl -n "$NS" describe pod "$pod" || true
  } >&2
}

deploy_workloads() {
  local idx node namespace_owner namespace_ref

  log "recreating dedicated namespace: $NS"
  namespace_ref="$(kubectl get namespace "$NS" -o name --ignore-not-found)" \
    || die "failed to query namespace ${NS}"
  if [[ -n "$namespace_ref" ]]; then
    namespace_owner="$(kubectl get namespace "$NS" \
      -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
    [[ "$namespace_owner" == "exp2-benchmark" ]] \
      || die "existing namespace ${NS} is not owned by this script, refusing to delete it (managed-by=${namespace_owner:-none})."
    kubectl delete namespace "$NS" --wait=true --timeout=300s >/dev/null
  fi
  kubectl create namespace "$NS" >/dev/null
  kubectl label namespace "$NS" \
    app.kubernetes.io/managed-by=exp2-benchmark experiment=exp2 --overwrite >/dev/null

  kubectl taint node "$BENCH_NODE" benchmark-only=true:NoSchedule --overwrite >/dev/null

  log "deploying Benchmark/Server pods (mode=${MODE}, iperf3=${IPERF_PORT}, netserver=${NETPERF_PORT})"
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIG_MAP}
  namespace: ${NS}
  labels:
    experiment: exp2
data:
  method: "${METHOD}"
  mode: "${MODE}"
  totalNodes: "${TOTAL_NODE_COUNT}"
  workers: "${WORKER_COUNT}"
  density: "${DENSITY}"
  benchmarkNode: "${BENCH_NODE}"
  serverNode: "${SERVER_NODE}"
  iperfPort: "${IPERF_PORT}"
  netperfPort: "${NETPERF_PORT}"
  toolImage: "${TOOL_IMAGE}"
  toolInstallMode: "${TOOL_INSTALL_MODE}"
  toolPackages: "${TOOL_PACKAGES}"
  iperf3Version: "${EXP2_IPERF3_VERSION}"
  iperf3InstallMode: "${IPERF3_INSTALL_MODE}"
  alpineImage: "${ALPINE_IMAGE}"
  netperfVersion: "${NETPERF_VERSION}"
---
apiVersion: v1
kind: Pod
metadata:
  name: ${BENCH_POD}
  namespace: ${NS}
  labels:
    experiment: exp2
    app: exp2-benchmark
spec:
  nodeName: "${BENCH_NODE}"
  tolerations:
  - key: benchmark-only
    operator: Equal
    value: "true"
    effect: NoSchedule
  hostNetwork: ${HOST_NETWORK}
  dnsPolicy: ${DNS_POLICY}
  terminationGracePeriodSeconds: 1
  containers:
  - name: bench
    image: ${TOOL_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "-euc"]
    args:
    - |
      # Every tool ships in the image. No APT at startup, so the pod becomes
      # Ready immediately and no iteration depends on an external repository.
      for tool in bash sh sleep cat chmod test date rm touch iperf3 netperf mpstat nc python3 socat; do
        command -v "\$tool" >/dev/null
      done
      dpkg-query -W ${TOOL_PACKAGES} >/dev/null
      # iperf3 must be the image copy at /usr/local/bin/iperf3 (3.21). Another
      # path or version would measure without -P multithreading and UDP GSO.
      test "\$(command -v iperf3)" = /usr/local/bin/iperf3
      iperf3 --version | grep -F 'iperf ${EXP2_IPERF3_VERSION} ' >/dev/null
      iperf3 --version
      netperf -V
      mpstat -V
      python3 --version
      socat -V
      touch /tmp/exp2-tools-ready
      exec sleep infinity
    readinessProbe:
      exec:
        command: ["/bin/sh", "-c", "test -f /tmp/exp2-tools-ready"]
      initialDelaySeconds: 1
      periodSeconds: 2
      timeoutSeconds: 1
    resources:
      requests:
        cpu: "1000m"
        memory: "256Mi"
---
apiVersion: v1
kind: Pod
metadata:
  name: ${SERVER_POD}
  namespace: ${NS}
  labels:
    experiment: exp2
    app: exp2-server
spec:
  nodeName: "${SERVER_NODE}"
  hostNetwork: ${HOST_NETWORK}
  dnsPolicy: ${DNS_POLICY}
  terminationGracePeriodSeconds: 1
  containers:
  - name: iperf3
    image: ${TOOL_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "-euc"]
    args:
    - |
      # Every tool ships in the image (no APT at startup).
      for tool in bash sh sleep cat chmod test date rm touch iperf3 netperf netserver mpstat nc python3 socat; do
        command -v "\$tool" >/dev/null
      done
      dpkg-query -W ${TOOL_PACKAGES} >/dev/null
      # iperf3 must be the image copy at /usr/local/bin/iperf3 (3.21).
      test "\$(command -v iperf3)" = /usr/local/bin/iperf3
      iperf3 --version | grep -F 'iperf ${EXP2_IPERF3_VERSION} ' >/dev/null
      iperf3 --version
      netperf -V
      mpstat -V
      python3 --version
      socat -V
      netserver -D -p ${NETPERF_PORT} &
      netserver_pid=\$!
      sleep 1
      kill -0 "\$netserver_pid"
      touch /tmp/exp2-tools-ready
      # Restart the iperf3 server in place instead of restarting the container.
      # As the only container process, an abnormal exit (socket teardown race)
      # would restart the container, pollute the server node CPU and flap
      # Ready, and clients connected at that moment fail with
      # "control socket has closed unexpectedly" (exit 1).
      while true; do
        rc=0
        iperf3 -s -p ${IPERF_PORT} || rc=\$?
        printf '%s iperf3 server exited rc=%s; restarting\n' \
          "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "\$rc" >&2
        sleep 1
      done
    ports:
    - name: iperf3
      containerPort: ${IPERF_PORT}
      protocol: TCP
    - name: iperf3-udp
      containerPort: ${IPERF_PORT}
      protocol: UDP
    - name: netserver
      containerPort: ${NETPERF_PORT}
      protocol: TCP
    readinessProbe:
      exec:
        command: ["/bin/sh", "-c", "test -f /tmp/exp2-tools-ready && nc -z -w 1 127.0.0.1 ${IPERF_PORT} && nc -z -w 1 127.0.0.1 ${NETPERF_PORT}"]
      initialDelaySeconds: 1
      periodSeconds: 2
      timeoutSeconds: 2
    resources:
      requests:
        cpu: "1100m"
        memory: "320Mi"
EOF

  idx=0
  for node in "${WORKERS[@]}"; do
    log "deploying dummy pods: worker=${node}, replicas=${DENSITY}, hostNetwork=${HOST_NETWORK}"
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dummy-w${idx}
  namespace: ${NS}
  labels:
    experiment: exp2
    app: exp2-dummy
    worker-index: "${idx}"
spec:
  replicas: ${DENSITY}
  selector:
    matchLabels:
      experiment: exp2
      app: exp2-dummy
      worker-index: "${idx}"
  template:
    metadata:
      labels:
        experiment: exp2
        app: exp2-dummy
        worker-index: "${idx}"
    spec:
      nodeName: "${node}"
      hostNetwork: ${HOST_NETWORK}
      dnsPolicy: ${DNS_POLICY}
      terminationGracePeriodSeconds: 1
      containers:
      - name: dummy
        image: ${ALPINE_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["/bin/sh", "-c", "while true; do sleep 3600; done"]
        resources:
          requests:
            cpu: "10m"
            memory: "16Mi"
EOF
    idx=$((idx + 1))
  done

  log "waiting for pods to become Ready (timeout=${WAIT_TIMEOUT})"
  if ! kubectl -n "$NS" wait --for=condition=Ready "pod/${BENCH_POD}" "pod/${SERVER_POD}" \
      --timeout="$WAIT_TIMEOUT" >/dev/null; then
    dump_pod_startup_diagnostics "$BENCH_POD"
    dump_pod_startup_diagnostics "$SERVER_POD"
    die "Benchmark/Server Pod Ready failed; inspect the container startup logs and Pod events above."
  fi
  for ((idx = 0; idx < WORKER_COUNT; idx++)); do
    kubectl -n "$NS" rollout status "deployment/dummy-w${idx}" \
      --timeout="$WAIT_TIMEOUT" >/dev/null
  done
}

read_deployment_config() {
  kubectl -n "$NS" get configmap "$CONFIG_MAP" \
    -o jsonpath='{.data.method}{"|"}{.data.mode}{"|"}{.data.totalNodes}{"|"}{.data.workers}{"|"}{.data.density}{"|"}{.data.benchmarkNode}{"|"}{.data.serverNode}{"|"}{.data.iperfPort}{"|"}{.data.netperfPort}{"|"}{.data.toolImage}{"|"}{.data.alpineImage}'
}

verify_deployment() {
  local compare_requested="${1:-false}"
  local config config_method config_mode config_total config_workers config_density
  local config_bench config_server config_iperf config_netperf config_tool config_alpine
  local bench_spec server_spec taint dummy_lines node phase ready hostnet dns_policy image image_id
  local server_image_id ports services
  local benchmark_node_pods worker_node_pods pod_namespace pod_name owner_kind pod_app
  local total_dummy=0 expected_dummy expected_hostnet expected_dns count
  local -A dummy_by_node=()

  config="$(read_deployment_config)" \
    || die "${NS}/${CONFIG_MAP} does not exist. Run create first."
  IFS='|' read -r config_method config_mode config_total config_workers config_density \
    config_bench config_server config_iperf config_netperf config_tool config_alpine <<< "$config"

  [[ "$config_total" == "$TOTAL_NODE_COUNT" && "$config_workers" == "$WORKER_COUNT" \
     && "$config_bench" == "$BENCH_NODE" && "$config_server" == "$SERVER_NODE" ]] \
    || die "the deployed ConfigMap does not match the current topology. Run create again."
  [[ "$config_iperf" == "$IPERF_PORT" && "$config_netperf" == "$NETPERF_PORT" ]] \
    || die "deployed ports differ from the fixed values (${IPERF_PORT}/${NETPERF_PORT})."
  [[ "$config_method" == "$METHOD" && "$config_mode" == "$MODE" ]] \
    || die "deployed method differs from the request/cluster prefix (requested=${METHOD}/${MODE}, deployed=${config_method}/${config_mode})."

  if [[ "$compare_requested" == true ]]; then
    [[ "$config_density" == "$DENSITY" \
       && "$config_tool" == "$TOOL_IMAGE" && "$config_alpine" == "$ALPINE_IMAGE" ]] \
      || die "benchmark arguments/images differ from the deployment (requested=${METHOD}/${DENSITY}/${TOOL_IMAGE}/${ALPINE_IMAGE}, deployed=${config_method}/${config_density}/${config_tool}/${config_alpine})."
  fi

  expected_hostnet="false"
  expected_dns="ClusterFirst"
  if [[ "$config_mode" == "host" ]]; then
    expected_hostnet="true"
    # A hostNetwork pod depending on CoreDNS (ClusterFirstWithHostNet) cannot
    # start on Host, which has no cross-node PodCIDR path.
    expected_dns="Default"
  fi

  bench_spec="$(kubectl -n "$NS" get pod "$BENCH_POD" \
    -o jsonpath='{.spec.nodeName}{"|"}{.spec.hostNetwork}{"|"}{.spec.dnsPolicy}{"|"}{.spec.containers[0].resources.requests.cpu}{"|"}{.spec.containers[0].image}{"|"}{.status.containerStatuses[0].imageID}{"|"}{.status.phase}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')" \
    || die "failed to query the Benchmark pod"
  IFS='|' read -r node hostnet dns_policy count image image_id phase ready <<< "$bench_spec"
  # A false bool field can be omitted from the Kubernetes API JSON.
  [[ -n "$hostnet" ]] || hostnet="false"
  [[ "$node" == "$BENCH_NODE" && "$hostnet" == "$expected_hostnet" \
     && "$dns_policy" == "$expected_dns" \
     && ( "$count" == "1000m" || "$count" == "1" ) \
     && "$image" == "$config_tool" && -n "$image_id" \
     && "$phase" == "Running" && "$ready" == "True" ]] \
    || die "Benchmark pod mismatch: node=${node}, hostNetwork=${hostnet}, dnsPolicy=${dns_policy}(expected=${expected_dns}), cpu=${count}, image=${image}, imageID=${image_id:-none}, phase=${phase}, ready=${ready}"
  TOOL_IMAGE_ID="$image_id"

  taint="$(kubectl get node "$BENCH_NODE" \
    -o jsonpath='{range .spec.taints[?(@.key=="benchmark-only")]}{.value}{":"}{.effect}{end}')"
  [[ "$taint" == *"true:NoSchedule"* ]] \
    || die "the benchmark node has no benchmark-only=true:NoSchedule taint."

  # kube-system pods can land here as DaemonSets, Deployments and so on
  # depending on the Kubernetes/Cilium setup, and a NoSchedule taint never
  # evicts what was already there (CoreDNS). All of them are allowed and kept
  # in the raw snapshot; the only user workload allowed is our Benchmark pod.
  benchmark_node_pods="$(kubectl get pods -A --field-selector "spec.nodeName=${BENCH_NODE}" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{range .metadata.ownerReferences[*]}{.kind}{end}{"\n"}{end}')"
  while IFS='|' read -r pod_namespace pod_name owner_kind; do
    [[ -z "$pod_name" ]] && continue
    [[ "$pod_namespace" == "kube-system" ]] && continue
    [[ "$pod_namespace" == "$NS" && "$pod_name" == "$BENCH_POD" ]] \
      || die "a workload pod that is not allowed runs on the benchmark node: ${pod_namespace}/${pod_name} (owner=${owner_kind:-none})"
  done <<< "$benchmark_node_pods"

  # Any other workload on a worker pollutes the server/client node CPU and the
  # network results.
  for node in "${WORKERS[@]}"; do
    worker_node_pods="$(kubectl get pods -A --field-selector "spec.nodeName=${node}" \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.labels.app}{"\n"}{end}')" \
      || die "failed to query pods on worker ${node}"
    while IFS='|' read -r pod_namespace pod_name pod_app; do
      [[ -z "$pod_name" ]] && continue
      [[ "$pod_namespace" == "kube-system" ]] && continue
      if [[ "$pod_namespace" == "$NS" && "$pod_app" == "exp2-dummy" ]]; then
        continue
      fi
      if [[ "$pod_namespace" == "$NS" && "$pod_name" == "$SERVER_POD" \
         && "$node" == "$SERVER_NODE" ]]; then
        continue
      fi
      die "a workload pod that is not allowed runs on worker ${node}: ${pod_namespace}/${pod_name} (app=${pod_app:-none})"
    done <<< "$worker_node_pods"
  done

  server_spec="$(kubectl -n "$NS" get pod "$SERVER_POD" \
    -o jsonpath='{.spec.nodeName}{"|"}{.spec.hostNetwork}{"|"}{.spec.dnsPolicy}{"|"}{.spec.containers[?(@.name=="iperf3")].image}{"|"}{.status.containerStatuses[?(@.name=="iperf3")].imageID}{"|"}{.status.phase}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')" \
    || die "failed to query the Server pod"
  IFS='|' read -r node hostnet dns_policy image server_image_id phase ready <<< "$server_spec"
  [[ -n "$hostnet" ]] || hostnet="false"
  [[ "$node" == "$SERVER_NODE" && "$hostnet" == "$expected_hostnet" \
     && "$dns_policy" == "$expected_dns" \
     && "$image" == "$config_tool" \
     && "$server_image_id" == "$TOOL_IMAGE_ID" \
     && "$phase" == "Running" && "$ready" == "True" ]] \
    || die "Server pod mismatch: node=${node}, hostNetwork=${hostnet}, dnsPolicy=${dns_policy}(expected=${expected_dns}), image=${image}, imageID=${server_image_id:-none}, phase=${phase}, ready=${ready}"

  dummy_lines="$(kubectl -n "$NS" get pods -l app=exp2-dummy \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"|"}{.spec.hostNetwork}{"|"}{.spec.dnsPolicy}{"|"}{.spec.containers[0].image}{"|"}{.status.containerStatuses[0].imageID}{"|"}{.status.phase}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"\n"}{end}')" \
    || die "failed to query dummy pods"
  while IFS='|' read -r node hostnet dns_policy image image_id phase ready; do
    [[ -z "$node" ]] && continue
    [[ -n "$hostnet" ]] || hostnet="false"
    array_contains "$node" "${WORKERS[@]}" || die "a dummy pod runs on a non-worker node: $node"
    [[ "$hostnet" == "$expected_hostnet" && "$dns_policy" == "$expected_dns" \
       && "$image" == "$config_alpine" && -n "$image_id" \
       && "$phase" == "Running" && "$ready" == "True" ]] \
      || die "dummy pod state mismatch (node=${node}, hostNetwork=${hostnet}, dnsPolicy=${dns_policy}(expected=${expected_dns}), image=${image}, imageID=${image_id:-none}, phase=${phase}, ready=${ready})"
    if [[ -z "$ALPINE_IMAGE_ID" ]]; then
      ALPINE_IMAGE_ID="$image_id"
    else
      [[ "$image_id" == "$ALPINE_IMAGE_ID" ]] \
        || die "dummy pods resolved different imageIDs across nodes: ${ALPINE_IMAGE_ID} != ${image_id}"
    fi
    dummy_by_node["$node"]=$(( ${dummy_by_node["$node"]:-0} + 1 ))
    total_dummy=$((total_dummy + 1))
  done <<< "$dummy_lines"

  expected_dummy=$((WORKER_COUNT * config_density))
  (( total_dummy == expected_dummy )) \
    || die "wrong total dummy pod count (expected=${expected_dummy}, actual=${total_dummy})."
  for node in "${WORKERS[@]}"; do
    count=${dummy_by_node["$node"]:-0}
    (( count == config_density )) \
      || die "wrong dummy pod count on worker ${node} (expected=${config_density}, actual=${count})."
  done

  if [[ "$config_mode" == "host" ]]; then
    ports="$(kubectl -n "$NS" get pods -l app=exp2-dummy \
      -o jsonpath='{range .items[*].spec.containers[*].ports[*]}{.containerPort}{"/"}{.hostPort}{"\n"}{end}')"
    [[ -z "$ports" ]] || die "Host dummy pods must not open containerPort/hostPort: $ports"
  fi
  services="$(kubectl -n "$NS" get service -o name)"
  [[ -z "$services" ]] || die "the experiment namespace must contain no Service: $services"

  log "deployment verified: method=${config_method}, mode=${config_mode}, total=${config_total}, workers=${config_workers}, density=${config_density}, dummy=${total_dummy}"
}

# Keeps the whole node CPU as seen from the pod, per CPU at 1s resolution. The
# CSV metrics are extracted separately from the "Average: all" row.
#
# No helper script is installed in the container: mpstat runs inline. Output is
# written to /tmp inside the container instead of stdout, and a separate
# kubectl exec collects it after the measurement. Streaming the whole result
# (~35KB) over exec stdout at exit lost the output entirely whenever it
# coincided with UDP load saturating the node receive path (empty file, exit 0,
# no stderr).
cpu_sampler_command() {
  local label="$1"
  cat <<EOF
set -eu
out="/tmp/exp2_mpstat_${label}.txt"
rm -f "\$out" "\$out.partial"
[ "${IPERF_OMIT_SECONDS}" -eq 0 ] || sleep "${IPERF_OMIT_SECONDS}"
command -v mpstat >/dev/null 2>&1 || { echo "mpstat is required" >&2; exit 127; }
{
  printf '# sampler_label=%s\n' '${label}'
  printf '# sampler_started_at_utc=%s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  LC_ALL=C mpstat -P ALL 1 ${IPERF_MEASURE_SECONDS}
  printf '# sampler_finished_at_utc=%s\n' "\$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "\$out.partial"
mv -- "\$out.partial" "\$out"
EOF
}

remote_has_command() {
  local pod="$1" container="$2" command_name="$3"
  kubectl -n "$NS" exec "$pod" -c "$container" -- \
    sh -c "command -v ${command_name} >/dev/null 2>&1"
}

verify_required_container_tools() {
  local command_name pod container banner

  for command_name in bash sh sleep cat chmod test date rm touch iperf3 netperf mpstat nc python3 socat; do
    remote_has_command "$BENCH_POD" bench "$command_name" \
      || die "${BENCH_POD}/bench missing required command: ${command_name}"
  done
  for command_name in bash sh sleep cat chmod test date rm touch iperf3 netperf netserver mpstat nc python3 socat; do
    remote_has_command "$SERVER_POD" iperf3 "$command_name" \
      || die "${SERVER_POD}/iperf3 missing required command: ${command_name}"
  done

  # Confirm both pods run the prebuilt 3.21. This blocks a deployment where the
  # image was never loaded onto the node or where APT 3.9 takes precedence.
  for pod in "$BENCH_POD" "$SERVER_POD"; do
    container=bench
    [[ "$pod" == "$SERVER_POD" ]] && container=iperf3
    kubectl -n "$NS" exec "$pod" -c "$container" -- \
      sh -c 'test "$(command -v iperf3)" = /usr/local/bin/iperf3' \
      || die "${pod}/${container} iperf3 is not /usr/local/bin/iperf3 (prebuilt 3.21)."
    banner="$(kubectl -n "$NS" exec "$pod" -c "$container" -- iperf3 --version 2>/dev/null | head -n 1)" \
      || die "${pod}/${container} iperf3 --version failed"
    [[ "$banner" == "iperf ${EXP2_IPERF3_VERSION} "* ]] \
      || die "${pod}/${container} iperf3 version mismatch (expected=iperf ${EXP2_IPERF3_VERSION}, actual=${banner})"
  done

  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- netperf -V >/dev/null 2>&1 \
    || die "${BENCH_POD}/bench netperf version check failed"
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    dpkg-query -W $TOOL_PACKAGES >/dev/null 2>&1 \
    || die "${BENCH_POD}/bench APT package verification failed"
  kubectl -n "$NS" exec "$SERVER_POD" -c iperf3 -- \
    dpkg-query -W $TOOL_PACKAGES >/dev/null 2>&1 \
    || die "${SERVER_POD}/iperf3 APT package verification failed"
}

read_server_endpoint() {
  local snapshot node ip uid phase ready deleting
  snapshot="$(kubectl -n "$NS" get pod "$SERVER_POD" \
    -o jsonpath='{.spec.nodeName}{"|"}{.status.podIP}{"|"}{.metadata.uid}{"|"}{.status.phase}{"|"}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}{"|"}{.metadata.deletionTimestamp}')" \
    || return 1
  IFS='|' read -r node ip uid phase ready deleting <<< "$snapshot"
  [[ "$node" == "$SERVER_NODE" && -n "$ip" && -n "$uid" \
     && "$phase" == "Running" && "$ready" == "True" && -z "$deleting" ]] || {
    printf '[ERROR] server endpoint state mismatch: node=%s ip=%s uid=%s phase=%s ready=%s deleting=%s\n' \
      "${node:-none}" "${ip:-none}" "${uid:-none}" "${phase:-none}" \
      "${ready:-none}" "${deleting:-none}" >&2
    return 1
  }
  printf '%s|%s\n' "$ip" "$uid"
}

refresh_server_endpoint() {
  local endpoint old_ip="${SERVER_IP:-}"
  endpoint="$(read_server_endpoint)" || return 1
  IFS='|' read -r SERVER_IP SERVER_POD_UID <<< "$endpoint"
  if [[ -n "$old_ip" && "$old_ip" != "$SERVER_IP" ]]; then
    log "server pod IP changed: ${old_ip} -> ${SERVER_IP}"
  fi
}

server_endpoint_unchanged() {
  local endpoint current_ip current_uid
  endpoint="$(read_server_endpoint)" || return 1
  IFS='|' read -r current_ip current_uid <<< "$endpoint"
  [[ "$current_ip" == "$SERVER_IP" && "$current_uid" == "$SERVER_POD_UID" ]] || {
    printf '[ERROR] server endpoint changed during the measurement: expected=%s/%s actual=%s/%s\n' \
      "$SERVER_IP" "$SERVER_POD_UID" "$current_ip" "$current_uid" >&2
    return 1
  }
}

wait_server_listeners() {
  local attempts="${1:-10}" i ok=false
  for i in $(seq 1 "$attempts"); do
    ok=true
    kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
      nc -z -w 3 "$SERVER_IP" "$IPERF_PORT" >/dev/null 2>&1 || ok=false
    kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
      nc -z -w 3 "$SERVER_IP" "$NETPERF_PORT" >/dev/null 2>&1 || ok=false
    [[ "$ok" == true ]] && return 0
    sleep 3
  done
  return 1
}

prepare_runtime() {
  verify_required_container_tools
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- mpstat -P ALL 1 1 >/dev/null \
    || die "${BENCH_POD}/bench mpstat sampling check failed"
  kubectl -n "$NS" exec "$SERVER_POD" -c iperf3 -- mpstat -P ALL 1 1 >/dev/null \
    || die "${SERVER_POD}/iperf3 mpstat sampling check failed"

  refresh_server_endpoint || die "could not read the IP/Ready state of the worker-0 Server pod."
  wait_server_listeners 10 \
    || die "server is not listening (${SERVER_IP}:${IPERF_PORT}/${NETPERF_PORT})."

  # Short real data-path check for TCP, UDP and netperf.
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    iperf3 -c "$SERVER_IP" -p "$IPERF_PORT" -t 1 >/dev/null \
    || die "iperf3 TCP smoke test failed"
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    iperf3 -u -c "$SERVER_IP" -p "$IPERF_PORT" -b 1M -t 1 >/dev/null \
    || die "iperf3 UDP smoke test failed"
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    netperf -H "$SERVER_IP" -p "$NETPERF_PORT" -P 0 -t TCP_RR -l 1 -- -r 1,1 >/dev/null \
    || die "netperf TCP_RR smoke test failed"
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    netperf -H "$SERVER_IP" -p "$NETPERF_PORT" -P 0 -j -t TCP_RR -l 1 -- \
      -r 1,1 -o TRANSACTION_RATE,MEAN_LATENCY,P50_LATENCY,P99_LATENCY >/dev/null \
    || die "netperf histogram/percentile support check (-j, -o) failed"

  log "tools, listeners and data path verified: server=${SERVER_IP}, iperf3=${IPERF_PORT}, netserver=${NETPERF_PORT}"
}

choose_iteration_and_claim() {
  local prefix base f output max=0 found
  local -a existing=()

  mkdir -p "$RESULTS_DIR"
  prefix="${METHOD_SLUG}_${TOTAL_NODE_COUNT}n_${WORKER_COUNT}w_p${DENSITY}_exp2_"

  shopt -s nullglob
  existing=("$RESULTS_DIR/${prefix}iter"*".csv" "$RESULTS_DIR/${prefix}iter"*"_FAILED.csv")
  shopt -u nullglob

  if [[ "$ITERATION" == "auto" ]]; then
    for f in "${existing[@]}"; do
      base="$(basename "$f")"
      if [[ "$base" =~ _exp2_iter([0-9]+)(_FAILED)?\.csv$ ]]; then
        found="${BASH_REMATCH[1]}"
        (( found > max )) && max=$found
      fi
    done
    ITERATION=$((max + 1))
  fi

  base="${prefix}iter${ITERATION}"
  FINAL_CSV="$RESULTS_DIR/${base}.csv"
  FAILED_CSV="$RESULTS_DIR/${base}_FAILED.csv"
  WORK_CSV="$RESULTS_DIR/.${base}.inprogress.csv"
  TCP_CSV="$RESULTS_DIR/${base}_tcp.csv"
  UDP_CSV="$RESULTS_DIR/${base}_udp.csv"
  TCP_RR_1B_CSV="$RESULTS_DIR/${base}_tcp_rr_1b.csv"
  TCP_RR_1024B_CSV="$RESULTS_DIR/${base}_tcp_rr_1024b.csv"
  TCP_WORK_CSV="$RESULTS_DIR/.${base}_tcp.inprogress.csv"
  UDP_WORK_CSV="$RESULTS_DIR/.${base}_udp.inprogress.csv"
  TCP_RR_1B_WORK_CSV="$RESULTS_DIR/.${base}_tcp_rr_1b.inprogress.csv"
  TCP_RR_1024B_WORK_CSV="$RESULTS_DIR/.${base}_tcp_rr_1024b.inprogress.csv"
  CLAIM_DIR="$RESULTS_DIR/.${base}.claim"
  RAW_DIR="$RESULTS_DIR/raw/${base}"

  for output in "$FINAL_CSV" "$FAILED_CSV" "$WORK_CSV" \
    "$TCP_CSV" "$UDP_CSV" "$TCP_RR_1B_CSV" "$TCP_RR_1024B_CSV" \
    "$TCP_WORK_CSV" "$UDP_WORK_CSV" "$TCP_RR_1B_WORK_CSV" "$TCP_RR_1024B_WORK_CSV" "$RAW_DIR"; do
    [[ ! -e "$output" ]] \
      || die "results for iteration ${ITERATION} already exist. Use another number or auto: $output"
  done
  mkdir "$CLAIM_DIR" 2>/dev/null \
    || die "the same combination/iteration is running, or a stale claim exists: $CLAIM_DIR"
  mkdir -p "$RAW_DIR"
  RESULT_ACTIVE=true
}

write_result_header() {
  printf '%s\n' \
    'status,method,mode,total_nodes,workers,density,iteration,run,started_at_utc,finished_at_utc,tcp_gbps,tcp_retrans,tcp_cli_usr,tcp_cli_sys,tcp_cli_iowait,tcp_cli_soft,tcp_srv_usr,tcp_srv_sys,tcp_srv_iowait,tcp_srv_soft,udp_gbps,udp_jitter_ms,udp_lost,udp_total,udp_lost_pct,udp_cli_usr,udp_cli_sys,udp_cli_iowait,udp_cli_soft,udp_srv_usr,udp_srv_sys,udp_srv_iowait,udp_srv_soft,netperf_1b_tps,rtt_1b_mean_us,rtt_1b_p50_us,rtt_1b_p99_us,netperf_1024b_tps,rtt_1024b_mean_us,rtt_1024b_p50_us,rtt_1024b_p99_us' \
    > "$WORK_CSV"
}

reset_metrics() {
  M_TCP_GBPS=NA; M_TCP_RETRANS=NA
  M_TCP_CLI_USR=NA; M_TCP_CLI_SYS=NA; M_TCP_CLI_IOWAIT=NA; M_TCP_CLI_SOFT=NA
  M_TCP_SRV_USR=NA; M_TCP_SRV_SYS=NA; M_TCP_SRV_IOWAIT=NA; M_TCP_SRV_SOFT=NA
  M_UDP_GBPS=NA; M_UDP_JITTER=NA; M_UDP_LOST=NA; M_UDP_TOTAL=NA; M_UDP_LOST_PCT=NA
  M_UDP_CLI_USR=NA; M_UDP_CLI_SYS=NA; M_UDP_CLI_IOWAIT=NA; M_UDP_CLI_SOFT=NA
  M_UDP_SRV_USR=NA; M_UDP_SRV_SYS=NA; M_UDP_SRV_IOWAIT=NA; M_UDP_SRV_SOFT=NA
  M_NETPERF_1B_TPS=NA; M_RTT_1B_MEAN=NA; M_RTT_1B_P50=NA; M_RTT_1B_P99=NA
  M_NETPERF_1024B_TPS=NA; M_RTT_1024B_MEAN=NA; M_RTT_1024B_P50=NA; M_RTT_1024B_P99=NA
  RUN_STARTED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  RUN_FINISHED=""
}

append_run_row() {
  local status="$1" run="$2"
  local -a row
  RUN_FINISHED="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  row=(
    "$status" "$METHOD" "$MODE" "$TOTAL_NODE_COUNT" "$WORKER_COUNT" "$DENSITY" "$ITERATION" "$run"
    "$RUN_STARTED" "$RUN_FINISHED"
    "$M_TCP_GBPS" "$M_TCP_RETRANS"
    "$M_TCP_CLI_USR" "$M_TCP_CLI_SYS" "$M_TCP_CLI_IOWAIT" "$M_TCP_CLI_SOFT"
    "$M_TCP_SRV_USR" "$M_TCP_SRV_SYS" "$M_TCP_SRV_IOWAIT" "$M_TCP_SRV_SOFT"
    "$M_UDP_GBPS" "$M_UDP_JITTER" "$M_UDP_LOST" "$M_UDP_TOTAL" "$M_UDP_LOST_PCT"
    "$M_UDP_CLI_USR" "$M_UDP_CLI_SYS" "$M_UDP_CLI_IOWAIT" "$M_UDP_CLI_SOFT"
    "$M_UDP_SRV_USR" "$M_UDP_SRV_SYS" "$M_UDP_SRV_IOWAIT" "$M_UDP_SRV_SOFT"
    "$M_NETPERF_1B_TPS" "$M_RTT_1B_MEAN" "$M_RTT_1B_P50" "$M_RTT_1B_P99"
    "$M_NETPERF_1024B_TPS" "$M_RTT_1024B_MEAN" "$M_RTT_1024B_P50" "$M_RTT_1024B_P99"
  )
  (IFS=','; printf '%s\n' "${row[*]}") >> "$WORK_CSV"
}

fail_current_run() {
  local run="$1" stage="$2" message="$3"
  printf 'stage=%s\nmessage=%s\ntime=%s\n' \
    "$stage" "$message" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    > "$RAW_DIR/run${run}_failure.txt"
  append_run_row FAILED "$run"
  die "run ${run} failed (${stage}): ${message}"
}

# On an iperf3 client failure ("control socket has closed unexpectedly" and
# friends) the server-side state is written to raw/. A rising restartCount means
# a container-level restart (outside the supervision loop); "iperf3 server
# exited" in the log means the loop caught the server process exiting, so the
# two causes stay distinguishable afterwards.
# An mpstat parse failure can also happen after the sampler exited 0 (format or
# truncation), and without the original file the cause cannot be pinned down, so
# the file size, whether an Average block exists and the last lines are kept.
dump_cpu_sample_diagnostics() {
  local run="$1" phase="$2" side="$3" file="$4"
  local out="$RAW_DIR/run${run}_${phase}_${side}_cpu_diag.txt"
  {
    printf 'captured_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'source_file=%s\n' "$file"
    if [[ -f "$file" ]]; then
      printf 'size_bytes=%s\n' "$(wc -c <"$file" | tr -d ' ')"
      printf 'line_count=%s\n' "$(wc -l <"$file" | tr -d ' ')"
      printf 'average_block_lines=%s\n' "$(grep -c '^Average:' "$file" || true)"
      printf -- '--- non-numeric fields on Average rows ---\n'
      grep '^Average:' "$file" | grep -E '(^|[[:space:]])-[0-9]' || printf '(none)\n'
      printf -- '--- tail 20 ---\n'
      tail -n 20 "$file"
    else
      printf 'size_bytes=0 (file missing)\n'
    fi
  } > "$out" 2>&1 || true
}

fail_cpu_parse() {
  local run="$1" stage="$2" phase="$3" side="$4" file="$5"
  dump_cpu_sample_diagnostics "$run" "$phase" "$side" "$file"
  [[ "$side" == "server" ]] && dump_server_runtime_diagnostics "$run" "$phase"
  fail_current_run "$run" "$stage" "${side} mpstat parse failed (diagnostics: run${run}_${phase}_${side}_cpu_diag.txt)"
}

dump_server_runtime_diagnostics() {
  local run="$1" phase="$2" out="$RAW_DIR/run${run}_${phase}_server_diag.txt"
  {
    printf 'captured_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- '--- server pod containerStatuses ---\n'
    kubectl -n "$NS" get pod "$SERVER_POD" \
      -o jsonpath='{range .status.containerStatuses[*]}{.name}{" restartCount="}{.restartCount}{" ready="}{.ready}{"\n"}{end}' || true
    printf -- '--- server container logs (tail 30) ---\n'
    kubectl -n "$NS" logs "$SERVER_POD" -c iperf3 --tail 30 || true
  } > "$out" 2>&1 || true
}

read_cpu_metrics() {
  local file="$1"
  awk '
    # sysstat prints "-0.00" when a /proc/stat delta dips slightly negative (a
    # rounding artifact of a real zero). It is actually observed when the server
    # node piles up softirq under heavy UDP receive, so a sign is accepted and
    # -0.01 < v < 0 is normalized to 0.00. Any other negative value is a real
    # anomaly and is preserved so it shows up in the results.
    function number(v) { return v ~ /^-?[0-9]+([.][0-9]+)?$/ }
    # "-0.00" is numerically exactly 0, so x < 0 never catches it. Normalize
    # the band "<= 0 and > -0.01" to 0.00 (a positive 0.00 stays 0.00).
    function norm(v,   x) { x = v + 0; return (x <= 0 && x > -0.01) ? "0.00" : v }
    /%usr/ {
      cpu = usr = sys = iowait = soft = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "CPU") cpu = i
        if ($i == "%usr") usr = i
        if ($i == "%sys") sys = i
        if ($i == "%iowait") iowait = i
        if ($i == "%soft") soft = i
      }
      if (cpu && usr && sys && iowait && soft) {
        usr_offset = usr - cpu
        sys_offset = sys - cpu
        iowait_offset = iowait - cpu
        soft_offset = soft - cpu
      }
    }
    $1 == "Average:" && cpu {
      all = 0
      for (i = 2; i <= NF; i++) if ($i == "all") { all = i; break }
      if (all &&
          number($(all + usr_offset)) && number($(all + sys_offset)) &&
          number($(all + iowait_offset)) && number($(all + soft_offset))) {
        value = norm($(all + usr_offset)) "," norm($(all + sys_offset)) "," \
                norm($(all + iowait_offset)) "," norm($(all + soft_offset))
      }
    }
    END { if (value == "") exit 1; print value }
  ' "$file"
}

python_file_path() {
  local file="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$file"
  else
    printf '%s\n' "$file"
  fi
}

parse_tcp_json() {
  local file="$1" native_file
  native_file="$(python_file_path "$file")"
  "$PYTHON_BIN" - "$native_file" <<'PY'
import json, math, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
end = data.get("end", {})
received = end.get("sum_received") or {}
sent = end.get("sum_sent") or {}
bps = received.get("bits_per_second")
retrans = sent.get("retransmits")
if isinstance(bps, bool) or not isinstance(bps, (int, float)) or not math.isfinite(bps) or bps < 0:
    raise SystemExit("invalid TCP bits_per_second")
if isinstance(retrans, bool) or not isinstance(retrans, int) or retrans < 0:
    raise SystemExit("invalid TCP retransmits")
print(f"{bps / 1e9:.6f}\t{int(retrans)}")
PY
}

parse_udp_json() {
  local file="$1" native_file
  native_file="$(python_file_path "$file")"
  "$PYTHON_BIN" - "$native_file" <<'PY'
import json, math, sys
with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)
end = data.get("end", {})
summary = end.get("sum_received") or end.get("sum") or {}
keys = ("bits_per_second", "jitter_ms", "lost_packets", "packets", "lost_percent")
values = [summary.get(k) for k in keys]
if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0 for v in values):
    raise SystemExit("invalid UDP summary")
bps, jitter, lost, packets, lost_pct = values
if not isinstance(lost, int) or not isinstance(packets, int) or lost > packets or lost_pct > 100:
    raise SystemExit("inconsistent UDP loss summary")
print(f"{bps / 1e9:.6f}\t{jitter:.6f}\t{int(lost)}\t{int(packets)}\t{lost_pct:.6f}")
PY
}

parse_netperf_csv() {
  local file="$1"
  awk -F',' '
    function number(v) { return v ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/ }
    NF == 4 && number($1) && number($2) && number($3) && number($4) {
      n++
      line = $1 "\t" $2 "\t" $3 "\t" $4
      p50 = $3 + 0
      p99 = $4 + 0
    }
    END {
      if (n != 1 || line == "" || p50 > p99) exit 1
      print line
    }
  ' "$file"
}

run_netperf_rr() {
  local run="$1" payload="$2" label="$3"
  local warmup_file output_file stage

  stage="netperf_${label}"
  server_endpoint_unchanged 2>> "$RAW_DIR/run${run}_endpoint.stderr" \
    || fail_current_run "$run" "${stage}_endpoint" "server pod UID/IP changed before the ${payload}B TCP_RR"

  warmup_file="$RAW_DIR/run${run}_netperf_${label}_warmup.txt"
  output_file="$RAW_DIR/run${run}_netperf_${label}.csv"
  printf 'netperf -H %s -p 10001 -P 0 -t TCP_RR -l 10 -- -r %s,%s\n' \
    "$SERVER_IP" "$payload" "$payload" >> "$RAW_DIR/commands.txt"
  log "TCP_RR warm-up: ${NETPERF_WARMUP_SECONDS}s, payload=${payload}/${payload} byte"
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    netperf -H "$SERVER_IP" -p "$NETPERF_PORT" -P 0 -t TCP_RR \
      -l "$NETPERF_WARMUP_SECONDS" -- -r "$payload,$payload" \
      > "$warmup_file" 2> "$RAW_DIR/run${run}_netperf_${label}_warmup.stderr" \
    || fail_current_run "$run" "${stage}_warmup" "netperf ${payload}B warm-up failed"

  printf 'netperf -H %s -p 10001 -P 0 -j -t TCP_RR -l 50 -- -r %s,%s -o TRANSACTION_RATE,MEAN_LATENCY,P50_LATENCY,P99_LATENCY\n' \
    "$SERVER_IP" "$payload" "$payload" >> "$RAW_DIR/commands.txt"
  log "TCP_RR measurement: payload=${payload}/${payload} byte, ${NETPERF_MEASURE_SECONDS}s + histogram percentiles (-j)"
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    netperf -H "$SERVER_IP" -p "$NETPERF_PORT" -P 0 -j -t TCP_RR \
      -l "$NETPERF_MEASURE_SECONDS" -- -r "$payload,$payload" \
      -o TRANSACTION_RATE,MEAN_LATENCY,P50_LATENCY,P99_LATENCY \
      > "$output_file" 2> "$RAW_DIR/run${run}_netperf_${label}.stderr" \
    || fail_current_run "$run" "$stage" "netperf ${payload}B measurement failed"

  NETPERF_RESULT="$(parse_netperf_csv "$output_file" \
    2> "$RAW_DIR/run${run}_netperf_${label}_parse.stderr")" \
    || fail_current_run "$run" "${stage}_parse" "TPS/mean/P50/P99 parse or range check failed"
  server_endpoint_unchanged 2>> "$RAW_DIR/run${run}_endpoint.stderr" \
    || fail_current_run "$run" "${stage}_endpoint" "server pod UID/IP changed during the ${payload}B TCP_RR"
}

remove_remote_cpu_sample() {
  local pod="$1" container="$2" label="$3"
  kubectl -n "$NS" exec "$pod" -c "$container" -- \
    rm -f "/tmp/exp2_mpstat_${label}.txt" "/tmp/exp2_mpstat_${label}.txt.partial" \
    >/dev/null 2>&1 || true
}

# Collected after the measurement, once the datapath is quiet. A failed fetch
# or an unparsable file is retried a bounded number of times; after that the
# caller fails the run, so an iteration cannot stretch on endless retries.
fetch_cpu_sample() {
  local pod="$1" container="$2" label="$3" dest="$4"
  local remote="/tmp/exp2_mpstat_${label}.txt"
  local stderr_file="${dest%.txt}.stderr"
  local attempt

  for (( attempt = 1; attempt <= CPU_SAMPLE_FETCH_ATTEMPTS; attempt++ )); do
    if kubectl -n "$NS" exec "$pod" -c "$container" -- cat "$remote" \
        > "$dest" 2>> "$stderr_file"; then
      # The label check prevents picking up a leftover file from another phase.
      if [[ -s "$dest" ]] \
         && head -n 1 "$dest" | grep -qxF "# sampler_label=${label}" \
         && read_cpu_metrics "$dest" >/dev/null 2>&1; then
        remove_remote_cpu_sample "$pod" "$container" "$label"
        (( attempt == 1 )) || log "CPU sample collected (${pod}, attempt ${attempt}/${CPU_SAMPLE_FETCH_ATTEMPTS})"
        return 0
      fi
    fi
    printf '[WARN] CPU sample fetch failed (%s, attempt %d/%d): %s (%s bytes)\n' \
      "$pod" "$attempt" "$CPU_SAMPLE_FETCH_ATTEMPTS" "$remote" \
      "$( [[ -f "$dest" ]] && wc -c <"$dest" | tr -d ' ' || echo 0 )" >&2
    (( attempt == CPU_SAMPLE_FETCH_ATTEMPTS )) || sleep "$CPU_SAMPLE_FETCH_DELAY"
  done
  return 1
}

start_cpu_pair() {
  local client_file="$1" server_file="$2" label="$3"
  CPU_SAMPLE_LABEL="$label"
  CPU_CLIENT_FILE="$client_file"
  CPU_SERVER_FILE="$server_file"
  # The sampler writes no stdout: the result stays in the container /tmp and
  # wait_cpu_pair collects it with a separate exec after the measurement.
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    sh -c "$(cpu_sampler_command "${label}_client")" \
    >/dev/null 2> "${client_file%.txt}.stderr" &
  CPU_CLIENT_PID=$!
  kubectl -n "$NS" exec "$SERVER_POD" -c iperf3 -- \
    sh -c "$(cpu_sampler_command "${label}_server")" \
    >/dev/null 2> "${server_file%.txt}.stderr" &
  CPU_SERVER_PID=$!
}

stop_cpu_pair_after_failure() {
  kill "$CPU_CLIENT_PID" "$CPU_SERVER_PID" 2>/dev/null || true
  wait "$CPU_CLIENT_PID" 2>/dev/null || true
  wait "$CPU_SERVER_PID" 2>/dev/null || true
  CPU_CLIENT_PID=""
  CPU_SERVER_PID=""
  if [[ -n "$CPU_SAMPLE_LABEL" ]]; then
    remove_remote_cpu_sample "$BENCH_POD" bench "${CPU_SAMPLE_LABEL}_client"
    remove_remote_cpu_sample "$SERVER_POD" iperf3 "${CPU_SAMPLE_LABEL}_server"
    CPU_SAMPLE_LABEL=""
  fi
}

wait_cpu_pair() {
  local rc=0
  wait "$CPU_CLIENT_PID" || rc=1
  wait "$CPU_SERVER_PID" || rc=1
  CPU_CLIENT_PID=""
  CPU_SERVER_PID=""
  if (( rc != 0 )); then
    stop_cpu_pair_after_failure
    return 1
  fi
  fetch_cpu_sample "$BENCH_POD" bench "${CPU_SAMPLE_LABEL}_client" "$CPU_CLIENT_FILE" || rc=1
  fetch_cpu_sample "$SERVER_POD" iperf3 "${CPU_SAMPLE_LABEL}_server" "$CPU_SERVER_FILE" || rc=1
  CPU_SAMPLE_LABEL=""
  return "$rc"
}

run_one() {
  local run="$1" tcp_json tcp_cli_file tcp_srv_file udp_json udp_cli_file udp_srv_file
  local tcp_parsed udp_parsed client_cpu server_cpu
  local iperf_rc

  reset_metrics
  log "========== run ${run}/${RUNS} (${TAG}) =========="

  refresh_server_endpoint 2> "$RAW_DIR/run${run}_endpoint.stderr" \
    || fail_current_run "$run" server_endpoint "failed to read worker-0 server pod IP/Ready"
  wait_server_listeners 10 \
    || fail_current_run "$run" server_listening "${SERVER_IP}:${IPERF_PORT}/${NETPERF_PORT} is not listening"
  printf 'checked_at_utc=%s\nnode=%s\npod=%s\nuid=%s\nip=%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SERVER_NODE" "$SERVER_POD" \
    "$SERVER_POD_UID" "$SERVER_IP" > "$RAW_DIR/run${run}_server_endpoint.txt"

  tcp_json="$RAW_DIR/run${run}_tcp.json"
  tcp_cli_file="$RAW_DIR/run${run}_tcp_cpu_client.txt"
  tcp_srv_file="$RAW_DIR/run${run}_tcp_cpu_server.txt"
  printf 'iperf3 -P 4 -O 10 -c %s -p 10000 -t 60 -J\n' "$SERVER_IP" \
    >> "$RAW_DIR/commands.txt"
  log "TCP: 10s pre-test + 60s measured, 4 streams"
  start_cpu_pair "$tcp_cli_file" "$tcp_srv_file" "run${run}_tcp"
  set +e
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    iperf3 -P 4 -O "$IPERF_OMIT_SECONDS" -c "$SERVER_IP" -p "$IPERF_PORT" \
      -t "$IPERF_MEASURE_SECONDS" -J \
      > "$tcp_json" 2> "$RAW_DIR/run${run}_tcp.stderr"
  iperf_rc=$?
  set -e
  if (( iperf_rc != 0 )); then
    stop_cpu_pair_after_failure
    dump_server_runtime_diagnostics "$run" tcp
    fail_current_run "$run" tcp "iperf3 exit=${iperf_rc}"
  fi
  wait_cpu_pair || fail_current_run "$run" tcp_cpu "mpstat sampler run or fetch failed (${CPU_SAMPLE_FETCH_ATTEMPTS} retries exhausted)"
  server_endpoint_unchanged 2>> "$RAW_DIR/run${run}_endpoint.stderr" \
    || fail_current_run "$run" tcp_endpoint "server pod UID/IP changed during the TCP measurement"

  tcp_parsed="$(parse_tcp_json "$tcp_json" 2> "$RAW_DIR/run${run}_tcp_parse.stderr")" \
    || fail_current_run "$run" tcp_parse "failed to parse a required iperf3 JSON field"
  IFS=$'\t' read -r M_TCP_GBPS M_TCP_RETRANS <<< "$tcp_parsed"
  client_cpu="$(read_cpu_metrics "$tcp_cli_file")" \
    || fail_cpu_parse "$run" tcp_cpu_client tcp client "$tcp_cli_file"
  server_cpu="$(read_cpu_metrics "$tcp_srv_file")" \
    || fail_cpu_parse "$run" tcp_cpu_server tcp server "$tcp_srv_file"
  IFS=',' read -r M_TCP_CLI_USR M_TCP_CLI_SYS M_TCP_CLI_IOWAIT M_TCP_CLI_SOFT <<< "$client_cpu"
  IFS=',' read -r M_TCP_SRV_USR M_TCP_SRV_SYS M_TCP_SRV_IOWAIT M_TCP_SRV_SOFT <<< "$server_cpu"
  log "TCP result: ${M_TCP_GBPS} Gbps, retrans=${M_TCP_RETRANS}"

  (( PAUSE_BETWEEN_TESTS == 0 )) || sleep "$PAUSE_BETWEEN_TESTS"

  udp_json="$RAW_DIR/run${run}_udp.json"
  udp_cli_file="$RAW_DIR/run${run}_udp_cpu_client.txt"
  udp_srv_file="$RAW_DIR/run${run}_udp_cpu_server.txt"
  printf 'iperf3 -u -c %s -p 10000 -P 4 -b 0 -O 10 -t 60 -J\n' "$SERVER_IP" \
    >> "$RAW_DIR/commands.txt"
  log "UDP: 10s pre-test + 60s measured, 4 streams, unlimited bitrate (-b 0)"
  start_cpu_pair "$udp_cli_file" "$udp_srv_file" "run${run}_udp"
  set +e
  kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
    iperf3 -u -c "$SERVER_IP" -p "$IPERF_PORT" -P 4 -b 0 \
      -O "$IPERF_OMIT_SECONDS" -t "$IPERF_MEASURE_SECONDS" -J \
      > "$udp_json" 2> "$RAW_DIR/run${run}_udp.stderr"
  iperf_rc=$?
  set -e
  if (( iperf_rc != 0 )); then
    stop_cpu_pair_after_failure
    dump_server_runtime_diagnostics "$run" udp
    fail_current_run "$run" udp "iperf3 exit=${iperf_rc}"
  fi
  wait_cpu_pair || fail_current_run "$run" udp_cpu "mpstat sampler run or fetch failed (${CPU_SAMPLE_FETCH_ATTEMPTS} retries exhausted)"
  server_endpoint_unchanged 2>> "$RAW_DIR/run${run}_endpoint.stderr" \
    || fail_current_run "$run" udp_endpoint "server pod UID/IP changed during the UDP measurement"

  udp_parsed="$(parse_udp_json "$udp_json" 2> "$RAW_DIR/run${run}_udp_parse.stderr")" \
    || fail_current_run "$run" udp_parse "failed to parse a required iperf3 JSON field"
  IFS=$'\t' read -r M_UDP_GBPS M_UDP_JITTER M_UDP_LOST M_UDP_TOTAL M_UDP_LOST_PCT <<< "$udp_parsed"
  client_cpu="$(read_cpu_metrics "$udp_cli_file")" \
    || fail_cpu_parse "$run" udp_cpu_client udp client "$udp_cli_file"
  server_cpu="$(read_cpu_metrics "$udp_srv_file")" \
    || fail_cpu_parse "$run" udp_cpu_server udp server "$udp_srv_file"
  IFS=',' read -r M_UDP_CLI_USR M_UDP_CLI_SYS M_UDP_CLI_IOWAIT M_UDP_CLI_SOFT <<< "$client_cpu"
  IFS=',' read -r M_UDP_SRV_USR M_UDP_SRV_SYS M_UDP_SRV_IOWAIT M_UDP_SRV_SOFT <<< "$server_cpu"
  log "UDP result: ${M_UDP_GBPS} Gbps, jitter=${M_UDP_JITTER}ms, loss=${M_UDP_LOST}/${M_UDP_TOTAL} (${M_UDP_LOST_PCT}%)"

  (( PAUSE_BETWEEN_TESTS == 0 )) || sleep "$PAUSE_BETWEEN_TESTS"

  run_netperf_rr "$run" "$NETPERF_PAYLOAD_1B" 1b
  IFS=$'\t' read -r M_NETPERF_1B_TPS M_RTT_1B_MEAN M_RTT_1B_P50 M_RTT_1B_P99 <<< "$NETPERF_RESULT"
  log "TCP_RR 1B result: TPS=${M_NETPERF_1B_TPS}, mean=${M_RTT_1B_MEAN}us, p50=${M_RTT_1B_P50}us, p99=${M_RTT_1B_P99}us"

  (( PAUSE_BETWEEN_TESTS == 0 )) || sleep "$PAUSE_BETWEEN_TESTS"

  run_netperf_rr "$run" "$NETPERF_PAYLOAD_1024B" 1024b
  IFS=$'\t' read -r M_NETPERF_1024B_TPS M_RTT_1024B_MEAN M_RTT_1024B_P50 M_RTT_1024B_P99 <<< "$NETPERF_RESULT"
  log "TCP_RR 1024B result: TPS=${M_NETPERF_1024B_TPS}, mean=${M_RTT_1024B_MEAN}us, p50=${M_RTT_1024B_P50}us, p99=${M_RTT_1024B_P99}us"

  append_run_row SUCCESS "$run"
}

append_summary() {
  local summary
  summary="$(awk -F',' -v expected="$RUNS" '
    function number(v) { return v ~ /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$/ }
    $1 == "SUCCESS" && $8 ~ /^[0-9]+$/ {
      n++
      method=$2; mode=$3; total=$4; workers=$5; density=$6; iteration=$7
      for (i=11; i<=NF; i++) {
        if (!number($i)) bad=1
        sum[i]+=$i
      }
      max_nf=NF
    }
    END {
      if (bad || n != expected || max_nf != 41) exit 1
      printf "SUMMARY,%s,%s,%s,%s,%s,%s,avg,,,", method,mode,total,workers,density,iteration
      for (i=11; i<=max_nf; i++) {
        printf "%.6f%s", sum[i]/n, (i==max_nf ? "\n" : ",")
      }
    }
  ' "$WORK_CSV")" || die "could not average exactly ${RUNS} successful runs."
  printf '%s\n' "$summary" >> "$WORK_CSV"
}

validate_split_csv() {
  local file="$1" expected_columns="$2" expected_rows=$((RUNS + 2))
  awk -F',' -v columns="$expected_columns" -v rows="$expected_rows" '
    NF != columns { bad = 1 }
    END { if (bad || NR != rows) exit 1 }
  ' "$file"
}

write_split_csvs() {
  local source="$1" expected_rows=$((RUNS + 2))

  awk -F',' -v OFS=',' -v expected="$expected_rows" \
      -v tcp="$TCP_WORK_CSV" \
      -v udp="$UDP_WORK_CSV" \
      -v rr1="$TCP_RR_1B_WORK_CSV" \
      -v rr1024="$TCP_RR_1024B_WORK_CSV" '
    NF != 41 { bad = 1 }
    NR == 1 && $1 != "status" { bad = 1 }
    NR > 1 && NR < expected && $1 != "SUCCESS" { bad = 1 }
    NR == expected && $1 != "SUMMARY" { bad = 1 }
    {
      print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20 > tcp
      print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30,$31,$32,$33 > udp
      print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$34,$35,$36,$37 > rr1
      print $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$38,$39,$40,$41 > rr1024
    }
    END { if (bad || NR != expected) exit 1 }
  ' "$source" || return 1

  validate_split_csv "$TCP_WORK_CSV" 20 || return 1
  validate_split_csv "$UDP_WORK_CSV" 23 || return 1
  validate_split_csv "$TCP_RR_1B_WORK_CSV" 14 || return 1
  validate_split_csv "$TCP_RR_1024B_WORK_CSV" 14 || return 1

  mv -- "$TCP_WORK_CSV" "$TCP_CSV" || return 1
  mv -- "$UDP_WORK_CSV" "$UDP_CSV" || return 1
  mv -- "$TCP_RR_1B_WORK_CSV" "$TCP_RR_1B_CSV" || return 1
  mv -- "$TCP_RR_1024B_WORK_CSV" "$TCP_RR_1024B_CSV" || return 1
}

write_metadata() {
  {
    echo "started_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "method=$METHOD"
    echo "mode=$MODE"
    echo "total_nodes=$TOTAL_NODE_COUNT"
    echo "workers=$WORKER_COUNT"
    echo "density=$DENSITY"
    echo "runs=$RUNS"
    echo "iteration=$ITERATION"
    echo "benchmark_node=$BENCH_NODE"
    echo "cluster_prefix=$CLUSTER_PREFIX"
    echo "server_node=$SERVER_NODE"
    echo "server_ip=$SERVER_IP"
    echo "server_pod_uid=$SERVER_POD_UID"
    echo "iperf_port=$IPERF_PORT"
    echo "netperf_port=$NETPERF_PORT"
    echo "tool_image=$TOOL_IMAGE"
    echo "tool_install_mode=$TOOL_INSTALL_MODE"
    echo "tool_packages=$TOOL_PACKAGES"
    echo "iperf3_version=$EXP2_IPERF3_VERSION"
    echo "iperf3_install_mode=$IPERF3_INSTALL_MODE"
    echo "netperf_install_mode=$TOOL_INSTALL_MODE"
    echo "netperf_version=$NETPERF_VERSION"
    echo "alpine_image=$ALPINE_IMAGE"
    echo "tool_image_id=$TOOL_IMAGE_ID"
    echo "alpine_image_id=$ALPINE_IMAGE_ID"
    echo "iperf_omit_seconds=$IPERF_OMIT_SECONDS"
    echo "iperf_measure_seconds=$IPERF_MEASURE_SECONDS"
    echo "netperf_warmup_seconds=$NETPERF_WARMUP_SECONDS"
    echo "netperf_measure_seconds=$NETPERF_MEASURE_SECONDS"
    echo "netperf_payloads_bytes=$NETPERF_PAYLOAD_1B,$NETPERF_PAYLOAD_1024B"
    echo "pause_between_tests_seconds=$PAUSE_BETWEEN_TESTS"
    echo "pause_between_runs_seconds=$PAUSE_BETWEEN_RUNS"
    echo "cpu_scope=node-wide via Pod-visible /proc/stat"
    echo "cpu_sampler=LC_ALL=C mpstat -P ALL 1 ${IPERF_MEASURE_SECONDS}"
    echo "cpu_iowait_note=Linux iowait is retained as a secondary indicator"
  } > "$RAW_DIR/config.txt"
  kubectl get nodes -o wide > "$RAW_DIR/nodes.txt"
  kubectl -n "$NS" get pods -o wide > "$RAW_DIR/pods.txt"
  kubectl get pods -A --field-selector "spec.nodeName=${BENCH_NODE}" -o wide \
    > "$RAW_DIR/benchmark-node-pods.txt"
  kubectl get pods -A --field-selector "spec.nodeName=${SERVER_NODE}" -o wide \
    > "$RAW_DIR/server-node-pods.txt"
  kubectl -n "$NS" get configmap "$CONFIG_MAP" -o yaml > "$RAW_DIR/exp2-config.yaml"
  kubectl -n "$NS" get pod "$BENCH_POD" "$SERVER_POD" -o yaml > "$RAW_DIR/benchmark-server-pods.yaml"
  kubectl -n "$NS" get deployment -l app=exp2-dummy -o yaml > "$RAW_DIR/dummy-deployments.yaml"
  {
    kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
      sh -c 'for c in bash sh sleep cat chmod test date rm touch iperf3 netperf mpstat nc python3 socat; do printf "%s=" "$c"; command -v "$c"; done' 2>&1 || true
    kubectl -n "$NS" exec "$SERVER_POD" -c iperf3 -- \
      sh -c 'for c in bash sh sleep cat chmod test date rm touch iperf3 netperf netserver mpstat nc python3 socat; do printf "%s=" "$c"; command -v "$c"; done' 2>&1 || true
    printf '%s\n' '[benchmark apt packages]'
    kubectl -n "$NS" exec "$BENCH_POD" -c bench -- \
      dpkg-query -W -f='${binary:Package}=${Version}\n' $TOOL_PACKAGES 2>&1 || true
    printf '%s\n' '[server apt packages]'
    kubectl -n "$NS" exec "$SERVER_POD" -c iperf3 -- \
      dpkg-query -W -f='${binary:Package}=${Version}\n' $TOOL_PACKAGES 2>&1 || true
    kubectl -n "$NS" exec "$BENCH_POD" -c bench -- iperf3 --version 2>&1 || true
    kubectl -n "$NS" exec "$BENCH_POD" -c bench -- netperf -V 2>&1 || true
    kubectl -n "$NS" exec "$BENCH_POD" -c bench -- mpstat -V 2>&1 || true
    kubectl -n "$NS" exec "$BENCH_POD" -c bench -- python3 --version 2>&1 || true
    kubectl -n "$NS" exec "$BENCH_POD" -c bench -- socat -V 2>&1 || true
    kubectl -n "$NS" exec "$SERVER_POD" -c iperf3 -- netserver -V 2>&1 || true
  } > "$RAW_DIR/tool-versions.txt"
}

run_benchmark() {
  local run
  detect_python
  choose_iteration_and_claim
  write_result_header
  write_metadata

  for ((run = 1; run <= RUNS; run++)); do
    run_one "$run"
    if (( run < RUNS && PAUSE_BETWEEN_RUNS > 0 )); then
      sleep "$PAUSE_BETWEEN_RUNS"
    fi
  done

  append_summary
  write_split_csvs "$WORK_CSV" \
    || die "failed to write or validate the per-metric TCP/UDP/TCP_RR CSVs"
  mv -- "$WORK_CSV" "$FINAL_CSV"
  RESULT_COMPLETE=true
  log "experiment 2 complete: $FINAL_CSV"
  log "per-metric CSVs: $TCP_CSV, $UDP_CSV, $TCP_RR_1B_CSV, $TCP_RR_1024B_CSV"
  log "raw data and metadata: $RAW_DIR"
}

cleanup_namespace() {
  local namespace_owner namespace_ref
  need kubectl
  namespace_ref="$(kubectl get namespace "$NS" -o name --ignore-not-found)" \
    || die "failed to query namespace ${NS}"
  if [[ -z "$namespace_ref" ]]; then
    log "namespace does not exist any more: $NS"
    return 0
  fi
  namespace_owner="$(kubectl get namespace "$NS" \
    -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
  [[ "$namespace_owner" == "exp2-benchmark" ]] \
    || die "namespace ${NS} is not owned by this script, refusing to delete it (managed-by=${namespace_owner:-none})."
  log "deleting namespace: $NS"
  kubectl delete namespace "$NS"
  log "benchmark node label/taint kept for the next experiment."
}

main() {
  parse_args "$@"
  case "$CMD" in
    ""|help) usage; return 0 ;;
    create|benchmark|verify|cleanup) ;;
    *) die "unknown subcommand: $CMD" ;;
  esac

  if [[ "$CMD" == "cleanup" ]]; then
    validate_experiment_namespace
    need kubectl
    kubectl cluster-info >/dev/null 2>&1 \
      || die "kubectl is not connected to a cluster (check KUBECONFIG)."
    acquire_cluster_lock
    cleanup_namespace
    return 0
  fi

  [[ "$METHOD_PROVIDED" == true ]] \
    || die "${CMD} requires -m/--method. The profile wrappers pass it safely."

  normalize_and_validate
  preflight
  discover_nodes
  acquire_cluster_lock
  case "$CMD" in
    create)
      deploy_workloads
      verify_deployment true
      verify_required_container_tools
      log "pods created. namespace=$NS (never deleted automatically)"
      log "measurement command: $0 benchmark -m '$METHOD' -d '$DENSITY' -n '$NS' -o '$RESULTS_DIR'"
      ;;
    benchmark)
      verify_deployment true
      prepare_runtime
      run_benchmark
      log "namespace and pods are kept after the benchmark: $NS"
      ;;
    verify)
      verify_deployment false
      verify_required_container_tools
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap cleanup_local_state EXIT
  main "$@"
fi
