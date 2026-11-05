#!/usr/bin/env bash
# Formal verification of the SDRAM controller with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl, yosys,
# sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from the root
# of the repository:  bash formal/sdram_ctrl/run.sh
# The proofs are bounded (the initialization alone takes about a hundred clocks) and run side by side (see
# formal/common.sh).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=sdram_ctrl
src="$root/src/RAM/SoC/sdram/sdram_ctrl.vhd"
props="$root/formal/sdram_ctrl/props.sv"
out="$root/build/formal_sdram_ctrl"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

# The wait of 200 us and the refresh period shrink to INIT and REFC clocks; the chip timings stay the project's.
netlist() {  # <vhdl> <name>
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$root/src/RAM/SoC/sdram/sdram_pkg.vhd" "$(formal_vhdl "$root/src/common/src/synchronizer.vhd" "synchronizer_$2")" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -ginit_cycles=6 -grefresh_cycles=24 sdram_ctrl > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v"
}

echo "sdram_ctrl"
netlist "$src" ctrl

# The longest proofs start first.
start prove ctrl_dbg.v bmc   150 ''        safety
start prove ctrl_dbg.v cover 150 '-DCOVER' cover

# Mutants of the VHDL: each defect must make the safety proof fail.
export MUT_DEPTH=150
start_mutant no_precharge     "s/st <= ST_INIT_PRE;/st <= ST_INIT_REF;/"
start_mutant few_refreshes    "s/if init_ref = INIT_REFRESHES - 1 then/if init_ref = 1 then/"
start_mutant init_wait_short  "s/wcnt     <= init_cycles;/wcnt     <= 1;/"
start_mutant mode_wrong       "s/o_dram_addr <= MODE_REG;/o_dram_addr <= (others => '0');/"
start_mutant init_done_early  "s/when ST_INIT_PRE =>/when ST_INIT_PRE =>\n            init_i <= '1';/"
start_mutant trcd_short       "s/goto_after(C_RCD, ST_RW);/goto_after(1, ST_RW);/"
start_mutant trp_short        "s/goto_after(C_RP, ST_INIT_REF);/goto_after(1, ST_INIT_REF);/"
start_mutant trfc_short       "s/act_cnt <= C_RFC;/act_cnt <= 0;/;s/goto_after(C_RFC, ST_IDLE);/goto_after(2, ST_IDLE);/"
start_mutant trc_short        "s/act_cnt <= ACT_TO_ACT;/act_cnt <= 1;/"
start_mutant refresh_never    "s/ref_due <= '1';/ref_due <= '0';/"
wait

expect "init sequence, chip timings, refresh period and answers (bounded, 150 clocks)" PASS safety
expect "cover: init, refresh, word and line reads and writes are reachable"            PASS cover
for m in no_precharge few_refreshes init_wait_short mode_wrong init_done_early trcd_short trp_short trfc_short trc_short refresh_never; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal sdram_ctrl: all expectations met" || { echo "formal sdram_ctrl: FAILED (logs in build/formal_sdram_ctrl)"; exit 1; }
