#!/usr/bin/env bash
# Formal verification of the NOR FLASH controller with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl,
# yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from the
# root of the repository:  bash formal/nor_flash_ctrl/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The chip is 8 KB with two sectors of 4 KB and
# pages of 8 bytes: the logic does not depend on the sizes. Configuration A has one clock in each read and write phase
# (every chip time equal to the clock period); configuration B (-DCFG_B) has different phases (3, 2, 2, 3, 5, 2 and 3
# clocks), so that the proof sees the number of clocks follow the timing generics.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=nor_flash_ctrl
src="$root/src/ROM/SoC/nor_flash_ctrl.vhd"
props="$root/formal/nor_flash_ctrl/props.sv"
out="$root/build/formal_nor_flash_ctrl"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name> [A|B]: the netlist and a copy that exposes the latch, the protection, the operation, the state and RY
  local cfg="${3:-${MUT_CFG:-A}}" work="$out/work_$2" times
  mkdir -p "$work"
  if [ "$cfg" = B ]; then
    times="-gt_acc_ns=30 -gt_pacc_ns=20 -gt_wp_ns=10 -gt_ah_ns=20 -gt_ds_ns=20 -gt_wph_ns=30 -gt_wc_ns=40 -gt_busy_ns=20 -gt_rp_ns=20 -gt_rh_ns=30"
  else
    times="-gt_acc_ns=10 -gt_pacc_ns=10 -gt_wp_ns=10 -gt_ah_ns=10 -gt_ds_ns=10 -gt_wph_ns=10 -gt_wc_ns=10 -gt_busy_ns=10 -gt_rp_ns=10 -gt_rh_ns=10"
  fi
  ghdl_run -a --std=08 --workdir="$work" "$root/src/common/src/utils_pkg.vhd" "$(formal_vhdl "$root/src/common/src/synchronizer.vhd" "synchronizer_$2")" \
    "$root/src/latency/SoC/latency_counter.vhd" "$root/src/ROM/SoC/chip_timing_pkg.vhd" "$1"
  # shellcheck disable=SC2086
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gclk_period_ns=10 -gsize_bytes=8192 -gsector_bytes=4096 -gpage_bytes=8 $times nor_flash_ctrl > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" wel prot:1 is_erase st:3 ry_s
  grep -q dbg_prot "$2_dbg.v" || { echo "the netlist has no register named prot: the exposure did not apply"; exit 1; }
}

echo "nor_flash_ctrl"
netlist "$src" a A
netlist "$src" b B

# One proof per scenario (see props.sv): the reads, the erase, the program of one byte and the commands, each deep enough
# to reach the end of its operation. Configuration B has no program scenario (too deep).
export FORMAL_TIMEOUT="${FORMAL_TIMEOUT:-1500}"
# The bitwuzla engine does not close two of the bounded proofs within FORMAL_TIMEOUT (the program scenario of
# configuration A, depth 80, and the read scenario of configuration B, depth 60), so it skips exactly these tags, as
# abc-bmc3 skips what it does not do. yices closes both (773 s and 62 s), and formal/aggregate.sh still demands an
# answer from some engine for each of them.
bitwuzla_slow=" safety_a_program safety_b_read "
start prove a_dbg.v bmc   80 '-DSC_PROGRAM'                  safety_a_program
start prove a_dbg.v cover 80 '-DSC_PROGRAM -DCOVER'          cover_a_program
start prove a_dbg.v bmc   50 '-DSC_ERASE'                    safety_a_erase
start prove a_dbg.v cover 50 '-DSC_ERASE -DCOVER'            cover_a_erase
start prove a_dbg.v bmc   48 '-DSC_READ'                     safety_a_read
start prove a_dbg.v cover 48 '-DSC_READ -DCOVER'             cover_a_read
start prove a_dbg.v bmc   26 '-DSC_CMD'                      safety_a_cmd
start prove a_dbg.v cover 26 '-DSC_CMD -DCOVER'              cover_a_cmd
start prove b_dbg.v bmc   60 '-DCFG_B -DSC_ERASE'            safety_b_erase
start prove b_dbg.v cover 60 '-DCFG_B -DSC_ERASE -DCOVER'    cover_b_erase
start prove b_dbg.v bmc   60 '-DCFG_B -DSC_READ'             safety_b_read
start prove b_dbg.v cover 60 '-DCFG_B -DSC_READ -DCOVER'     cover_b_read
start prove b_dbg.v bmc   26 '-DCFG_B -DSC_CMD'              safety_b_cmd

