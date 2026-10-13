#!/usr/bin/env bash
# Formal verification of axil_master_bridge with SymbiYosys. Needs ghdl, yosys, sby and the z3 solver
# (insper-riscv/Infra's toolchain image). Run from the root of the repository:
#   bash formal/axil_master/run.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$root/external/axi/axil_master_bridge.vhd"
props="$root/formal/axil_master/props.sv"
out="$root/build/formal_axil"
rm -rf "$out"; mkdir -p "$out"; cd "$out"

fail=0
expect() {
  if [ "$2" = "$3" ]; then printf '  ok    %-52s %s\n' "$1" "$3"
  else printf '  WRONG %-52s wanted %s, got %s\n' "$1" "$2" "$3"; fail=1; fi
}

netlist() {  # <vhdl> <name>
  local work="$out/work_$2"; mkdir -p "$work"
  ghdl -a --std=08 --workdir="$work" "$1"
  ghdl --synth --std=08 --workdir="$work" --out=verilog axil_master_bridge > "$2.v"
  # a copy that exposes the state registers the invariants need (the logic is the same)
  sed -e 's/input  \[1:0\] m_rresp);/input  [1:0] m_rresp,\n  output [1:0] dbg_st, output dbg_awv, output dbg_wv, output dbg_arv, output dbg_we);/' \
      -e 's/^endmodule/  assign dbg_st = st;\n  assign dbg_awv = awv;\n  assign dbg_wv = wv;\n  assign dbg_arv = arv;\n  assign dbg_we = we_l;\nendmodule/' \
      "$2.v" > "$2_dbg.v"
  grep -q dbg_st "$2_dbg.v" || { echo "the netlist has no register named st: the exposure did not apply"; exit 1; }
}

prove() {  # <netlist> <mode> <depth> <defines> <tag> -> PASS or FAIL
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

echo "axil_master_bridge"
netlist "$src" bridge
expect "safety, unbounded (k-induction)"          PASS "$(prove bridge_dbg.v prove 20 ''                      safety)"
expect "cover: every situation is reachable"       PASS "$(prove bridge_dbg.v cover 40 '-DCOVER'                cover)"
expect "an access is done within W clocks"         PASS "$(prove bridge_dbg.v bmc   40 "-DFAIRNESS -DW=${W:-12}" live)"

# Mutants of the VHDL: each defect must make the safety proof fail.
mutant() {  # <name> <sed expression>
  sed "$2" "$src" > "$out/mut_$1.vhd"
  cmp -s "$src" "$out/mut_$1.vhd" && { echo "mutant $1: the edit did not change the file"; exit 1; }
  netlist "$out/mut_$1.vhd" "mut_$1"
  expect "mutant $1 is caught" FAIL "$(prove "mut_$1_dbg.v" bmc 30 '' "mut_$1")"
}
mutant no_wait_aw   "s/m_bready  <= '1' when st = ST_WR and awv = '0' and wv = '0' else '0';/m_bready  <= '1' when st = ST_WR else '0';/"
mutant strb_wrong   "s/strb_l  <= byteena;/strb_l  <= \"1111\";/"
mutant drop_w       "s/if wv = '1' and m_wready = '1' then/if wv = '1' then/"
mutant ready_pulse  "s/if mem_advance = '1' then/if true then/"

[ "$fail" -eq 0 ] && echo "formal axil: all expectations met" || { echo "formal axil: FAILED (logs in build/formal_axil)"; exit 1; }
