#!/usr/bin/env bash
# Formal verification of the SDRAM CPU bridge with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl,
# yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from
# the root of the repository:  bash formal/sdram_cpu_bridge/run.sh
# The proofs run side by side (see formal/common.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=sdram_cpu_bridge
src="$root/src/RAM/SoC/sdram/sdram_cpu_bridge.vhd"
props="$root/formal/sdram_cpu_bridge/props.sv"
out="$root/build/formal_sdram_cpu_bridge"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>: the netlist and a copy that exposes the state, the synchronizer outputs and the request toggle
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$(formal_vhdl "$root/src/common/src/synchronizer.vhd" "synchronizer_$2")" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog sdram_cpu_bridge > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" st:1 ack_sync init_sync req_i
  grep -q dbg_st "$2_dbg.v" || { echo "the netlist has no register named st: the exposure did not apply"; exit 1; }
}

echo "sdram_cpu_bridge"
netlist "$src" bridge

start prove bridge_dbg.v bmc   30 ''          safety
start prove bridge_dbg.v cover 40 '-DCOVER'   cover

# Mutants of the VHDL: each defect must make the safety proof fail.
export MUT_DEPTH=30
start_mutant wrong_rdata     "s/pending   <= i_c_rdata;/pending   <= i_wdata;/"
start_mutant rdata_x_zero    "s/pending_x <= i_c_rdata_x;/pending_x <= (others => '0');/"
start_mutant init_ignored    "s/ and init_sync(0) = '1' then/ then/"
start_mutant ack_unsynced    "s/if ack_sync(0) = req_i then/if i_ack_tog = req_i then/"
start_mutant no_advance_wait "s/            if i_mem_advance = '1' then/            if true then/"
start_mutant write_as_read   "s/we_l    <= i_wren;/we_l    <= '0';/"
start_mutant address_shifted "s/o_c_addr  <= i_addr(addr_bits + 1 downto 2);/o_c_addr  <= i_addr(addr_bits downto 1);/"
start_mutant request_lost    "s/req_i   <= not req_i;/req_i   <= req_i;/"
start_mutant write_updates_rdata "s/if we_l = '0' then/if true then/"
wait

expect "safety, bounded (30 clocks)"               PASS safety
expect "cover: every situation is reachable"        PASS cover
for m in wrong_rdata rdata_x_zero init_ignored ack_unsynced no_advance_wait write_as_read address_shifted request_lost write_updates_rdata; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal sdram_cpu_bridge: all expectations met" || { echo "formal sdram_cpu_bridge: FAILED (logs in build/formal_sdram_cpu_bridge)"; exit 1; }
