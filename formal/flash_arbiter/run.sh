#!/usr/bin/env bash
# Formal verification of the flash arbiter with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl, yosys,
# sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from the
# root of the repository:  bash formal/flash_arbiter/run.sh
# The proofs run side by side (see formal/common.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=flash_arbiter
src="$root/src/cache/SoC/flash_arbiter.vhd"
props="$root/formal/flash_arbiter/props.sv"
out="$root/build/formal_flash_arbiter"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>: the netlist and a copy that exposes the owner and the last served master
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog flash_arbiter > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" owner:1 last_a
  grep -q dbg_owner "$2_dbg.v" || { echo "the netlist has no register named owner: the exposure did not apply"; exit 1; }
}

echo "flash_arbiter"
netlist "$src" arb

# The longest proofs start first.
start prove arb_dbg.v bmc   40 "-DFAIRNESS -DN=${N:-6}" wait
start prove arb_dbg.v bmc   40 "-DFAIRNESS -DN=${N_TIGHT:-5}" wait_tight
start prove arb_dbg.v prove 8  ''                     safety
start prove arb_dbg.v cover 30 '-DCOVER'               cover

# Mutants of the VHDL: each defect must make a proof fail.
export MUT_DEPTH=40 MUT_DEFS='-DFAIRNESS'
start_mutant a_always_first   "s/if i_a_rden = '1' and (i_b_rden = '0' or last_a = '0') then/if i_a_rden = '1' then/"
start_mutant ready_to_both    "s/o_b_ready   <= i_ready when owner = O_B else '0';/o_b_ready   <= i_ready;/"
start_mutant b_release_wrong "s/if i_b_advance = '1' and i_ready = '1' then/if i_a_advance = '1' and i_ready = '1' then/"
start_mutant owner_b_gets_a   "s/o_addr    <= i_a_addr    when owner = O_A else i_b_addr;/o_addr    <= i_a_addr;/"
start_mutant data_swapped     "s/o_b_rdata   <= i_rdata;/o_b_rdata   <= not i_rdata;/"
start_mutant rden_without_owner "s/i_b_rden    when owner = O_B else '0';/i_b_rden;/"
wait

expect "safety, unbounded (k-induction)"                    PASS safety
expect "cover: every situation is reachable"                 PASS cover
expect "a request is answered within N clocks (depth 40)"    PASS wait
expect "N - 1 clocks are not enough (the bound is tight)"    FAIL wait_tight
for m in a_always_first ready_to_both b_release_wrong owner_b_gets_a data_swapped rden_without_owner; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal flash_arbiter: all expectations met" || { echo "formal flash_arbiter: FAILED (logs in build/formal_flash_arbiter)"; exit 1; }
