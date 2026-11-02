#!/usr/bin/env bash
# Formal verification of the SDRAM arbiter with SymbiYosys (see docs/FORMAL.md). Needs ghdl, yosys,
# sby and the z3 solver, all in insper-riscv/Infra's toolchain image. Run from the root of the
# repository:  bash formal/run.sh
# The proofs run side by side (see formal/common.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/external/sdram/sdram_arbiter.vhd"
props="$root/formal/sdram_arbiter/props.sv"
out="$root/build/formal"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

# netlist <vhdl> <name>: the GHDL netlist of sdram_arbiter, and a copy of it that exposes the
# registers the invariants need as outputs (the logic is the same).
netlist() {
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl -a --std=08 --workdir="$work" "$1"
  ghdl --synth --std=08 --workdir="$work" --out=verilog sdram_arbiter > "$2.v"
  sed -e 's/input  \[95:0\] i_c_rdata_x);/input  [95:0] i_c_rdata_x,\n  output dbg_st, output dbg_grant_b, output dbg_last_b, output dbg_a_tog_l, output [1:0] dbg_a_s, output dbg_grant_i, output dbg_last_i, output dbg_i_tog_l, output [1:0] dbg_i_s);/' \
      -e 's/^endmodule/  assign dbg_st = st;\n  assign dbg_grant_b = grant_b;\n  assign dbg_last_b = last_b;\n  assign dbg_a_tog_l = a_tog_l;\n  assign dbg_a_s = a_s;\n  assign dbg_grant_i = grant_i;\n  assign dbg_last_i = last_i;\n  assign dbg_i_tog_l = ins_tog_l;\n  assign dbg_i_s = ins_s;\nendmodule/' \
      "$2.v" > "$2_dbg.v"
  grep -q dbg_st "$2_dbg.v" || { echo "the netlist has no register named st: the exposure did not apply"; exit 1; }
}

echo "sdram_arbiter"
netlist "$src" arb

# The longest proofs start first.
start prove arb_dbg.v bmc   60 '-DFAIRNESS -DW=20' wait20
start prove arb_dbg.v bmc   60 '-DFAIRNESS -DW=19' wait19
start prove arb_dbg.v prove 30 ''                  safety
start prove arb_dbg.v cover 40 '-DCOVER'            cover

# Mutants of the VHDL: each defect must make the safety proof fail.
start_mutant rdata_swap   "s/a_rdata_i <= i_c_rdata;/a_rdata_i <= b_rdata_i;/"
start_mutant no_wait_ctrl "s/if i_c_ack_tog = c_req_i then/if true then/"
start_mutant rdata_swap_i "s/ins_rdata_i <= i_c_rdata;/ins_rdata_i <= b_rdata_i;/"
wait

expect "safety, unbounded (k-induction)"                    PASS safety
expect "cover: every situation is reachable"                 PASS cover
expect "a request is answered within 20 clocks (depth 60)"   PASS wait20
expect "19 clocks are not enough (the bound is tight)"       FAIL wait19
for m in rdata_swap no_wait_ctrl rdata_swap_i; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal: all expectations met" || { echo "formal: FAILED (logs in build/formal)"; exit 1; }
