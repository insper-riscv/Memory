#!/usr/bin/env bash
# Formal verification of the EPCS user access controller with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl,
# yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from the
# root of the repository:  bash formal/epcs_ctrl/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The chip is 128 KB (two sectors of 64 KB) with the user
# region from 64 KB, and the SPI clock runs at half the system clock; the logic does not depend on the sizes. The properties
# are on the SPI pins only: the instruction, address and data of every frame the controller sends (see props.sv).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=epcs_ctrl
cmd_src="$root/src/ROM/SoC/epcs_cmd.vhd"
spi_src="$root/src/ROM/SoC/epcs_spi.vhd"
top_src="$root/src/ROM/SoC/epcs_ctrl.vhd"
src="$cmd_src"
props="$root/formal/epcs_ctrl/props.sv"
out="$root/build/formal_epcs_ctrl"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>: the netlist; the file replaces the epcs_cmd, or the epcs_spi when MUT_KIND is spi
  local work="$out/work_$2" cmd="$cmd_src" spi="$spi_src"
  mkdir -p "$work"
  if [ "${MUT_KIND:-cmd}" = spi ]; then spi="$1"; else cmd="$1"; fi
  ghdl_run -a --std=08 --workdir="$work" "$spi" "$cmd" "$top_src"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gsize_bytes=131072 -guser_base=65536 -gclk_div=1 -ggap_ticks=1 \
    epcs_ctrl > "$2.v"
}

# mutant_run <name> <sed expression>: as in formal/common.sh, but the file that is mutated is the one of MUT_KIND.
mutant_run() {
  local file="$cmd_src"
  [ "${MUT_KIND:-cmd}" = spi ] && file="$spi_src"
  sed "$2" "$file" > "$out/mut_$1.vhd"
  if cmp -s "$file" "$out/mut_$1.vhd"; then
    echo "ERROR the edit of the mutant did not change the file" > "$out/mut_$1.res"
    return
  fi
  netlist "$out/mut_$1.vhd" "mut_$1"
  prove "mut_$1.v" bmc "${MUT_DEPTH:-30}" "${MUT_DEFS:-}" "mut_$1"
}

echo "epcs_ctrl"
netlist "$cmd_src" ctrl

# One proof per scenario (see props.sv): the erase and the program, each deep enough to reach the end of its frame.
export FORMAL_TIMEOUT="${FORMAL_TIMEOUT:-1500}"
start prove ctrl.v bmc   120 '-DSC_SE'          safety_se
start prove ctrl.v cover 120 '-DSC_SE -DCOVER'  cover_se
start prove ctrl.v bmc   150 '-DSC_PP'          safety_pp
start prove ctrl.v cover 150 '-DSC_PP -DCOVER'  cover_pp

# Mutants of the VHDL: each defect must make the safety proof of its scenario fail.
mutant() {  # <kind> <scenario> <depth> <name> <sed>
  MUT_KIND="$1" MUT_DEFS="-DSC_$2" MUT_DEPTH="$3" start_mutant "$4" "$5"
}
mutant cmd SE 120 se_without_wren_frame  "s/if link_op = LINK_WREN then/if true then/"
mutant cmd SE 120 se_without_latch       "s/accept := wel = '1' and sector_a >= user_base/accept := sector_a >= user_base/"
mutant cmd SE 120 se_below_user_region   "s/sector_a >= user_base and a < size_bytes/a < size_bytes/"
mutant cmd SE 120 se_unaligned           "s/link_addr <= std_logic_vector(to_unsigned(sector_a, 24));/null;/"
mutant cmd SE 120 se_past_the_chip       "s/sector_a >= user_base and a < size_bytes/sector_a >= user_base/"
mutant cmd PP 150 pp_without_latch       "s/accept := wel = '1' and n >= 1 and n <= PAGE_BYTES/accept := n >= 1 and n <= PAGE_BYTES/"
mutant cmd PP 150 pp_below_user_region   "s/PAGE_BYTES and a >= user_base/PAGE_BYTES and a >= 0/"
mutant cmd PP 150 pp_crosses_the_page    "s/ and (a mod PAGE_BYTES) + n <= PAGE_BYTES//"
mutant cmd PP 150 pp_past_the_chip       "s/ + n <= PAGE_BYTES and a + n <= size_bytes;/ + n <= PAGE_BYTES;/"
mutant cmd PP 150 pp_empty               "s/accept := wel = '1' and n >= 1 and n <= PAGE_BYTES/accept := wel = '1' and n <= PAGE_BYTES/"
mutant spi SE 120 bulk_erase_instruction "s/constant INS_SE        : std_logic_vector(7 downto 0) := x\"D8\";/constant INS_SE        : std_logic_vector(7 downto 0) := x\"C7\";/"
mutant spi PP 150 status_write_instruction "s/constant INS_PP        : std_logic_vector(7 downto 0) := x\"02\";/constant INS_PP        : std_logic_vector(7 downto 0) := x\"01\";/"
mutant spi SE 120 address_order_swapped  "s/return a(23 downto 16);/return a(7 downto 0);/"
wait

for sc in se pp; do
  expect "scenario $sc: instructions, WREN before PP and SE, region, alignment, frame length (bounded)" PASS "safety_$sc"
  expect "scenario $sc: cover" PASS "cover_$sc"
done
for m in se_without_wren_frame se_without_latch se_below_user_region se_unaligned se_past_the_chip pp_without_latch \
  pp_below_user_region pp_crosses_the_page pp_past_the_chip pp_empty bulk_erase_instruction status_write_instruction \
  address_order_swapped; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal epcs_ctrl: all expectations met" || { echo "formal epcs_ctrl: FAILED (logs in build/formal_epcs_ctrl)"; exit 1; }
