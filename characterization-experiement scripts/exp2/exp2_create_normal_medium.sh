#!/usr/bin/env bash
# Normal pod network, medium density: create pods with 50 dummies per worker.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/exp2_common.sh"
run_normal_profile create 50 "$@"
