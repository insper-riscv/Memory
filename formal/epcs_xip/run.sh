#!/usr/bin/env bash
# Formal verification of the direct read adapter of the serial flash with SymbiYosys (see docs/pt-br/formal/formal.md).
# Needs ghdl, yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run
# from the root of the repository:  bash formal/epcs_xip/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The window is 64 bytes from byte 128 of the chip and
# the SPI clock runs at half the system clock; the logic does not depend on the sizes. The properties are on the SPI pins
# only: the instruction, address and length of every frame the adapter sends and the data it returns (see props.sv).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=epcs_xip
src="$root/src/ROM/SoC/epcs_xip.vhd"
spi_src="$root/src/ROM/SoC/epcs_spi.vhd"
props="$root/formal/epcs_xip/props.sv"
out="$root/build/formal_epcs_xip"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name> [fast_read]: the netlist of the adapter and the SPI master; the file replaces the adapter
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$root/src/common/src/utils_pkg.vhd" "$root/src/common/src/config_pkg.vhd" \
    "$spi_src" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gwindow_bytes=64 -gchip_offset=128 -gclk_div=1 \
    -ggap_ticks=1 -gfast_read="${3:-false}" epcs_xip > "$2.v"
}

# mutant_run <name> <sed expression>: as in formal/common.sh, with the scenario and depth the mutant needs.
mutant_run() {
  sed "$2" "$src" > "$out/mut_$1.vhd"
  if cmp -s "$src" "$out/mut_$1.vhd"; then
    echo "ERROR the edit of the mutant did not change the file" > "$out/mut_$1.res"
    return
  fi
  netlist "$out/mut_$1.vhd" "mut_$1"
  prove "mut_$1.v" bmc "${MUT_DEPTH:-170}" "${MUT_DEFS:-}" "mut_$1"
}

echo "epcs_xip"
netlist "$src" xip
netlist "$src" fast true

# One proof per scenario (see props.sv): the word and the line, each deep enough to reach the end of its frame.
export FORMAL_TIMEOUT="${FORMAL_TIMEOUT:-1500}"
start prove xip.v  bmc   170 '-DSC_WORD'                 safety_word
start prove xip.v  bmc   380 '-DSC_LINE'                 safety_line
start prove fast.v bmc   190 '-DSC_WORD -DFAST'          safety_fast
start prove xip.v  cover 170 '-DSC_WORD -DCOVER'         cover_word
start prove xip.v  cover 380 '-DSC_LINE -DCOVER'         cover_line

# Mutants of the VHDL: each defect must make the safety proof of its scenario fail.
mutant() {  # <scenario> <depth> <name> <sed>
  MUT_DEFS="-DSC_$1" MUT_DEPTH="$2" start_mutant "$3" "$4"
}
mutant WORD 170 write_instruction   "s/spi_op   <= OP_FAST_READ when fast_read else OP_READ;/spi_op <= \"110\";/"
mutant WORD 170 offset_ignored      "s/to_unsigned(chip_offset, 24) + resize/resize/"
mutant WORD 170 word_unaligned      "s/rd_addr := unsigned(i_addr(31 downto 2)) \& \"00\";/rd_addr := unsigned(i_addr);/"
mutant LINE 380 line_unaligned      "s/rd_addr := unsigned(i_addr(31 downto 4)) \& \"0000\";/rd_addr := unsigned(i_addr);/"
mutant WORD 170 word_length_wrong   "s/to_unsigned(4, 9)/to_unsigned(8, 9)/"
mutant LINE 380 line_length_wrong   "s/to_unsigned(16, 9)/to_unsigned(12, 9)/"
mutant WORD 170 window_ignored      "s/if rd_outw = '1' then/if false then/"
mutant WORD 170 bytes_swapped       "s/line_q(8 \* i + 7 downto 8 \* i) <= rx_data;/line_q(8 * (4 * (i \/ 4) + 3 - i mod 4) + 7 downto 8 * (4 * (i \/ 4) + 3 - i mod 4)) <= rx_data;/"
mutant WORD 170 ready_before_frame  "s/if spi_done = '1' then/if rx_v = '1' then/"
mutant WORD 170 ready_not_held      "s/if i_advance = '1' then/if true then/"
wait

for sc in word line; do
  expect "scenario $sc: instruction, address, frame length, data and window (bounded)" PASS "safety_$sc"
  expect "scenario $sc: cover" PASS "cover_$sc"
done
expect "scenario word with FAST_READ: instruction, dummy byte, address, data (bounded)" PASS safety_fast
for m in write_instruction offset_ignored word_unaligned line_unaligned word_length_wrong line_length_wrong \
  window_ignored bytes_swapped ready_before_frame ready_not_held; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal epcs_xip: all expectations met" || { echo "formal epcs_xip: FAILED (logs in build/formal_epcs_xip)"; exit 1; }
