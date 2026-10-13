#!/usr/bin/env bash
# Formal verification of the SDRAM arbiter with SymbiYosys (see docs/FORMAL.md). Needs ghdl, yosys,
# sby and the z3 solver, all in insper-riscv/Infra's toolchain image. Run from the root of the
# repository:  bash formal/run.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/external/sdram/sdram_arbiter.vhd"
props="$root/formal/sdram_arbiter/props.sv"
out="$root/build/formal"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
# expect <label> <wanted: PASS|FAIL> <result: PASS|FAIL>
expect() {
  if [ "$2" = "$3" ]; then printf '  ok    %-52s %s\n' "$1" "$3"
  else printf '  WRONG %-52s wanted %s, got %s\n' "$1" "$2" "$3"; fail=1; fi
}

# netlist <vhdl> <name>: the GHDL netlist of sdram_arbiter, and a copy of it that exposes the
# registers the invariants need as outputs (the logic is the same).
netlist() {
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl -a --std=08 --workdir="$work" "$1"
  ghdl --synth --std=08 --workdir="$work" --out=verilog sdram_arbiter > "$2.v"
  sed -e 's/input  \[31:0\] c_rdata);/input  [31:0] c_rdata,\n  output dbg_st, output dbg_grant_b, output dbg_last_b, output dbg_a_tog_l, output [1:0] dbg_a_s);/' \
      -e 's/^endmodule/  assign dbg_st = st;\n  assign dbg_grant_b = grant_b;\n  assign dbg_last_b = last_b;\n  assign dbg_a_tog_l = a_tog_l;\n  assign dbg_a_s = a_s;\nendmodule/' \
      "$2.v" > "$2_dbg.v"
  grep -q dbg_st "$2_dbg.v" || { echo "the netlist has no register named st: the exposure did not apply"; exit 1; }
}

# prove <netlist> <mode: prove|bmc|cover> <depth> <defines> <tag>  ->  PASS or FAIL
prove() {
  cat > "$5.sby" <<EOS
[options]
mode $2
depth $3
[engines]
smtbmc z3
[script]
read_verilog -formal -sv $4 $1 $props
prep -top props
[files]
$1
$props
EOS
  if sby -f "$5.sby" > "$5.log" 2>&1; then echo PASS; else echo FAIL; fi
}

echo "sdram_arbiter"
netlist "$src" arb
expect "safety, unbounded (k-induction)"                    PASS "$(prove arb_dbg.v prove 30 ''             safety)"
expect "cover: every situation is reachable"                 PASS "$(prove arb_dbg.v cover 40 '-DCOVER'       cover)"
expect "a request is answered within 14 clocks (depth 45)"   PASS "$(prove arb_dbg.v bmc   45 '-DFAIRNESS -DW=14' wait14)"
expect "13 clocks are not enough (the bound is tight)"       FAIL "$(prove arb_dbg.v bmc   45 '-DFAIRNESS -DW=13' wait13)"

# Mutants of the VHDL: each defect must make the safety proof fail.
mutant() {  # <name> <sed expression>
  sed "$2" "$src" > "$out/mut_$1.vhd"
  cmp -s "$src" "$out/mut_$1.vhd" && { echo "mutant $1: the edit did not change the file"; exit 1; }
  netlist "$out/mut_$1.vhd" "mut_$1"
  expect "mutant $1 is caught" FAIL "$(prove "mut_$1_dbg.v" bmc 30 '' "mut_$1")"
}
mutant rdata_swap   "s/a_rdata_i <= c_rdata;/a_rdata_i <= b_rdata_i;/"
mutant no_wait_ctrl "s/if c_ack_tog = c_req_i then/if true then/"

[ "$fail" -eq 0 ] && echo "formal: all expectations met" || { echo "formal: FAILED (logs in build/formal)"; exit 1; }
