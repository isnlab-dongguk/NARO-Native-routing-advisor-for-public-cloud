#!/usr/bin/env bash
# Shared part of the experiment 2 profile wrappers.
# There is a single implementation (../exp2_benchmark.sh); each public wrapper
# calls only one stage, create or benchmark, so pod lifetime and measurement
# stay separate.
set -euo pipefail

(( BASH_VERSINFO[0] >= 4 )) || {
  printf 'ERROR: Bash 4 or newer is required (current %s).\n' "$BASH_VERSION" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly EXP2_MAIN="${SCRIPT_DIR}/../exp2_benchmark.sh"
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
  local kind="$1" density="$2" action="$3" action_text allowed
  if [[ "$action" == "create" ]]; then
    action_text="create pods only (shared by experiments 2 and 3, kept afterwards)"
    allowed="-n/--namespace"
  else
    action_text="run the experiment 2 benchmark only (uses existing pods, kept afterwards)"
    allowed="-i/--iteration, -n/--namespace, -o/--outdir, -r/--runs"
  fi
  if [[ "$kind" == "normal" ]]; then
    cat <<EOF
Usage: $(basename "$0") -m <VXLAN|Static|Dynamic> [options]
Action (action=${action}): ${action_text}
Fixed: hostNetwork=false, dummy pods per worker=${density}
Extra options allowed: ${allowed}
EOF
  else
    cat <<EOF
Usage: $(basename "$0") [options]
Action (action=${action}): ${action_text}
Fixed: method=Host, hostNetwork=true, dummy pods per worker=${density}
Extra options allowed: ${allowed}
EOF
  fi
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
      -h|--help) profile_usage normal "$density" "$action"; return 0 ;;
      *) forwarded+=("$1"); shift ;;
    esac
  done
  [[ "$method_seen" == true ]] || profile_die "the normal profile requires -m <method>."
  case "${method,,}" in
    vxlan|static|dynamic) ;;
    host) profile_die "use the hostnetwork profile for Host." ;;
    *) profile_die "unsupported normal method (VXLAN|Static|Dynamic): $method" ;;
  esac
  run_exp2 "$action" -m "$method" -d "$density" "${forwarded[@]}"
}

run_hostnetwork_profile() {
  local action="$1" density="$2"
  local -a forwarded=()
  shift 2
  [[ "$action" == "create" || "$action" == "benchmark" ]] \
    || profile_die "internal action error: $action"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--method|--method=*) profile_die "method=Host is fixed for this profile." ;;
      -d|--density|--density=*) profile_die "density=${density} is fixed for this profile." ;;
      -h|--help) profile_usage hostnetwork "$density" "$action"; return 0 ;;
      *) forwarded+=("$1"); shift ;;
    esac
  done
  run_exp2 "$action" -m Host -d "$density" "${forwarded[@]}"
}
