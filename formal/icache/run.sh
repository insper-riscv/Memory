#!/usr/bin/env bash
# Formal verification of the instruction cache with SymbiYosys (see docs/pt-br/formal/formal.md). Needs ghdl,
# yosys, sby and the solver of the engine (FORMAL_ENGINE), all in insper-riscv/Infra's toolchain image. Run from
# the root of the repository:  bash formal/icache/run.sh
# The proofs are bounded and run side by side (see formal/common.sh). The cache is two lines of 128 bits
# (size_bits = 256): the logic does not depend on the size. The proofs run for each width of the tag window in
# FORMAL_WINDOWS (default "26 27": 64 MiB and 128 MiB); the mutants run on the default width.
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

netlist() {  # <vhdl> <name> [window_bits]
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl_run -a --std=08 --workdir="$work" "$root/src/common/src/utils_pkg.vhd" "$root/src/cache/SoC/cache_pkg.vhd" "$1"
  ghdl_run --synth --std=08 --workdir="$work" --out=verilog -gsize_bits=256 "-gwindow_bits=${3:-26}" icache > "$2.v"
  cp "$2.v" "$2_dbg.v"
  expose "$2_dbg.v"
}

echo "icache"
windows="${FORMAL_WINDOWS:-26 27}"
for w in $windows; do
  netlist "$src" "ic_w$w" "$w"
  start prove "ic_w${w}_dbg.v" bmc   28 "-DWINDOW=$w"               "safety_w$w"
  start prove "ic_w${w}_dbg.v" cover 28 "-DWINDOW=$w -DCOVER"        "cover_w$w"
  start prove "ic_w${w}_dbg.v" bmc   32 "-DWINDOW=$w -DREGION"       "region_w$w"
  start prove "ic_w${w}_dbg.v" cover 32 "-DWINDOW=$w -DREGION -DCOVER" "cover_region_w$w"
done

# Mutants of the VHDL: each defect must make the safety proof fail.
export MUT_DEPTH=28
start_mutant invalidate_keeps   "s/^ \{20\}blocked <= '1';/                    null;/"
start_mutant hit_while_blocked  "s/early_ok  <= sel_eff and (not blocked) when/early_ok  <= sel_eff when/"
start_mutant tag_always_matches "s/tag_match <= '1' when tag_rd = (rom_q \& addr_q(window_bits - 1 downto TAG_LOW)) else '0';/tag_match <= '1';/"
start_mutant ready_without_addr "s/addr_same <= '1' when (not check_addr) or addr_q = i_addr else '0';/addr_same <= '1';/"
start_mutant fill_word_swapped  "s/i_d_rdata_x(31 downto 0)[[:space:]]*when cnt = \"01\" else/i_d_rdata_x(63 downto 32) when cnt = \"01\" else/"
start_mutant hit_without_sel    "s/early_ok  <= sel_eff and (not blocked) when/early_ok  <= (not blocked) when/"
start_mutant partial_line       "s/o_d_line    <= d_line_i;/o_d_line    <= '0';/"
wait
# The region mutants need the REGION mode.
export MUT_DEPTH=32 MUT_DEFS='-DREGION'
start_mutant region_ignored     "s/pend_first <= rq_first;/pend_first <= rq_first + 1;/"
start_mutant big_region_partial "s/if span_m1 >= LINES - 1 then/if false then/"
wait
export MUT_DEPTH=28; unset MUT_DEFS

for w in $windows; do
  expect "hit data, invalidation and bus requests (bounded, 28 clocks, window $w)" PASS "safety_w$w"
  expect "cover: a hit on the watched word, a miss and an invalidation during a fill are reachable (window $w)" PASS "cover_w$w"
  expect "after a region, a hit is the current data (bounded, 32 clocks, window $w)" PASS "region_w$w"
  expect "cover: a region that changes the word, a hit on the old data and a region off the index are reachable (window $w)" PASS "cover_region_w$w"
done
for m in region_ignored big_region_partial; do
  expect "mutant $m is caught" FAIL "mut_$m"
done
for m in invalidate_keeps hit_while_blocked tag_always_matches ready_without_addr fill_word_swapped hit_without_sel partial_line; do
  expect "mutant $m is caught" FAIL "mut_$m"
done

[ "$fail" -eq 0 ] && echo "formal icache: all expectations met" || { echo "formal icache: FAILED (logs in build/formal_icache)"; exit 1; }
