#!/usr/bin/env bash
# Formal verification of the instruction cache with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl,
# yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from
# the root of the repository:  bash formal/icache/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The cache is two lines of 128 bits
# (size_bits = 256): the logic does not depend on the size.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
block=icache
src="$root/src/cache/SoC/icache.vhd"
props="$root/formal/icache/props.sv"
out="$root/build/formal_icache"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# shellcheck source=formal/common.sh
source "$root/formal/common.sh"

netlist() {  # <vhdl> <name>
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$root/src/common/src/utils_pkg.vhd" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gsize_bits=256 icache > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v"
}

echo "icache"
netlist "$src" ic

start prove ic_dbg.v bmc   28 ''        safety
start prove ic_dbg.v cover 28 '-DCOVER' cover
start prove ic_dbg.v bmc   22 '-DREGION' region
start prove ic_dbg.v cover 22 '-DREGION -DCOVER' cover_region

# Mutants of the VHDL: each defect must make the safety proof fail.
export MUT_DEPTH=28
start_mutant dropped_fill_valid "s/if drop = '0' and i_invalidate = '0' then/if i_invalidate = '0' then/"
start_mutant invalidate_keeps   "/if i_invalidate = '1' then/{n;s/valid <= (others => '0');/null;/}"
start_mutant tag_always_matches "s/tag_match <= '1' when tag_rd = (in_rom(addr_q) \& addr_q(25 downto TAG_LOW)) else '0';/tag_match <= '1';/"
start_mutant ready_without_addr "s/o_ready     <= hit when addr_q = i_addr else '0';/o_ready     <= hit;/"
start_mutant fill_word_swapped  "s/i_d_rdata_x(31 downto 0)  when cnt = \"01\" else/i_d_rdata_x(63 downto 32) when cnt = \"01\" else/"
start_mutant hit_without_sel    "s/hit       <= sel_q and valid_rd and tag_match;/hit       <= valid_rd and tag_match;/"
start_mutant partial_line       "s/o_d_line    <= d_line_i;/o_d_line    <= '0';/"
wait
# The region mutants need the REGION mode.
export MUT_DEPTH=22 MUT_DEFS='-DREGION'
start_mutant region_ignored     "s/if in_region(i, rq_first, rq_off, rq_all) then/if false then/"
start_mutant fill_not_dropped   "s/if st \/= S_IDLE and in_region(to_integer(unsigned(fill_idx)), rq_first, rq_off, rq_all) then/if false then/"
start_mutant region_too_wide    "s/return all_lines = '1' or (to_unsigned(i, first'length) - first) <= off;/return true;/"
start_mutant region_one_short   "s/return all_lines = '1' or (to_unsigned(i, first'length) - first) <= off;/return all_lines = '1' or (to_unsigned(i, first'length) - first) < off;/"
start_mutant big_region_partial "s/if span_m1 >= LINES - 1 then/if false then/"
wait
export MUT_DEPTH=28; unset MUT_DEFS

expect "hit data, invalidation and bus requests (bounded, 28 clocks)" PASS safety
expect "cover: a hit on the watched word, a miss and an invalidation during a fill are reachable" PASS cover
expect "after a region, a hit is the current data and a region off the index keeps the hit (bounded, 22 clocks)" PASS region
expect "cover: a region that changes the word, a hit on the old data and a region off the index are reachable" PASS cover_region
for m in region_ignored fill_not_dropped region_too_wide region_one_short big_region_partial; do
  expect "mutant $m is caught" FAIL "mut_$m"
done
for m in dropped_fill_valid invalidate_keeps tag_always_matches ready_without_addr fill_word_swapped hit_without_sel partial_line; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal icache: all expectations met" || { echo "formal icache: FAILED (logs in build/formal_icache)"; exit 1; }
