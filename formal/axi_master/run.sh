#!/usr/bin/env bash
# Formal verification of axi_master_bridge with SymbiYosys. Needs ghdl, yosys, sby and the z3 solver
# (insper-riscv/Infra's toolchain image). Run from the root of the repository:
#   bash formal/axi_master/run.sh
# The proofs run side by side (see formal/common.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$root/external/axi/axi_master_bridge.vhd"
props="$root/formal/axi_master/props.sv"
out="$root/build/formal_axi"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl -a --std=08 --workdir="$work" "$1"
  ghdl --synth --std=08 --workdir="$work" --out=verilog axi_master_bridge > "$2.v"
  # a copy that exposes the state registers the invariants need (the logic is the same)
  sed -e 's/input  i_m_rlast);/input  i_m_rlast,\n  output [1:0] dbg_st, output dbg_awv, output dbg_wv, output dbg_arv, output dbg_we, output [1:0] dbg_beat, output [1:0] dbg_last, output [95:0] dbg_wdx, output [11:0] dbg_bex);/' \
      -e 's/^endmodule/  assign dbg_st = st;\n  assign dbg_awv = awv;\n  assign dbg_wv = wv;\n  assign dbg_arv = arv;\n  assign dbg_we = we_l;\n  assign dbg_beat = beat;\n  assign dbg_last = last_b;\n  assign dbg_wdx = wdx_l;\n  assign dbg_bex = bex_l;\nendmodule/' \
      "$2.v" > "$2_dbg.v"
  grep -q dbg_st "$2_dbg.v" || { echo "the netlist has no register named st: the exposure did not apply"; exit 1; }
}

echo "axi_master_bridge"
netlist "$src" bridge

# The longest proof starts first.
start prove bridge_dbg.v bmc   40 "-DFAIRNESS -DW=${W:-20}" live
start prove bridge_dbg.v prove 20 ''                       safety
start prove bridge_dbg.v cover 40 '-DCOVER'                 cover

# Mutants of the VHDL: each defect must make the safety proof fail.
start_mutant no_wait_aw   "s/o_m_bready  <= '1' when st = ST_WR and awv = '0' and wv = '0' else '0';/o_m_bready  <= '1' when st = ST_WR else '0';/"
start_mutant strb_wrong   "s/strb_l  <= i_byteena;/strb_l  <= \"1111\";/"
start_mutant drop_w       "s/if wv = '1' and i_m_wready = '1' then/if wv = '1' then/"
start_mutant ready_pulse  "s/if i_mem_advance = '1' then/if true then/"
start_mutant wlast_always "s/o_m_wlast   <= '1' when beat = last_b else '0';/o_m_wlast <= '1';/"
start_mutant arlen_wrong  "s/o_m_arlen   <= \"00000011\" when last_b = 3 else \"00000000\";/o_m_arlen <= \"00000001\" when last_b = 3 else \"00000000\";/"
wait

expect "safety, unbounded (k-induction)"          PASS safety
expect "cover: every situation is reachable"       PASS cover
expect "an access is done within W clocks"         PASS live
for m in no_wait_aw strb_wrong drop_w ready_pulse wlast_always arlen_wrong; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal axi: all expectations met" || { echo "formal axi: FAILED (logs in build/formal_axi)"; exit 1; }
