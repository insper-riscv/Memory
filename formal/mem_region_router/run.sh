#!/usr/bin/env bash
# Formal verification of the memory region router with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl,
# yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from
# the root of the repository:  bash formal/mem_region_router/run.sh
# The proofs run side by side (see formal/common.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=mem_region_router
src="$root/src/cache/SoC/mem_region_router.vhd"
props="$root/formal/mem_region_router/props.sv"
out="$root/build/formal_mem_region_router"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>: the netlist and a copy that exposes the register of the local answer
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl -a --std=08 -Wno-library --workdir="$work" "$1"
  ghdl --synth --std=08 -Wno-library --workdir="$work" --out=verilog mem_region_router > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" local_ready
  grep -q dbg_local_ready "$2_dbg.v" || { echo "the netlist has no register named local_ready: the exposure did not apply"; exit 1; }
}

echo "mem_region_router"
netlist "$src" router

start prove router_dbg.v prove 6  '' safety
start prove router_dbg.v cover 12 '-DCOVER' cover

# Mutants of the VHDL: each defect must make the safety proof fail.
export MUT_DEPTH=12
start_mutant end_inclusive    "s/unsigned(i_addr) < shift_left(to_unsigned(rom_end_kib, 32), 10)/unsigned(i_addr) <= shift_left(to_unsigned(rom_end_kib, 32), 10)/"
start_mutant write_not_local  "s/is_local <= is_flash and (i_wren or (i_rden and beyond));/is_local <= is_flash and (i_rden and beyond);/"
start_mutant slave_sees_flash "s/o_s_rden    <= i_rden and not is_flash;/o_s_rden    <= i_rden;/"
start_mutant local_not_zero   "s/o_rdata <= (others => '0') when is_local = '1' else/o_rdata <= i_f_rdata when is_local = '1' else/"
start_mutant local_hangs      "s/elsif is_local = '1' then/elsif false then/"
start_mutant flash_gets_local "s/o_f_rden    <= i_rden and is_flash and not is_local;/o_f_rden    <= i_rden and is_flash;/"
start_mutant window_by_base   "s/rom_base_kib + rom_window_kib/rom_base_kib/"
start_mutant advance_to_both  "s/o_s_advance <= i_advance and not is_flash;/o_s_advance <= i_advance;/"
wait

expect "safety, unbounded (k-induction)"          PASS safety
expect "cover: every situation is reachable"       PASS cover
for m in end_inclusive write_not_local slave_sees_flash local_not_zero local_hangs flash_gets_local window_by_base advance_to_both; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal mem_region_router: all expectations met" || { echo "formal mem_region_router: FAILED (logs in build/formal_mem_region_router)"; exit 1; }
