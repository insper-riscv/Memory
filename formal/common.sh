# Shared by the formal/*/run.sh scripts (sourced, never run). Runs SymbiYosys proofs side by side, at most
# FORMAL_JOBS at a time (default: the number of cores, up to 8), and tells a verdict from a failure of the tool.
# The script that sources it sets out, props, src and fail, and defines netlist <vhdl> <name>.

formal_jobs="${FORMAL_JOBS:-$(nproc)}"
[ "$formal_jobs" -gt 8 ] && formal_jobs=8

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

# prove <netlist> <mode: prove|bmc|cover> <depth> <defines> <tag>: runs sby and writes the verdict to <tag>.res,
# PASS (exit code 0), FAIL (2, a counterexample or a goal that cannot be covered) or ERROR (any other code, such
# as 4 unknown, 8 timeout and 16 error: the tool did not reach a verdict).
prove() {
  cat > "$5.sby" << EOS
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
  local rc=0
  sby -f "$5.sby" > "$5.log" 2>&1 || rc=$?
  case "$rc" in
    0) echo PASS ;;
    2) echo FAIL ;;
    *) echo "ERROR sby exited with code $rc, not a verdict (see $5.log)" ;;
  esac > "$5.res.tmp"
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
  prove "mut_$1_dbg.v" bmc 30 '' "mut_$1"
}

# start_mutant <name> <sed expression>: each defect must make the safety proof fail.
start_mutant() { start mutant_run "$@"; }

# expect <label> <wanted: PASS|FAIL> <tag>: compares the verdict written by prove with the wanted one. An ERROR
# never matches, not even a wanted FAIL.
expect() {
  local got
  got="$(cat "$out/$3.res" 2> /dev/null || echo 'ERROR no verdict was written')"
  case "$got" in
    ERROR*) printf '  ERROR %-52s %s\n' "$1" "${got#ERROR }"; fail=1 ;;
    "$2") printf '  ok    %-52s %s\n' "$1" "$got" ;;
    *) printf '  WRONG %-52s wanted %s, got %s\n' "$1" "$2" "$got"; fail=1 ;;
  esac
}
