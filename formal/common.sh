# Shared by the formal/*/run.sh scripts (sourced, never run). Runs SymbiYosys proofs side by side, at most
# FORMAL_JOBS at a time (default: the number of cores, up to 8), with the engine chosen by FORMAL_ENGINE, tells a
# verdict from a failure of the tool and records every result for formal/aggregate.sh. A warning of GHDL, Yosys or
# SymbiYosys is an error (see warnings_in): the code is fixed, the warning is never silenced.
# The script that sources it sets block, out, props, src and fail, and defines netlist <vhdl> <name>.

formal_jobs="${FORMAL_JOBS:-$(nproc)}"
[ "$formal_jobs" -gt 8 ] && formal_jobs=8

# The engine of the proofs: an SMT solver run by smtbmc, or the bounded model checker of ABC.
engine="${FORMAL_ENGINE:-bitwuzla}"
case "$engine" in
  yices | bitwuzla | boolector | abc-bmc3) ;;
  *) echo "FORMAL_ENGINE must be yices, bitwuzla, boolector or abc-bmc3, not '$engine'" >&2; exit 2 ;;
esac

# The slots are shared by the scripts that run at once: formal/all.sh exports FORMAL_SLOTS, and a script run
# alone makes its own.
if [ -z "${FORMAL_SLOTS:-}" ]; then
  FORMAL_SLOTS="$(mktemp -d)"
  export FORMAL_SLOTS
  trap 'rm -rf "$FORMAL_SLOTS"' EXIT
fi

# acquire: waits for a free slot and sets slot to it (a slot is a directory, and mkdir is atomic).
acquire() {
  local i
  while :; do
    for i in $(seq 1 "$formal_jobs"); do
      if mkdir "$FORMAL_SLOTS/$i" 2> /dev/null; then slot="$i"; return; fi
    done
    sleep 0.5
  done
}

release() { rmdir "$FORMAL_SLOTS/$slot" 2> /dev/null || true; }

# start <command...>: runs the command in the background once a slot is free.
start() {
  (
    acquire
    trap release EXIT
    "$@"
  ) &
}

# The only warnings accepted, and only from the abc-bmc3 engine: the three messages of ABC about the undriven clock
# of the property module, the undriven bits and the outputs read as constraints.
abc_notes='aig: Warning: Treating undriven bit props\.\\clk like \$anyseq\.$|aig: Warning: Treating a total of [0-9]+ undriven bits in props like \$anyseq\.$|engine_0: Warning: The last ([0-9]+ outputs are|output is) interpreted as (a )?constraints?\.$'

# warnings_in <log> [label]: prints every warning of a tool log as <label>:<line>: <text> (the label is the log by
# default), and nothing when there is none. A warning is a diagnostic: the word "warning" or "warnings", in any case,
# as a whole word, which is how GHDL (file:line:col:warning: text), Yosys (Warning: text) and SymbiYosys (the same,
# after its time and the tag of the proof) write it. A name that only contains the word (no_warnings.sv, a property
# called warning_free) is not a whole word, and the summary of Yosys with a count of zero ("Warnings: 0 unique
# messages, 0 total") reports that there is none.
warnings_in() {
  local ignore='^$^'
  # Only the log of the abc-bmc3 engine (never GHDL's output) may carry these ABC messages, which come from the way ABC
  # reads the netlist and cannot be removed from the design; any other message, in any engine, still fails.
  [ "$engine" = abc-bmc3 ] && [ "${2:-}" != ghdl ] && ignore="$abc_notes"
  ignore="$ignore" awk -v label="${2:-$1}" '
    BEGIN { ignore = ENVIRON["ignore"] }
    { l = tolower($0) }
    l ~ /(^|[^a-z0-9_.\/-])warnings?($|[^a-z0-9_.\/-])/ && l !~ /warnings: 0 unique messages, 0 total/ && $0 !~ ignore { printf "%s:%d: %s\n", label, FNR, $0 }
  ' "$1"
}

