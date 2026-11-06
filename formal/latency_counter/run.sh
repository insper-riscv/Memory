#!/usr/bin/env bash
# Formal verification of the latency counting machine with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl,
# yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from the
# root of the repository:  bash formal/latency_counter/run.sh
# The proofs run side by side (see formal/common.sh). The counter is proved with max_count 6: the logic does not
# depend on the width.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=latency_counter
src="$root/src/latency/SoC/latency_counter.vhd"
props="$root/formal/latency_counter/props.sv"
out="$root/build/formal_latency_counter"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>: the netlist and a copy that exposes the count register
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gmax_count=6 latency_counter > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" cnt:2
  grep -q dbg_cnt "$2_dbg.v" || { echo "the netlist has no register named cnt: the exposure did not apply"; exit 1; }
}

echo "latency_counter"
netlist "$src" cnt

start prove cnt_dbg.v prove 12 ''        safety
start prove cnt_dbg.v cover 30 '-DCOVER' cover

# Mutants of the VHDL: each defect must make the proof fail.
export MUT_DEPTH=12
start_mutant zero_hangs        "s/cnt <= 1;/cnt <= 0;/"
start_mutant one_too_long      "s/cnt <= i_count;/cnt <= i_count + 1;/"
start_mutant restart_ignored   "s/elsif i_load = '1' then/elsif i_load = '1' and cnt = 0 then/"
start_mutant last_never_ends   "/elsif cnt > 1 then/{n;n;n;s/cnt <= 0;/cnt <= cnt;/}"
start_mutant reset_ignored     "/i_rst = '1' then/{n;s/cnt <= 0;/null;/}"
start_mutant wait_from_zero    "s/o_wait <= '1' when cnt > 1/o_wait <= '1' when cnt > 0/"
start_mutant last_at_two       "s/o_last <= '1' when cnt = 1/o_last <= '1' when cnt = 2/"
wait

expect "end, wait and count register, unbounded (k-induction)" PASS safety
expect "cover: ends, restarts, resets and the zero count are reachable" PASS cover
for m in zero_hangs one_too_long restart_ignored last_never_ends reset_ignored wait_from_zero last_at_two; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal latency_counter: all expectations met" || { echo "formal latency_counter: FAILED (logs in build/formal_latency_counter)"; exit 1; }
