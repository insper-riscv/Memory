#!/usr/bin/env bash
# Tests formal/aggregate.sh on results written by hand: every scenario states the exit code it must end with.
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

[ "$failures" -eq 0 ] && echo "aggregate: all scenarios met" || { echo "aggregate: $failures scenario(s) failed"; exit 1; }