# Mutants of the VHDL: each defect must make the safety proof of its scenario fail. Those of the chip commands, of the
# protocol and of the data run in configuration A; those of the number of clocks of a phase run in configuration B.
mutant() {  # <cfg> <scenario> <depth> <name> <sed>
  MUT_CFG="$1" MUT_DEFS="$([ "$1" = B ] && echo -DCFG_B) -DSC_$2" MUT_DEPTH="$3" start_mutant "$4" "$5"
}
mutant A ERASE   50 unlock_wrong       "s/addr_o := UNLOCK_B;/addr_o := UNLOCK_A;/"
mutant A PROGRAM 80 program_cmd_wrong  "s/data_o := x\"A0\";/data_o := x\"A1\";/"
mutant A ERASE   50 erase_cmd_wrong    "s/data_o := x\"80\";/data_o := x\"81\";/"
mutant A ERASE   50 sector_cmd_wrong   "s/data_o := x\"30\";/data_o := x\"31\";/"
mutant A ERASE   50 sector_unaligned   "s/sec_off := off(WINDOW_BITS - 1 downto SECTOR_BITS) \& (SECTOR_BITS - 1 downto 0 => '0');/sec_off := off;/"
mutant A PROGRAM 80 ff_not_skipped     "s/if byte_dat = x\"FF\" then/if byte_dat = x\"FE\" then/"
mutant A CMD     26 window_ignored     "s/if cmd_out or prot(sec) = '1' then/if prot(sec) = '1' then/"
mutant A CMD     26 protection_ignored "s/if cmd_out or prot(sec) = '1' then/if cmd_out then/"
mutant A CMD     26 latch_ignored      "s/(i_cmd_op = CMD_ERASE or i_cmd_op = CMD_PROGRAM) and wel = '1' then/(i_cmd_op = CMD_ERASE or i_cmd_op = CMD_PROGRAM) then/"
mutant A ERASE   50 ry_not_awaited     "s/if ry_s(0) = '1' then/if ry_s(0) = '1' or true then/"
mutant A CMD     26 hardware_protect   "s/o_fl_wp_n     <= '1';/o_fl_wp_n     <= '0';/"
mutant A READ    48 read_stride_two    "s/addr_q <= addr_q + 1;/addr_q <= addr_q + 2;/"
mutant A READ    48 line_unaligned     "s/rd_addr := unsigned(i_addr(31 downto 4)) \& \"0000\";/rd_addr := unsigned(i_addr);/"
mutant A ERASE   50 region_one_short   "s/last_q  <= first_a + to_unsigned(region - 1, 32);/last_q  <= first_a + to_unsigned(region - 2, 32);/"
mutant A READ    48 data_bus_in_read   "/oe_n_q  <= '0';/{n;s/dq_oe_q <= '0';/dq_oe_q <= '1';/}"
mutant A ERASE   50 oe_with_we         "s/we_n_q <= '0';/we_n_q <= '0'; oe_n_q <= '0';/"
mutant B ERASE   60 we_width_wp_only   "s/max_natural(t_wp_ns, max_natural(t_ah_ns, t_ds_ns))/t_wp_ns/"
mutant B ERASE   60 we_high_wc_only    "s/N_WH    : positive := max_natural(cycles_of(t_wph_ns, clk_period_ns, margin_ns),/N_WH    : positive := max_natural(1,/"
mutant B ERASE   60 busy_not_waited    "s/cycles_of(t_busy_ns, clk_period_ns, margin_ns) + 3/cycles_of(t_busy_ns, clk_period_ns, margin_ns)/"
mutant B READ    60 page_uses_random   "s/N_NEXT  : positive := cycles_of(t_pacc_ns/N_NEXT  : positive := cycles_of(t_acc_ns/"
mutant B READ    60 first_uses_page    "s/N_FIRST : positive := cycles_of(t_acc_ns/N_FIRST : positive := cycles_of(t_pacc_ns/"
mutant B CMD     26 reset_pulse_short  "s/N_RP    : positive := cycles_of(t_rp_ns/N_RP    : positive := cycles_of(t_rh_ns/"
wait

for sc in program erase read cmd; do
  expect "configuration A, scenario $sc: pins, phases, command sequence, data, completion, read and commands (bounded)" PASS "safety_a_$sc"
  expect "configuration A, scenario $sc: cover" PASS "cover_a_$sc"
done
for sc in erase read; do
  expect "configuration B (other phase lengths), scenario $sc: the same properties (bounded)" PASS "safety_b_$sc"
  expect "configuration B, scenario $sc: cover" PASS "cover_b_$sc"
done
expect "configuration B, scenario cmd: the same properties (bounded)" PASS safety_b_cmd
for m in unlock_wrong program_cmd_wrong erase_cmd_wrong sector_cmd_wrong sector_unaligned ff_not_skipped window_ignored protection_ignored \
  latch_ignored ry_not_awaited hardware_protect read_stride_two line_unaligned region_one_short data_bus_in_read oe_with_we \
  we_width_wp_only we_high_wc_only busy_not_waited page_uses_random first_uses_page reset_pulse_short; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal nor_flash_ctrl: all expectations met" || { echo "formal nor_flash_ctrl: FAILED (logs in build/formal_nor_flash_ctrl)"; exit 1; }
