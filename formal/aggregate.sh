#!/usr/bin/env bash
# Decides, across the engines, whether every formal proof holds (see docs/FORMAL.md, section 9). It reads the
# result-<engine>.jsonl files that `make formal FORMAL_ENGINE=<engine>` writes (formal/all.sh), in the directory
# given and in the ones below it, and needs jq. Run:  bash formal/aggregate.sh <directory>
#
# For each proof, an engine answers pass or fail; an error (the tool reached no verdict) or a skip (the engine
# cannot run that kind of proof) is no answer. The proof holds when it has at least one answer, the answers do
# not contradict each other and they are the expected one. The exit code is 0 when every proof holds.
# The table of proofs by engine goes to the output and, when GITHUB_STEP_SUMMARY is set, to the job summary.
set -euo pipefail

dir="${1:?usage: bash formal/aggregate.sh <directory with the result-<engine>.jsonl files>}"
mapfile -t files < <(find "$dir" -name 'result-*.jsonl' -size +0c | sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "formal: no engine left results in $dir, so no proof was decided" >&2
  exit 1
fi

decided="$(jq -s '
  group_by(.block + "/" + .tag)
  | map({
      key: (.[0].block + "/" + .[0].tag),
      label: .[0].label,
      expected: (map(.expected) | unique),
      cells: (map({(.engine): {verdict: .verdict, seconds: .seconds}}) | add),
      answers: (map(select(.verdict == "pass" or .verdict == "fail") | .verdict) | unique)
    }
    | . + {result:
        (if (.expected | length) != 1 then "the engines expect different results"
         elif (.answers | length) == 0 then "NO ANSWER"
         elif (.answers | length) > 1 then "DISAGREEMENT"
         elif .answers[0] != .expected[0] then "WRONG"
         else "ok" end)})
' "${files[@]}")"

engines="$(jq -r '[.[].cells | keys[]] | unique | join(" ")' <<< "$decided")"
total="$(jq 'length' <<< "$decided")"
bad="$(jq '[.[] | select(.result != "ok")] | length' <<< "$decided")"
if [ "$total" -eq 0 ]; then echo "formal: the results hold no proof" >&2; exit 1; fi

# one line by proof: key, expected, one cell by engine (verdict and seconds, or - when the engine did not run it), result
rows="$(jq -r --arg engines "$engines" '
  ($engines | split(" ")) as $e
  | .[]
  | . as $p
  | [$p.key, $p.expected[0]]
    + [$e[] | ($p.cells[.] // null) | if . == null then "-" else (.verdict + (if .verdict == "skip" then "" else " " + (.seconds | tostring) + "s" end)) end]
    + [$p.result]
  | @tsv' <<< "$decided")"
header="$(printf 'proof\texpected\t%s\tresult' "$(tr ' ' '\t' <<< "$engines")")"

echo "formal: ${total} proofs, engines: ${engines}"
printf '%s\n%s\n' "$header" "$rows" | awk -F'\t' '
  { for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > width[i]) width[i] = length($i) } cols = NF }
  END { for (r = 1; r <= NR; r++) { line = ""; for (i = 1; i <= cols; i++) line = line sprintf("%-" width[i] "s  ", cell[r, i]); print line } }'

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### formal: proofs by engine"
    echo
    printf '| %s |\n' "$(sed 's/\t/ | /g' <<< "$header")"
    printf '|%s\n' "$(awk -F'\t' '{ for (i = 1; i <= NF; i++) printf " :--- |" }' <<< "$header")"
    while IFS= read -r row; do printf '| %s |\n' "$(sed 's/\t/ | /g' <<< "$row")"; done <<< "$rows"
    echo
    if [ "$bad" -eq 0 ]; then echo "Every proof holds."; else echo "**${bad} of ${total} proofs do not hold.**"; fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$bad" -gt 0 ]; then
  echo "formal: ${bad} of ${total} proofs do not hold:" >&2
  jq -r '.[] | select(.result != "ok") | "  \(.key) (\(.label)): \(.result)"' <<< "$decided" >&2
  exit 1
fi
echo "formal: every proof holds"
