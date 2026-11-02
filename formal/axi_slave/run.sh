#!/usr/bin/env bash
# Formal verification of axi_slave_word_bridge with SymbiYosys. Needs ghdl, yosys, sby and the z3 solver
# (insper-riscv/Infra's toolchain image). Run from the root of the repository:
#   bash formal/axi_slave/run.sh
# The proofs run side by side (see formal/common.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$root/external/axi/axi_slave_word_bridge.vhd"
props="$root/formal/axi_slave/props.sv"
out="$root/build/formal_axi_slave"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl -a --std=08 --workdir="$work" "$1"
  ghdl --synth --std=08 --workdir="$work" --out=verilog axi_slave_word_bridge > "$2.v"
  # a copy that exposes the state registers the invariants need (the logic is the same)
  sed -e 's/input  \[95:0\] i_rdata_x);/input  [95:0] i_rdata_x,\n  output [2:0] dbg_st, output dbg_we, output dbg_bad, output dbg_fast, output [1:0] dbg_k, output [7:0] dbg_left);/' \
      -e 's/^endmodule/  assign dbg_st = st;\n  assign dbg_we = we_l;\n  assign dbg_bad = bad_l;\n  assign dbg_fast = fast_l;\n  assign dbg_k = k;\n  assign dbg_left = left_l;\nendmodule/' \
      "$2.v" > "$2_dbg.v"
  grep -q dbg_st "$2_dbg.v" || { echo "the netlist has no register named st: the exposure did not apply"; exit 1; }
}

echo "axi_slave_word_bridge"
netlist "$src" bridge

# The longest proofs start first.
start prove bridge_dbg.v bmc   55 ''                       safety
start prove bridge_dbg.v bmc   50 "-DFAIRNESS -DW=${W:-40}" live
start prove bridge_dbg.v cover 40 '-DCOVER'                 cover

# Mutants of the VHDL: each defect must make the safety proof fail.
start_mutant read_over_write "s/ and i_s_awvalid = '0' else '0';/ else '0';/"
start_mutant aw_twice       "s/awr <= '1' when st = ST_IDLE else '0';/awr <= '1';/"
start_mutant rlast_early    "s/(fast_l = '1' and k = 3) or (fast_l = '0' and left_l = 0)) else '0'/(fast_l = '1' and k = 2) or (fast_l = '0' and left_l = 0)) else '0'/"
start_mutant serves_unaligned "s/ or a(1 downto 0) \\/= \"00\" then/ then/"
start_mutant no_wait_resp   "s/            if i_s_bready = '1' then/            if true then/"
start_mutant advance_early  "s/if i_ready = '1' then/if true then/"
wait

expect "safety, 55 clocks from reset"             PASS safety
expect "cover: every situation is reachable"       PASS cover
expect "an access is done within W clocks"         PASS live
for m in read_over_write aw_twice rlast_early serves_unaligned no_wait_resp advance_early; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal axi: all expectations met" || { echo "formal axi: FAILED (logs in build/formal_axi_slave)"; exit 1; }
