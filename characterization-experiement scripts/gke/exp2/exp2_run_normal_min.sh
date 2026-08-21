#!/usr/bin/env bash
# Normal pod network, minimum density: benchmark only (uses existing pods).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/exp2_common.sh"
run_normal_profile benchmark 1 "$@"