# prove <netlist> <mode: prove|bmc|cover> <depth> <defines> <tag>: runs sby and writes the verdict to <tag>.res,
# PASS (exit code 0), FAIL (2, a counterexample or a goal that cannot be covered), ERROR (any other code, such
# as 4 unknown, 8 timeout and 16 error: the tool did not reach a verdict) or SKIP (the engine cannot run that
# kind of proof: abc-bmc3 only does bounded checks; or it did not finish within FORMAL_TIMEOUT seconds, 600 by
# default, which leaves the proof to the other engines), and the exit code and the seconds it took to <tag>.info.
prove() {
  if [ "$engine" = abc-bmc3 ] && [ "$2" != bmc ]; then
    echo "SKIP abc-bmc3 runs only bounded checks, not mode $2" > "$5.res"
    echo "- 0.0" > "$5.info"
    return
  fi
  {
    printf '%s\n' '[options]' "mode $2" "depth $3"
    # ABC has no model of its own to rebuild a counterexample with, and gets the netlist as plain logic
    if [ "$engine" = abc-bmc3 ]; then printf '%s\n' 'aigsmt none' '[engines]' 'abc bmc3'; else printf '%s\n' '[engines]' "smtbmc $engine"; fi
    printf '%s\n' '[script]' "read_verilog -formal -sv $4 $1 $props" 'prep -top props' 'memory_map'
    if [ "$engine" = abc-bmc3 ]; then printf '%s\n' 'techmap' 'opt -fast' 'setundef -anyseq'; fi
    printf '%s\n' '[files]' "$1" "$props"
  } > "$5.sby"
  local rc=0 t0 t1
  t0="$(date +%s.%N)"
  timeout "${FORMAL_TIMEOUT:-600}" sby -f "$5.sby" > "$5.log" 2>&1 || rc=$?
  t1="$(date +%s.%N)"
  local found
  found="$(warnings_in "$5.log" "${out:-.}/$5.log")"
  # A warning is an error, whatever the verdict was
  if [ -n "$found" ]; then
    echo "formal: the log of the proof has warnings, which are errors:" >&2
    echo "$found" >&2
    echo "ERROR warning in the log of the proof, first at $(echo "$found" | head -n 1 | cut -c1-200)" > "$5.res.tmp"
  else
    case "$rc" in
      0) echo PASS ;;
      2) echo FAIL ;;
      124) echo "SKIP the engine did not finish within FORMAL_TIMEOUT (${FORMAL_TIMEOUT:-600} s)" ;;
      *) echo "ERROR sby exited with code $rc, not a verdict (see $5.log)" ;;
    esac > "$5.res.tmp"
  fi
  awk -v rc="$rc" -v a="$t0" -v b="$t1" 'BEGIN { printf "%s %.1f\n", rc, b - a }' > "$5.info"
  mv "$5.res.tmp" "$5.res"
}

# mutant_run <name> <sed expression>: the netlist of the VHDL with one defect, and the bounded proof of safety on it.
mutant_run() {
  sed "$2" "$src" > "$out/mut_$1.vhd"
  if cmp -s "$src" "$out/mut_$1.vhd"; then
    echo "ERROR the edit of the mutant did not change the file" > "$out/mut_$1.res"
    return
  fi
  netlist "$out/mut_$1.vhd" "mut_$1"
  prove "mut_$1_dbg.v" bmc "${MUT_DEPTH:-30}" "${MUT_DEFS:-}" "mut_$1"
}

# start_mutant <name> <sed expression>: each defect must make the safety proof fail.
start_mutant() { start mutant_run "$@"; }

# json_text <text>: the text as the content of a JSON string.
json_text() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# record <tag> <label> <wanted: pass|fail> <verdict: pass|fail|error|skip> <detail>: one line of results.jsonl, which
# formal/aggregate.sh reads to decide, across the engines, whether the proof holds.
record() {
  local rc sec
  read -r rc sec < "$out/$1.info" 2> /dev/null || { rc="-"; sec=0.0; }
  printf '{"engine":"%s","block":"%s","tag":"%s","label":"%s","expected":"%s","verdict":"%s","rc":"%s","seconds":%s,"detail":"%s"}\n' \
    "$engine" "$block" "$1" "$(json_text "$2")" "$3" "$4" "$rc" "$sec" "$(json_text "$5")" >> "$out/results.jsonl"
}

