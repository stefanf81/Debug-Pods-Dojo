#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
require_dojo_context

# Check every deployed lab against its success condition. The exit status mirrors check-lab.sh:
# 0 every deployed lab passes, 1 at least one is not fixed yet, 2 at least one check could not run.
# Checks run in parallel (CHECK_JOBS at a time, default 4) because a broken lab spends its whole
# retry budget before it fails; results are printed in lab order.
JOBS="${CHECK_JOBS:-4}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "CHECK_JOBS must be a positive integer (got '$JOBS')" >&2; exit 2; }

lab_list="$(selected_labs "$ROOT")" || { echo "Invalid lab selection (LABS='${LABS:-}')" >&2; exit 2; }
labs=()
while IFS= read -r lab; do
  [[ -n "$lab" ]] && labs+=("$lab")
done <<<"$lab_list"
(( ${#labs[@]} > 0 )) || { echo "No labs selected (LABS='${LABS:-}')" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Decide which labs are deployed before starting any check.
to_check=()
for lab in "${labs[@]}"; do
  ns="$(lab_namespace "$lab")"
  if [[ -n "$ns" ]] && kubectl --context "$DOJO_CONTEXT" get namespace "$ns" >/dev/null 2>&1; then
    to_check+=("$lab")
  fi
done

for lab in ${to_check[@]+"${to_check[@]}"}; do
  name="$(basename "$lab")"
  num="${name%%-*}"
  while (( $(jobs -rp | wc -l) >= JOBS )); do sleep 0.5; done
  (
    rc=0
    "$ROOT/scripts/check-lab.sh" "$num" >"$tmp/$num.out" 2>&1 || rc=$?
    echo "$rc" >"$tmp/$num.rc"
  ) &
done
wait

printf '%-4s %-34s %s\n' "LAB" "NAME" "RESULT"
printf '%-4s %-34s %s\n' "---" "----" "------"

passed=0
not_fixed=0
errors=0
skipped=0

for lab in "${labs[@]}"; do
  name="$(basename "$lab")"
  num="${name%%-*}"
  label="${name#*-}"
  if [[ ! -f "$tmp/$num.rc" ]]; then
    printf '%-4s %-34s %s\n' "$num" "$label" "NOT DEPLOYED"
    skipped=$((skipped + 1))
    continue
  fi
  rc="$(cat "$tmp/$num.rc")"
  case "$rc" in
    0)
      printf '%-4s %-34s %s\n' "$num" "$label" "PASS"
      passed=$((passed + 1))
      ;;
    1)
      printf '%-4s %-34s %s\n' "$num" "$label" "NOT FIXED YET"
      note="$(sed -n 's/^Hint: //p' "$tmp/$num.out" | head -n 1)"
      [[ -n "$note" ]] && printf '     %s\n' "$note"
      not_fixed=$((not_fixed + 1))
      ;;
    *)
      printf '%-4s %-34s %s\n' "$num" "$label" "CHECK ERROR (${rc})"
      note="$(head -n 1 "$tmp/$num.out")"
      [[ -n "$note" ]] && printf '     %s\n' "$note"
      errors=$((errors + 1))
      ;;
  esac
done

echo
summary="${passed} passed, ${not_fixed} not fixed, ${errors} check error(s), ${skipped} not deployed"
if (( errors > 0 )); then
  echo "Result: ${summary}" >&2
  echo "Run a failing lab directly with: CHECK_VERBOSE=1 ./scripts/check-lab.sh <lab>" >&2
  exit 2
elif (( not_fixed > 0 )); then
  echo "Result: ${summary}"
  exit 1
else
  echo "Result: ${summary}"
  exit 0
fi
