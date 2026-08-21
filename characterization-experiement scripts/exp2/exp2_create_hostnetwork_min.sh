#!/usr/bin/env bash
# hostNetwork, minimum density: create pods with 1 dummy per worker.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/exp2_common.sh"
run_hostnetwork_profile create 1 "$@"
