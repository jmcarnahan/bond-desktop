#!/bin/bash
# The project's pre-commit gates in one command, with a short answer.
#
#   .claude/hooks/gate.sh [label]
#
# Runs `flutter analyze` and `flutter test` in app/ (offline, serverless — the
# live benches are @Skip'd and never part of this), tees the full output to
# /tmp/gate-<label>-<stamp>.log, prints a summary of at most ~20 lines in the
# phase-table form ("4428/7 green"), and on green writes tmp/.gate/last-green,
# which the commit hook checks and the session-start hook reports.
set -u
# The label lands in a file name and a JSON string: letters, digits, . _ - only.
label=$(printf '%s' "${1:-gate}" | tr -c 'A-Za-z0-9._-' '-' | tr -s '-')
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "not inside a git checkout" >&2; exit 2; }
app="$root/app"
[ -d "$app" ] || { echo "no app/ under $root" >&2; exit 2; }
stamp=$(date +%Y%m%d-%H%M%S)
log=/tmp/gate-$label-$stamp.log
mkdir -p "$root/tmp/.gate"

echo "gate: $label · $(git -C "$root" branch --show-current) @ $(git -C "$root" rev-parse --short HEAD) · log $log"

cd "$app" || exit 2
{ echo "=== flutter analyze"; flutter analyze; echo "analyze exit=$?"; } > "$log" 2>&1
analyze_exit=$(sed -n 's/^analyze exit=//p' "$log" | tail -1)
issues=$(grep -E '^ *(error|warning|info) ' "$log" | head -10)
if [ "$analyze_exit" = "0" ] && grep -q 'No issues found' "$log"; then
  echo "analyze: clean"
  date +%s > "$root/tmp/.gate/analyze-ok"
else
  echo "analyze: NOT clean (exit $analyze_exit)"
  [ -n "$issues" ] && echo "$issues"
  echo "gate: RED (analyzer) · full log $log"
  exit 1
fi

# A red run must not leave yesterday's green stamp for the commit hook to trust.
rm -f "$root/tmp/.gate/last-green"
{ echo "=== flutter test"; flutter test --reporter failures-only; echo "test exit=$?"; } >> "$log" 2>&1
test_exit=$(sed -n 's/^test exit=//p' "$log" | tail -1)
# failures-only prints "+5365 ~7: All other tests passed!" (no clock prefix);
# the compact reporter prints "01:50 +5365 ~7: All tests passed!".
summary=$(grep -E '^([0-9:]+ )?\+[0-9]+' "$log" | tail -1)
passed=$(echo "$summary" | sed -n 's/.*+\([0-9]*\).*/\1/p')
skipped=$(echo "$summary" | sed -n 's/.*~\([0-9]*\).*/\1/p'); skipped=${skipped:-0}
failed=$(echo "$summary" | sed -n 's/.* -\([0-9]*\).*/\1/p'); failed=${failed:-0}

if [ "$test_exit" = "0" ] && [ "$failed" = "0" ] && [ -n "$passed" ] && grep -qE 'All (other )?tests passed' "$log"; then
  echo "tests: $passed passed / $skipped skipped"
  echo "gate: ${passed}/${skipped} green"
  printf '{"when":"%s","branch":"%s","head":"%s","passed":%s,"skipped":%s,"label":"%s","log":"%s"}\n' \
    "$(date '+%Y-%m-%d %H:%M')" "$(git -C "$root" branch --show-current)" "$(git -C "$root" rev-parse --short HEAD)" \
    "$passed" "$skipped" "$label" "$log" > "$root/tmp/.gate/last-green"
  exit 0
fi

echo "tests: ${passed:-?} passed / $skipped skipped / $failed FAILED (exit $test_exit)"
grep -E '\[E\]' "$log" | sed 's/^[0-9:]* [+~-]*[0-9 ~-]*: */  /' | sort -u | head -12
echo "gate: RED (tests) · full log $log"
exit 1
