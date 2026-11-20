#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The dojo scripts read CLUSTER and INGRESS_PORT, so take the test's values from E2E_* variables
# instead of inheriting what a learner exported for the main dojo (this script deletes $CLUSTER).
export CLUSTER="${E2E_CLUSTER:-debug-pods-dojo-e2e}"
# Use a separate host port so the test can run while the main dojo cluster is up.
export INGRESS_PORT="${E2E_INGRESS_PORT:-8180}"
# Run every lab by default. E2E_LABS limits the suite to a subset for a faster smoke test:
#   E2E_LABS="01 07" ./scripts/e2e-test.sh
if [[ -n "${E2E_LABS:-}" ]]; then
  export LABS="$E2E_LABS"
else
  unset LABS
fi
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
# The checks never use the Arthas debug image, so do not build and import it (about 700 MB).
export DOJO_ARTHAS="${DOJO_ARTHAS:-0}"
JOBS="${CHECK_JOBS:-4}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "CHECK_JOBS must be a positive integer (got '$JOBS')" >&2; exit 2; }
# A private kubeconfig keeps cluster creation and `use-context` away from the learner's current context.
E2E_KUBECONFIG_DIR="$(mktemp -d)"
export KUBECONFIG="$E2E_KUBECONFIG_DIR/config"
source "$ROOT/scripts/lib.sh"

# Capture first: a failure inside a here-string substitution is ignored, so a typo such as
# E2E_LABS="01 99" would silently run fewer labs instead of stopping.
lab_list="$(selected_labs "$ROOT")" || { echo "Invalid lab selection (E2E_LABS='${E2E_LABS:-}')" >&2; exit 2; }
labs=()
while IFS= read -r lab; do
  [[ -n "$lab" ]] && labs+=("$lab")
done <<<"$lab_list"
(( ${#labs[@]} > 0 )) || { echo "No labs selected (E2E_LABS='${E2E_LABS:-}')" >&2; exit 2; }

results="$(mktemp -d)"
cleanup() {
  rm -rf "$results"
  forget_previous_context
  if [[ "$KEEP_CLUSTER" == "1" ]]; then
    echo "Kept cluster $CLUSTER; use it with: export KUBECONFIG=$KUBECONFIG"
  else
    k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
    rm -rf "$E2E_KUBECONFIG_DIR"
  fi
}
trap cleanup EXIT

for cmd in docker k3d kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
"$ROOT/scripts/up.sh"

# Check every lab, CHECK_JOBS at a time, and expect exit status <expected> from each. check-lab.sh
# exits 0 when fixed, 1 when not fixed yet and 2 when the check itself could not run. Every
# unexpected result is reported before the test fails.
check_phase() {
  local expected="$1" started=$SECONDS lab name number rc failed=0
  rm -f "$results"/*
  run_lab_checks "$ROOT" "$results" "$JOBS" "${labs[@]}"
  for lab in "${labs[@]}"; do
    name="$(basename "$lab")"
    number="${name%%-*}"
    rc="$(cat "$results/$number.rc" 2>/dev/null || echo missing)"
    [[ "$rc" == "$expected" ]] && continue
    failed=$((failed + 1))
    sed 's/^/    /' "$results/$number.out" >&2 2>/dev/null || true
    if [[ "$expected" == 1 && "$rc" == 0 ]]; then
      echo "Broken scenario unexpectedly passed: $name" >&2
    elif [[ "$expected" == 1 ]]; then
      echo "Checker could not evaluate broken scenario $name (exit $rc)" >&2
    else
      echo "Reference repair did not pass: $name (exit $rc)" >&2
    fi
  done
  echo "    ${#labs[@]} labs checked in $((SECONDS - started))s"
  (( failed == 0 )) || exit 1
}

echo "==> Broken-state reference checks"
check_phase 1

# Apply every reference repair first so the rollouts run concurrently, then check them together.
echo "==> Reference repair checks"
for lab in "${labs[@]}"; do
  number="$(basename "$lab")"; number="${number%%-*}"
  "$ROOT/scripts/solve-lab.sh" "$number" >/dev/null
done
check_phase 0

echo "E2E reference-state test: PASS (${#labs[@]} labs)"
