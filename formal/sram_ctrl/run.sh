#!/usr/bin/env bash
# Formal verification of the asynchronous SRAM controller with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl,
# yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from the
# root of the repository:  bash formal/sram_ctrl/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The chip is 64 bytes: the logic does not depend on
# the size. Configuration A has one clock in each read and write phase (every chip time equal to the clock period);
# configuration B (-DCFG_B) has three clocks in each phase, so that the proof sees the number of clocks follow the
# timing generics. Each configuration has a read scenario and a write scenario (see props.sv).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=sram_ctrl
src="$root/src/RAM/SoC/sram_ctrl.vhd"
props="$root/formal/sram_ctrl/props.sv"
out="$root/build/formal_sram_ctrl"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name> [A|B]: the netlist and a copy that exposes the state
  local cfg="${3:-${MUT_CFG:-A}}" work="$out/work_$2" times
  mkdir -p "$work"
  if [ "$cfg" = B ]; then
    times="-gt_aa_ns=30 -gt_rc_ns=20 -gt_wc_ns=70 -gt_sce_ns=20 -gt_aw_ns=20 -gt_pwe_ns=30 -gt_sd_ns=20 -gt_ha_ns=20 -gt_hd_ns=0"
  else
    times="-gt_aa_ns=10 -gt_rc_ns=10 -gt_wc_ns=10 -gt_sce_ns=10 -gt_aw_ns=10 -gt_pwe_ns=10 -gt_sd_ns=10 -gt_ha_ns=10 -gt_hd_ns=0"
  fi
  ghdl_run -a --std=08 --workdir="$work" "$root/src/common/src/utils_pkg.vhd" "$root/src/common/src/config_pkg.vhd" "$root/src/latency/SoC/latency_counter.vhd" \
    "$root/src/ROM/SoC/chip_timing_pkg.vhd" "$root/src/RAM/SoC/ram_pkg.vhd" "$1"
  # shellcheck disable=SC2086
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gclk_period_ns=10 -gsize_bytes=64 $times sram_ctrl > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" st:2
  grep -q dbg_st "$2_dbg.v" || { echo "the netlist has no register named st: the exposure did not apply"; exit 1; }
}

echo "sram_ctrl"
netlist "$src" a A
netlist "$src" b B

export FORMAL_TIMEOUT="${FORMAL_TIMEOUT:-1500}"
start prove a_dbg.v bmc   44 '-DSC_WRITE'                  safety_a_write
start prove a_dbg.v cover 44 '-DSC_WRITE -DCOVER'          cover_a_write
start prove a_dbg.v bmc   24 '-DSC_READ'                   safety_a_read
start prove a_dbg.v cover 24 '-DSC_READ -DCOVER'           cover_a_read
start prove b_dbg.v bmc   34 '-DCFG_B -DSC_WRITE'          safety_b_write
start prove b_dbg.v cover 34 '-DCFG_B -DSC_WRITE -DCOVER'  cover_b_write
start prove b_dbg.v bmc   40 '-DCFG_B -DSC_READ'           safety_b_read
start prove b_dbg.v cover 40 '-DCFG_B -DSC_READ -DCOVER'   cover_b_read

# Mutants of the VHDL: each defect must make the safety proof of its scenario fail.
mutant() {  # <cfg> <scenario> <depth> <name> <sed>
  MUT_CFG="$1" MUT_DEFS="$([ "$1" = B ] && echo -DCFG_B) -DSC_$2" MUT_DEPTH="$3" start_mutant "$4" "$5"
}
mutant A WRITE 44 lanes_swapped     "s/lb_n_q  <= not be_q(2 \* half_n);/lb_n_q  <= not be_q(2 * half_n + 1);/"
mutant A WRITE 44 empty_half_written "s/elsif be_q(2 \* half_n + 1 downto 2 \* half_n) = \"00\" then/elsif be_q(2 * half_n + 1 downto 2 * half_n) = \"11\" then/"
mutant A WRITE 44 stride_two        "s/addr_q <= addr_q + 1;/addr_q <= addr_q + 2;/"
mutant A READ  24 data_early        "s/o_rdata      <= rdata_q(31 downto 0);/o_rdata      <= pend_q(31 downto 0);/"
mutant A READ  24 window_ignored    "s/if acc_outw = '1' then/if false then/"
mutant A READ  24 data_bus_in_read  "/ub_n_q  <= '0';/{n;s/dq_oe_q <= '0';/dq_oe_q <= '1';/}"
mutant A WRITE 44 oe_with_we        "s/we_n_q <= '0';/we_n_q <= '0'; oe_n_q <= '0';/"
mutant B WRITE 34 we_pulse_dropped  "s/N_WL[[:space:]]*: positive := max_natural(cycles_of(t_pwe_ns, clk_period_ns, margin_ns),/N_WL : positive := max_natural(1,/"
mutant B WRITE 34 we_high_wc_dropped "s/max_natural(cycles_of(t_wc_ns, clk_period_ns, margin_ns), N_WL + 2) - N_WL - 1/1/"
mutant B READ  40 read_wait_rc_only "s/cycles_of(max_natural(t_aa_ns, t_rc_ns), clk_period_ns, margin_ns)/cycles_of(t_rc_ns, clk_period_ns, margin_ns)/"
wait

for sc in write read; do
  expect "configuration A, scenario $sc: pins, bytes, phases, data and contract (bounded)" PASS "safety_a_$sc"
  expect "configuration A, scenario $sc: cover" PASS "cover_a_$sc"
  expect "configuration B (three clocks per phase), scenario $sc: the same properties (bounded)" PASS "safety_b_$sc"
  expect "configuration B, scenario $sc: cover" PASS "cover_b_$sc"
done
for m in lanes_swapped empty_half_written stride_two data_early window_ignored data_bus_in_read oe_with_we we_pulse_dropped \
  we_high_wc_dropped read_wait_rc_only; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal sram_ctrl: all expectations met" || { echo "formal sram_ctrl: FAILED (logs in build/formal_sram_ctrl)"; exit 1; }
