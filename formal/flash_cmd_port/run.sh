#!/usr/bin/env bash
# Formal verification of the command port of the FLASH chip model with SymbiYosys (see docs/pt-br/formal/formal.md).
# Needs ghdl, yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image.
# Run from the root of the repository:  bash formal/flash_cmd_port/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The chip is 64 bytes, with sectors of 16 bytes
# and pages of 8 bytes: the logic does not depend on the sizes.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=flash_cmd_port
src="$root/src/cache/SoC/flash_cmd_port.vhd"
props="$root/formal/flash_cmd_port/props.sv"
out="$root/build/formal_flash_cmd_port"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>: the netlist and a copy that exposes the latch, the protection and the operation
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$root/src/common/src/utils_pkg.vhd" "$root/src/ROM/SoC/chip_timing_pkg.vhd" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gsize_bytes=64 -gsector_bytes=16 -gpage_bytes=8 \
    -gerase_latency=1 -gprogram_latency=1 flash_cmd_port > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" wel prot:3 is_erase
  grep -q dbg_prot "$2_dbg.v" || { echo "the netlist has no register named prot: the exposure did not apply"; exit 1; }
}

echo "flash_cmd_port"
netlist "$src" cmd

start prove cmd_dbg.v bmc   40 ''        safety
start prove cmd_dbg.v cover 40 '-DCOVER' cover

# Mutants of the VHDL: each defect must make the safety proof fail.
export MUT_DEPTH=40
start_mutant program_overwrites "s/wdata_q <= i_mem_data and i_buf_data;/wdata_q <= i_buf_data;/"
start_mutant erase_writes_zero  "s/wdata_q <= (others => '1');/wdata_q <= (others => '0');/"
start_mutant ignores_the_latch  "s/(i_cmd_op = CMD_ERASE or i_cmd_op = CMD_PROGRAM) and wel = '1' then/(i_cmd_op = CMD_ERASE or i_cmd_op = CMD_PROGRAM) then/"
start_mutant protection_ignored "s/if out_win or prot(sec) = '1' then/if out_win then/"
start_mutant window_ignored     "s/if out_win or prot(sec) = '1' then/if prot(sec) = '1' then/"
start_mutant latch_stays        "/inval_q <= '1';/{n;s/wel     <= '0';/null;/}"
start_mutant refusal_keeps_latch "/refused <= '1';/{n;s/wel     <= '0';/null;/}"
start_mutant short_by_one       "s/if word_n = last_n then/if word_n = last_n - 1 then/"
start_mutant stride_of_eight    "s/addr_q  <= addr_q + 4;/addr_q  <= addr_q + 8;/"
start_mutant unprotect_all      "s/prot(sec) <= '0';/prot <= (others => '0');/"
start_mutant region_one_short   "s/first_a + to_unsigned(4 \* (last_n + 1) - 1, 32)/first_a + to_unsigned(4 * (last_n + 1) - 2, 32)/"
start_mutant page_unaligned     "/base_off <= off(WINDOW_BITS - 1 downto PAGE_BITS)$/{N;s/.*/base_off <= off;/}"
wait

expect "writes, latch, protection, region and bounds (bounded, 40 clocks)" PASS safety
expect "cover: an erase, a program, a refusal, an ignored command and the pulse are reachable" PASS cover
for m in program_overwrites erase_writes_zero ignores_the_latch protection_ignored window_ignored latch_stays refusal_keeps_latch \
  short_by_one stride_of_eight unprotect_all region_one_short page_unaligned; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal flash_cmd_port: all expectations met" || { echo "formal flash_cmd_port: FAILED (logs in build/formal_flash_cmd_port)"; exit 1; }
