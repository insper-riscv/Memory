#!/usr/bin/env bash
# Formal verification of the data cache in write-through mode with SymbiYosys (see docs/pt-br/formal/formal.md).
# Needs ghdl, yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain
# image. Run from the root of the repository:  bash formal/dcache/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The cache is two lines of 128 bits
# (size_bits = 256): the logic does not depend on the size.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=dcache
src="$root/src/cache/SoC/dcache.vhd"
props="$root/formal/dcache/props.sv"
out="$root/build/formal_dcache"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>: the netlist and a copy that exposes the valid bits and the invalidation flag
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl -a --std=08 -Wno-library --workdir="$work" "$root/src/common/src/utils_pkg.vhd" "$1"
  ghdl --synth --std=08 -Wno-library --workdir="$work" --out=verilog -gsize_bits=256 -gwrite_through=true dcache > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" valid:1 inv_run
  grep -q dbg_valid "$2_dbg.v" || { echo "the netlist has no register named valid: the exposure did not apply"; exit 1; }
}

echo "dcache"
netlist "$src" dc

start prove dc_dbg.v bmc   24 '-DDATA'        stores
start prove dc_dbg.v bmc   40 '-DINV'         invalidate
start prove dc_dbg.v cover 24 '-DDATA -DCOVER' cover
start prove dc_dbg.v cover 40 '-DINV -DCOVER'  cover_inv

# Mutants of the VHDL: each defect must make a proof fail.
export MUT_DEPTH=24 MUT_DEFS='-DDATA'
start_mutant hit_store_not_cached "s/ram_we <= '1' when (st = S_LOOK and hit = '1' and i_wren = '1' and in_rom(i_addr) = '0' and i_bypass = '0') or st = S_FILL_GET else '0';/ram_we <= '1' when st = S_FILL_GET else '0';/"
start_mutant write_back_on_hit    "s/elsif (write_through or in_rom(i_addr) = '1' or i_bypass = '1') and i_wren = '1' then/elsif (in_rom(i_addr) = '1' or i_bypass = '1') and i_wren = '1' then/"
start_mutant byteena_lost         "s/d_be_i    <= i_byteena;/d_be_i    <= \"1111\";/"
start_mutant fill_word_swapped    "s/i_d_rdata_x(31 downto 0)  when cnt = \"01\" else/i_d_rdata_x(63 downto 32) when cnt = \"01\" else/"
start_mutant hit_ignores_tag      "s/hit     <= valid(to_integer(unsigned(cur_idx))) when tag_rd = req_tag else '0';/hit     <= valid(to_integer(unsigned(cur_idx)));/"
start_mutant store_acked_early    "s/            st        <= S_WT_WAIT;/            st        <= S_DONE;/"
start_mutant store_data_lost      "s/d_wdata_i <= i_wdata;/d_wdata_i <= (others => '0');/"
wait
# The invalidation mutant needs the INV mode.
export MUT_DEPTH=40 MUT_DEFS='-DINV'
mutant_run inv_keeps "/if inv_run = '1' then/{n;s/valid <= (others => '0');/null;/}"

expect "store order and data of every hit and fill (bounded, 24 clocks)" PASS stores
expect "a flush with invalidation leaves every line invalid (bounded, 40 clocks)" PASS invalidate
expect "cover: a store, a load after a fill and a load hit are reachable" PASS cover
expect "cover: a flush with invalidation is reachable" PASS cover_inv
for m in hit_store_not_cached write_back_on_hit byteena_lost fill_word_swapped hit_ignores_tag store_acked_early store_data_lost inv_keeps; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal dcache: all expectations met" || { echo "formal dcache: FAILED (logs in build/formal_dcache)"; exit 1; }
