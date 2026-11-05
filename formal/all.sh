#!/usr/bin/env bash
# Every formal proof of the repository at once: the blocks (the SDRAM arbiter, the SDRAM controller and its CPU
# bridge, the AXI master and slave bridges, the flash arbiter, the command port of the flash chip, the region router and the two caches) run side by side and share the FORMAL_JOBS slots (see formal/common.sh), with the engine chosen by
# FORMAL_ENGINE. Each block prints its result when it ends, in the order below, and the results of the blocks go
# to build/formal-results/result-<engine>.jsonl, which formal/aggregate.sh reads. Run from the root of the
# repository:  bash formal/all.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

FORMAL_ENGINE="${FORMAL_ENGINE:-bitwuzla}"
export FORMAL_ENGINE
echo "formal: engine $FORMAL_ENGINE"

FORMAL_SLOTS="$(mktemp -d)"
export FORMAL_SLOTS
trap 'rm -rf "$FORMAL_SLOTS"' EXIT

blocks=(formal/run.sh formal/axi_master/run.sh formal/axi_slave/run.sh formal/flash_arbiter/run.sh formal/flash_cmd_port/run.sh formal/mem_region_router/run.sh
  formal/sdram_cpu_bridge/run.sh formal/sdram_ctrl/run.sh formal/icache/run.sh formal/dcache/run.sh)
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

# The results of the blocks in one file, even when a block ended in failure: the aggregation needs them.
rm -rf build/formal-results
mkdir -p build/formal-results
cat build/formal/results.jsonl build/formal_axi/results.jsonl build/formal_axi_slave/results.jsonl \
  build/formal_flash_arbiter/results.jsonl build/formal_flash_cmd_port/results.jsonl build/formal_mem_region_router/results.jsonl build/formal_sdram_cpu_bridge/results.jsonl \
  build/formal_sdram_ctrl/results.jsonl build/formal_icache/results.jsonl build/formal_dcache/results.jsonl \
  > "build/formal-results/result-$FORMAL_ENGINE.jsonl" 2> /dev/null || true
exit "$status"
