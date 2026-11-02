#!/usr/bin/env bash
# Every formal proof of the repository at once: the three blocks (the SDRAM arbiter and the AXI master and slave
# bridges) run side by side and share the FORMAL_JOBS slots (see formal/common.sh). Each block prints its
# result when it ends, in the order below. Run from the root of the repository:  bash formal/all.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

FORMAL_SLOTS="$(mktemp -d)"
export FORMAL_SLOTS
trap 'rm -rf "$FORMAL_SLOTS"' EXIT

blocks=(formal/run.sh formal/axi_master/run.sh formal/axi_slave/run.sh)
pids=()
for i in "${!blocks[@]}"; do
  bash "${blocks[$i]}" > "$FORMAL_SLOTS/log.$i" 2>&1 &
  pids+=("$!")
done

status=0
for i in "${!blocks[@]}"; do
  wait "${pids[$i]}" || status=1
  cat "$FORMAL_SLOTS/log.$i"
done
exit "$status"
