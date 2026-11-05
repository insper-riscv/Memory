#!/usr/bin/env bash
# Tests formal/aggregate.sh on results written by hand: every scenario states the exit code it must end with. Also
# tests the guard of formal/common.sh that makes a warning of GHDL, Yosys or SymbiYosys an error.
# Needs jq. Run from the root of the repository:  bash formal/test-aggregate.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# row <scenario> <engine> <tag> <expected> <verdict>: one result line of an engine, in the block of the proof
row() {
  mkdir -p "$work/$1"
  printf '{"engine":"%s","block":"axi_slave","tag":"%s","label":"%s","expected":"%s","verdict":"%s","rc":"0","seconds":1.0,"detail":""}\n' \
    "$2" "$3" "$3" "$4" "$5" >> "$work/$1/result-$2.jsonl"
}

failures=0
# check <scenario> <wanted exit code> <what the scenario shows>
check() {
  local got=0
  bash "$root/formal/aggregate.sh" "$work/$1" > "$work/$1.out" 2>&1 || got=$?
  if [ "$got" = "$2" ]; then
    echo "ok    $3"
  else
    echo "WRONG $3: wanted exit code $2, got $got"
    sed 's/^/        /' "$work/$1.out"
    failures=$((failures + 1))
  fi
}

# 1. the engines agree on every proof
for e in yices bitwuzla boolector; do
  row agree "$e" safety pass pass
  row agree "$e" mut_a fail fail
done
check agree 0 "the engines agree with what is expected"

# 2. one engine has an error and the others decide
for e in yices bitwuzla; do row error_one "$e" safety pass pass; done
row error_one boolector safety pass error
check error_one 0 "an engine with an error does not stop the others from deciding"

# 3. a skip is no answer either, and the engine that can run the proof decides
row skip_one bitwuzla cover pass pass
row skip_one abc-bmc3 cover pass skip
check skip_one 0 "an engine that cannot run a kind of proof does not count"

# 4. an engine contradicts the others
row disagree yices safety pass pass
row disagree bitwuzla safety pass fail
check disagree 1 "a pass and a fail of the same proof are a disagreement"

# 5. no engine decided
for e in yices bitwuzla; do row none "$e" safety pass error; done
row none abc-bmc3 safety pass skip
check none 1 "a proof that only has errors and skips is not decided"

# 6. a defect that should fail is answered as pass
for e in yices bitwuzla; do row wrong "$e" mut_a fail pass; done
check wrong 1 "a mutant that is not caught fails the proof"

# 7. the only engine is broken
row only_broken yices safety pass error
check only_broken 1 "a single engine in error decides nothing"

# 8. a broken engine next to one that decides
row broken_and_ok yices safety pass error
row broken_and_ok bitwuzla safety pass pass
check broken_and_ok 0 "a broken engine does not fail a proof another engine decided"

# 9. an engine that left no result at all
mkdir -p "$work/empty"
check empty 1 "no results at all"

# The guard against warnings (warnings_in, ghdl_run and prove of formal/common.sh). Each case is a log line and whether
# the guard must find a warning in it.
guard_case() {  # <wanted: warn|clean> <log line> <what the line shows> [engine]
  local found
  printf '%s\n' "$2" > "$work/guard.log"
  found="$(FORMAL_ENGINE="${4:-bitwuzla}" bash -c 'source "$1"; warnings_in "$2"' _ "$root/formal/common.sh" "$work/guard.log")"
  if { [ "$1" = warn ] && [ -n "$found" ]; } || { [ "$1" = clean ] && [ -z "$found" ]; }; then
    echo "ok    guard: $3"
  else
    echo "WRONG guard: $3 (wanted $1, found '$found')"
    failures=$((failures + 1))
  fi
}

guard_case warn  '/work/src/synchronizer.vhd:62:19:warning: unhandled attribute "altera_attribute" [-Wunhandled-attribute]' "a warning of GHDL"
guard_case warn  'SBY 12:00:01 [mut_x] base: Warning: Wire flash_arbiter.\dbg_last_a is used but has no driver.' "a warning of Yosys in the log of SymbiYosys"
guard_case warn  'WARNING: something' "the word in capitals"
guard_case warn  'Warnings: 2 unique messages, 2 total' "a summary of Yosys with a count above zero"
guard_case clean 'Warnings: 0 unique messages, 0 total' "a summary of Yosys with a count of zero"
guard_case clean 'reading formal/no_warnings.sv' "a file name that contains the word"
guard_case clean 'assert property warning_free passed' "a property name that contains the word"
guard_case clean 'SBY 12:00:03 [safety] aig: Warning: Treating undriven bit props.\clk like $anyseq.' "an ABC message, in the abc-bmc3 engine" abc-bmc3
guard_case clean 'SBY 12:00:03 [safety] aig: Warning: Treating a total of 7 undriven bits in props like $anyseq.' "an ABC message with a count, in the abc-bmc3 engine" abc-bmc3
guard_case clean 'SBY 12:00:03 [safety] engine_0: Warning: The last 2 outputs are interpreted as constraints.' "an ABC message about constraints, in the abc-bmc3 engine" abc-bmc3
guard_case warn  'SBY 12:00:03 [safety] aig: Warning: Treating undriven bit props.\clk like $anyseq.' "the same ABC message in another engine" yices
guard_case warn  'SBY 12:00:03 [safety] base: Warning: Wire props.\x is used but has no driver.' "any other warning, in the abc-bmc3 engine" abc-bmc3
guard_case clean 'SBY 12:00:02 [safety] summary: engine_0 (smtbmc bitwuzla) returned pass' "an ordinary line"

# ghdl_run and prove must turn a warning into a failure: tools are replaced by scripts that only print.
fake="$work/fake"; mkdir -p "$fake"
printf '#!/bin/sh\necho "x.vhd:3:4:warning: invented" >&2\n' > "$fake/ghdl"
printf '#!/bin/sh\necho "Warning: invented" \n' > "$fake/sby"
chmod +x "$fake/ghdl" "$fake/sby"
if (PATH="$fake:$PATH" FORMAL_ENGINE=bitwuzla bash -c 'source "$1"; ghdl_run -a x.vhd' _ "$root/formal/common.sh" > /dev/null 2>&1); then
  echo "WRONG guard: ghdl_run accepted a warning"; failures=$((failures + 1))
else
  echo "ok    guard: ghdl_run fails on a warning"
fi
mkdir -p "$work/prove"
( cd "$work/prove" && PATH="$fake:$PATH" FORMAL_ENGINE=bitwuzla props=p.sv bash -c 'source "$1"; : > n.v; prove n.v bmc 5 "" t' _ "$root/formal/common.sh" > /dev/null 2>&1 )
if grep -q '^ERROR warning' "$work/prove/t.res"; then
  echo "ok    guard: prove turns a warning of sby with exit code 0 into an ERROR"
else
  echo "WRONG guard: prove did not fail on a warning ($(cat "$work/prove/t.res" 2> /dev/null))"; failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] && echo "aggregate: all scenarios met" || { echo "aggregate: $failures scenario(s) failed"; exit 1; }
