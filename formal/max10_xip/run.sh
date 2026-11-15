#!/usr/bin/env bash
# Formal verification of the direct read adapter of the MAX 10 flash with SymbiYosys (see docs/pt-br/formal/formal.md).
# Needs ghdl, yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run
# from the root of the repository:  bash formal/max10_xip/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The window is 64 bytes from word 8 of a data space
# of 6 address bits. The environment is free (request, wait, read data valid and read data), so the proof covers any
# behaviour of the megafunction.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=max10_xip
src="$root/src/ROM/SoC/max10_xip.vhd"
props="$root/formal/max10_xip/props.sv"
out="$root/build/formal_max10_xip"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>: the netlist
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$root/src/common/src/utils_pkg.vhd" "$root/src/common/src/config_pkg.vhd" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gdata_addr_bits=6 -gwindow_bytes=64 -gbase_word=8 \
    max10_xip > "$2.v"
}

# mutant_run <name> <sed expression>: as in formal/common.sh, with the scenario and depth the mutant needs.
mutant_run() {
  sed "$2" "$src" > "$out/mut_$1.vhd"
  if cmp -s "$src" "$out/mut_$1.vhd"; then
    echo "ERROR the edit of the mutant did not change the file" > "$out/mut_$1.res"
    return
  fi
  netlist "$out/mut_$1.vhd" "mut_$1"
  prove "mut_$1.v" bmc "${MUT_DEPTH:-40}" "${MUT_DEFS:-}" "mut_$1"
}

echo "max10_xip"
netlist "$src" xip

start prove xip.v bmc   30 '-DSC_WORD'         safety_word
start prove xip.v bmc   30 '-DSC_LINE'         safety_line
start prove xip.v cover 30 '-DSC_WORD -DCOVER' cover_word
start prove xip.v cover 30 '-DSC_LINE -DCOVER' cover_line

# Mutants of the VHDL: each defect must make the safety proof of its scenario fail.
mutant() {  # <scenario> <depth> <name> <sed>
  MUT_DEFS="-DSC_$1" MUT_DEPTH="$2" start_mutant "$3" "$4"
}
mutant WORD 30 base_ignored        "s/to_unsigned(base_word, data_addr_bits) + resize/resize/"
mutant LINE 30 line_unaligned      "s/win_word := unsigned(i_addr(WINDOW_BITS - 1 downto 4)) \& \"00\";/win_word := unsigned(i_addr(WINDOW_BITS - 1 downto 2));/"
mutant LINE 30 line_of_three       "s/last_n   <= 3;/last_n   <= 2;/"
mutant LINE 30 address_not_stepped "s/addr_q <= addr_q + 1;/addr_q <= addr_q;/"
mutant WORD 30 window_ignored      "s/if rd_outw = '1' then/if false then/"
mutant LINE 30 words_swapped       "s/line_q(32 \* i + 31 downto 32 \* i) <= i_data_rdata;/line_q(32 * (3 - i) + 31 downto 32 * (3 - i)) <= i_data_rdata;/"
mutant WORD 30 read_not_held       "s/if i_data_wait = '0' then/if true then/"
mutant LINE 30 ready_early         "s/if word_n = last_n then/if word_n = last_n or word_n = 1 then/"
mutant WORD 30 ready_not_held      "s/if i_advance = '1' then/if true then/"
wait

for sc in word line; do
  expect "scenario $sc: address, order, hold, window and data (bounded)" PASS "safety_$sc"
  expect "scenario $sc: cover" PASS "cover_$sc"
done
for m in base_ignored line_unaligned line_of_three address_not_stepped window_ignored words_swapped read_not_held \
  ready_early ready_not_held; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal max10_xip: all expectations met" || { echo "formal max10_xip: FAILED (logs in build/formal_max10_xip)"; exit 1; }
