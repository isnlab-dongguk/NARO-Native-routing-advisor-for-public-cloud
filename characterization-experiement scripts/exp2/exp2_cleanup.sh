#!/usr/bin/env bash
# Reclaims the dedicated namespace and its Benchmark/Server/Dummy pods once
# experiments 2 and 3 are finished.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/exp2_common.sh"

cleanup_usage() {
  local default_namespace="$1"
  cat <<EOF
Usage: $(basename "$0") [-n <namespace>]

Deletes the dedicated namespace and every experiment pod inside it, after both
experiment 2 and experiment 3 are finished. Default namespace: ${default_namespace}.

Options:
  -n, --namespace  the exp2- namespace to reclaim
  -h, --help       this help

Safety:
  Deletes only a namespace that starts with exp2- and carries the
  managed-by=exp2-benchmark ownership label. Result files and the node
  label/taint are kept.
EOF
}

namespace="${NS:-exp2-bench}"
namespace_seen=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      [[ $# -ge 2 ]] || profile_die "$1 requires a namespace."
      [[ "$namespace_seen" == false ]] || profile_die "specify namespace only once."
      namespace="$2"
      namespace_seen=true
      shift 2
      ;;
    --namespace=*)
      profile_die "use the '--namespace VALUE' form."
      ;;
    -h|--help)
      cleanup_usage "$namespace"
      exit 0
      ;;
    *)
      profile_die "unsupported option: $1"
      ;;
  esac
done

run_exp2 cleanup -n "$namespace"
