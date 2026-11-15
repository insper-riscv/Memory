#!/usr/bin/env bash
# Formal verification of the MAX 10 user flash controller with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl,
# yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from the
# root of the repository:  bash formal/max10_flash/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The environment is free (bus, wait request, read
# data valid and CSR words), so the proof covers any behaviour of the megafunction.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=max10_flash
src="$root/src/ROM/SoC/max10_flash.vhd"
props="$root/formal/max10_flash/props.sv"
out="$root/build/formal_max10_flash"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>: the netlist and a copy that exposes the write enable
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gdata_addr_bits=4 max10_flash > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" wen
  grep -q dbg_wen "$2_dbg.v" || { echo "the netlist has no register named wen: the exposure did not apply"; exit 1; }
}

echo "max10_flash"
netlist "$src" ctrl

start prove ctrl_dbg.v bmc   40 ''        safety
start prove ctrl_dbg.v cover 40 '-DCOVER' cover

# Mutants of the VHDL: each defect must make the safety proof fail.
export MUT_DEPTH=40
start_mutant write_without_enable   "s/accept := wen = '1';/accept := true;/"
start_mutant erase_without_enable   "s/accept := wen = '1' and permit;/accept := permit;/"
start_mutant erase_allowed_ignored  "s/ and erase_allowed(k - 1) = '1'//"
start_mutant sector_below_allowed   "s/if sec = k and/if sec <= k and/"
start_mutant sector_above_allowed   "s/if sec = k and/if sec >= k and/"
start_mutant page_erase_requested   "s/CTRL_ENABLE(31 downto 23) \& sector_q \& PAGE_NOT_SET/CTRL_ENABLE(31 downto 23) \& sector_q \& x\"00000\"/"
start_mutant refusal_enables        "s/                            err <= '1';\$/                            err <= '1'; wen <= '1';/"
start_mutant disable_keeps_enable   "s/ctrl_q <= CTRL_DISABLE;\$/ctrl_q <= CTRL_ENABLE;/"
start_mutant enable_unprotects_none "s/ctrl_q <= CTRL_ENABLE;\$/ctrl_q <= CTRL_DISABLE;/"
wait

expect "write guard, erase guard, control words and enable latch (bounded, 40 clocks)" PASS safety
expect "cover: a write, an erase, an enable and a refusal are reachable" PASS cover
for m in write_without_enable erase_without_enable erase_allowed_ignored sector_below_allowed sector_above_allowed \
  page_erase_requested refusal_enables disable_keeps_enable enable_unprotects_none; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal max10_flash: all expectations met" || { echo "formal max10_flash: FAILED (logs in build/formal_max10_flash)"; exit 1; }
