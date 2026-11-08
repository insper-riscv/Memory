#!/usr/bin/env bash
# Formal verification of the data cache in write-through mode with SymbiYosys (see docs/pt-br/formal/formal.md).
# Needs ghdl, yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain
# image. Run from the root of the repository:  bash formal/dcache/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The cache is two lines of 128 bits
# (size_bits = 256): the logic does not depend on the size. The proofs run for each width of the tag window in
# FORMAL_WINDOWS (default "26 27": 64 MiB and 128 MiB); the mutants run on the default width.
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

netlist() {  # <vhdl> <name> [window_bits]: the netlist and a copy that exposes the valid bits and the invalidation flag
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$root/src/common/src/utils_pkg.vhd" "$root/src/cache/SoC/cache_pkg.vhd" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gsize_bits=256 -gwrite_through=true "-gwindow_bits=${3:-26}" dcache > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v" valid:1 inv_run
  grep -q dbg_valid "$2_dbg.v" || { echo "the netlist has no register named valid: the exposure did not apply"; exit 1; }
}

echo "dcache"
windows="${FORMAL_WINDOWS:-26 27}"
for w in $windows; do
  netlist "$src" "dc_w$w" "$w"
  start prove "dc_w${w}_dbg.v" bmc   24 "-DWINDOW=$w -DDATA"           "stores_w$w"
  start prove "dc_w${w}_dbg.v" bmc   40 "-DWINDOW=$w -DINV"            "invalidate_w$w"
  start prove "dc_w${w}_dbg.v" cover 24 "-DWINDOW=$w -DDATA -DCOVER"   "cover_w$w"
  start prove "dc_w${w}_dbg.v" cover 40 "-DWINDOW=$w -DINV -DCOVER"    "cover_inv_w$w"
  start prove "dc_w${w}_dbg.v" bmc   22 "-DWINDOW=$w -DREGION"         "region_w$w"
  start prove "dc_w${w}_dbg.v" cover 40 "-DWINDOW=$w -DREGION -DCOVER" "cover_region_w$w"
done

# Mutants of the VHDL: each defect must make a proof fail.
export MUT_DEPTH=24 MUT_DEFS='-DDATA'
start_mutant hit_store_not_cached "/ram_we <= '1' when (st = S_LOOK and hit = '1' and i_wren = '1' and is_rom = '0'/{N;s/.*/  ram_we <= '1' when st = S_FILL_GET else '0';/}"
start_mutant write_back_on_hit    "s/elsif (write_through or is_rom = '1' or i_bypass = '1') and i_wren = '1' then/elsif (is_rom = '1' or i_bypass = '1') and i_wren = '1' then/"
start_mutant byteena_lost         "s/d_be_i    <= i_byteena;/d_be_i    <= \"1111\";/"
start_mutant fill_word_swapped    "s/i_d_rdata_x(31 downto 0)  when cnt = \"01\" else/i_d_rdata_x(63 downto 32) when cnt = \"01\" else/"
start_mutant hit_ignores_tag      "s/hit     <= valid(to_integer(unsigned(cur_idx))) when tag_rd = req_tag else '0';/hit     <= valid(to_integer(unsigned(cur_idx)));/"
start_mutant store_acked_early    "s/            st        <= S_WT_WAIT;/            st        <= S_DONE;/"
start_mutant store_data_lost      "s/d_wdata_i <= i_wdata;/d_wdata_i <= (others => '0');/"
wait
# The invalidation mutant needs the INV mode.
export MUT_DEPTH=40 MUT_DEFS='-DINV'
mutant_run inv_inverted "s/if inv_run = '1' then/if inv_run = '0' then/"
# The region mutants need the REGION mode.
export MUT_DEPTH=22 MUT_DEFS='-DREGION'
start_mutant region_ignored   "s/if in_region(i, rq_first, rq_off, rq_all) and dirty(i) = '0' then/if false then/"
start_mutant fill_stays_valid "s/valid(ci) <= not stale;/valid(ci) <= '1';/"
start_mutant fill_not_marked  "s/if (st = S_FILL_REQ or st = S_FILL_WAIT or st = S_FILL_GET) and in_region(to_integer(unsigned(req_idx)), rq_first, rq_off, rq_all) then/if false then/"
start_mutant region_one_short "s/return all_lines = '1' or (to_unsigned(i, first'length) - first) <= off;/return all_lines = '1' or (to_unsigned(i, first'length) - first) < off;/"
wait

for w in $windows; do
  expect "store order and data of every hit and fill (bounded, 24 clocks, window $w)" PASS "stores_w$w"
  expect "a flush with invalidation leaves every line invalid (bounded, 40 clocks, window $w)" PASS "invalidate_w$w"
  expect "cover: a store, a load after a fill and a load hit are reachable (window $w)" PASS "cover_w$w"
  expect "cover: a flush with invalidation is reachable (window $w)" PASS "cover_inv_w$w"
  expect "after a region, a load is the current data of the lower memory (bounded, 22 clocks, window $w)" PASS "region_w$w"
  expect "cover: a region that changes the word and loads before and after it are reachable (window $w)" PASS "cover_region_w$w"
done
for m in region_ignored fill_stays_valid fill_not_marked region_one_short; do
  expect "mutant $m is caught" FAIL "mut_$m"
done
for m in hit_store_not_cached write_back_on_hit byteena_lost fill_word_swapped hit_ignores_tag store_acked_early store_data_lost inv_inverted; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal dcache: all expectations met" || { echo "formal dcache: FAILED (logs in build/formal_dcache)"; exit 1; }
