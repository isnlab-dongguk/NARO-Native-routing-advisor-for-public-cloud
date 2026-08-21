#!/usr/bin/env bash
# Shared part of the experiment 2 profile wrappers.
# There is a single GKE implementation (exp2_benchmark_gke.sh); each wrapper
# calls only one stage, create or benchmark, so pod lifetime and measurement
# stay separate.
set -euo pipefail

(( BASH_VERSINFO[0] >= 4 )) || {
  printf 'ERROR: Bash 4 or newer is required (current %s).\n' "$BASH_VERSION" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# GKE engine (same directory). The kubeadm engine is a separate file.
readonly EXP2_MAIN="${SCRIPT_DIR}/exp2_benchmark_gke.sh"
readonly IPERF_PORT=10000
readonly NETPERF_PORT=10001

[[ -f "$EXP2_MAIN" ]] || {
  printf 'ERROR: canonical experiment 2 script not found: %s\n' "$EXP2_MAIN" >&2
  exit 1
}

run_exp2() {
  exec bash "$EXP2_MAIN" "$@"
}

profile_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

profile_usage() {
  local density="$1" action="$2" action_text allowed
  if [[ "$action" == "create" ]]; then
    action_text="create pods only (shared by experiments 2 and 3, kept afterwards)"
    allowed="-n/--namespace"
  else
    action_text="run the experiment 2 benchmark only (uses existing pods, kept afterwards)"
    allowed="-i/--iteration, -n/--namespace, -o/--outdir, -r/--runs"
  fi
  cat <<EOF
Usage: $(basename "$0") -m Cloud [options]
Action (action=${action}): ${action_text}
Fixed: hostNetwork=false, dummy pods per worker=${density}
Extra options allowed: ${allowed}
EOF
}

run_normal_profile() {
  local action="$1" density="$2" method="" method_seen=false
  local -a forwarded=()
  shift 2
  [[ "$action" == "create" || "$action" == "benchmark" ]] \
    || profile_die "internal action error: $action"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--method)
        [[ $# -ge 2 ]] || profile_die "$1 requires a method."
        [[ "$method_seen" == false ]] || profile_die "specify method only once."
        method="$2"; method_seen=true; shift 2
        ;;
      --method=*) profile_die "use the '--method VALUE' form." ;;
      -d|--density|--density=*) profile_die "density=${density} is fixed for this profile." ;;
      -h|--help) profile_usage "$density" "$action"; return 0 ;;
      *) forwarded+=("$1"); shift ;;
    esac
  done
  [[ "$method_seen" == true ]] || profile_die "the GKE profile requires -m Cloud."
  case "${method,,}" in
    cloud) ;;
    *) profile_die "the GKE build only accepts -m Cloud: $method" ;;
  esac
  run_exp2 "$action" -m "$method" -d "$density" "${forwarded[@]}"
}