# expect <label> <wanted: PASS|FAIL> <tag>: compares the verdict written by prove with the wanted one. An ERROR
# never matches, not even a wanted FAIL, and a SKIP is neither right nor wrong: the engine gave no answer.
expect() {
  local got wanted
  got="$(cat "$out/$3.res" 2> /dev/null || echo 'ERROR no verdict was written')"
  wanted="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
  case "$got" in
    ERROR*) printf '  ERROR %-52s %s\n' "$1" "${got#ERROR }"; record "$3" "$1" "$wanted" error "${got#ERROR }"; fail=1 ;;
    SKIP*) printf '  skip  %-52s %s\n' "$1" "${got#SKIP }"; record "$3" "$1" "$wanted" skip "${got#SKIP }" ;;
    "$2") printf '  ok    %-52s %s\n' "$1" "$got"; record "$3" "$1" "$wanted" "$wanted" "" ;;
    *) printf '  WRONG %-52s wanted %s, got %s\n' "$1" "$2" "$got"; record "$3" "$1" "$wanted" "$(echo "$got" | tr '[:upper:]' '[:lower:]')" ""; fail=1 ;;
  esac
}

# expose <netlist> <signal[:high bit]>...: adds the wires of the last module (the top, GHDL writes it last) as the
# outputs dbg_<signal>, in place. The logic is the same; the proof states its invariants over these registers. A
# signal that the netlist no longer has (GHDL drops what nothing reads, as in a mutant that removes the only reader)
# is exposed as 0, so that no wire is read without a driver.
expose() {
  local v="$1"; shift
  local ports="" assigns="" s w nm width src
  for s in "$@"; do
    nm="${s%%:*}"; w=""; width=1
    if [ "$s" != "$nm" ]; then w="[${s#*:}:0] "; width=$(( ${s#*:} + 1 )); fi
    ports+=",
   output ${w}dbg_$nm"
    if awk -v nm="$nm;" '/^module / { n = 0 } $1 ~ /^(reg|wire)$/ && $NF == nm { n = 1 } END { exit !n }' "$v"; then src="$nm"; else src="${width}'b0"; fi
    assigns+="  assign dbg_$nm = $src;
"
  done
  awk -v ports="$ports" -v assigns="$assigns" '
    { line[NR] = $0 }
    /^module / { m = NR }
    /^endmodule/ { e = NR }
    END {
      done = 0
      for (i = 1; i <= NR; i++) {
        l = line[i]
        if (i >= m && !done && l ~ /\);[ \t]*$/) { sub(/\);[ \t]*$/, ports ");", l); done = 1 }
        if (i == e) printf "%s", assigns
        print l
      }
    }' "$v" > "$v.tmp" && mv "$v.tmp" "$v"
}

# formal_vhdl <vhdl> <name>: writes <name>.vhd in the output directory without the attribute altera_attribute and its
# declaration, which tell Quartus how to place a synchronizer and mean nothing to GHDL, which warns that it does not
# handle them. The logic is the same; prints the path of the copy.
formal_vhdl() {
  awk '
    skip { if ($0 ~ /;[ \t]*$/) skip = 0; next }
    /^[ \t]*attribute[ \t]+altera_attribute/ { if ($0 !~ /;[ \t]*$/) skip = 1; next }
    { print }
  ' "$1" > "$out/$2.vhd"
  echo "$out/$2.vhd"
}

# ghdl_run <ghdl arguments>: runs ghdl and keeps the informative "found RAM" notes (one per memory of each netlist,
# repeated for every mutant, each with its line of source and caret) out of the terminal. Errors still reach it, and a
# warning is an error: it reaches the terminal as it came (file:line:col:warning: text) and ghdl_run fails.
ghdl_run() {
  local err rc=0 w
  err="$(mktemp)"
  ghdl "$@" 2> "$err" || rc=$?
  awk '/:note: found RAM/ { skip = 1; next } skip { if ($0 ~ /^[ \t]*\^/) skip = 0; next } { print }' "$err" > "$err.out"
  cat "$err.out" >&2
  w="$(warnings_in "$err.out" ghdl)"
  rm -f "$err" "$err.out"
  if [ -n "$w" ]; then
    echo "formal: ghdl has warnings, which are errors (the file and line are in the text of each):" >&2
    echo "$w" >&2
    return 1
  fi
  return "$rc"
}
