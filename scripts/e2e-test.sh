#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The dojo scripts read CLUSTER and INGRESS_PORT, so take the test's values from E2E_* variables
# instead of inheriting what a learner exported for the main dojo (this script deletes $CLUSTER).
export CLUSTER="${E2E_CLUSTER:-debug-pods-dojo-e2e}"
# Use a separate host port so the test can run while the main dojo cluster is up.
export INGRESS_PORT="${E2E_INGRESS_PORT:-8180}"
unset LABS
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
# A private kubeconfig keeps cluster creation and `use-context` away from the learner's current context.
E2E_KUBECONFIG_DIR="$(mktemp -d)"
export KUBECONFIG="$E2E_KUBECONFIG_DIR/config"

cleanup() {
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

# check-lab.sh exits 1 for "not fixed yet" and 2 when the check itself could not run.
echo "==> Broken-state reference checks"
for lab in "$ROOT"/labs/*; do
  number="$(basename "$lab")"; number="${number%%-*}"
  rc=0
  out="$("$ROOT/scripts/check-lab.sh" "$number" 2>&1)" || rc=$?
  case "$rc" in
    1) ;;
    0) echo "Broken scenario unexpectedly passed: $(basename "$lab")" >&2; exit 1 ;;
    *) printf '%s\n' "$out" >&2; echo "Checker could not evaluate broken scenario $(basename "$lab") (exit $rc)" >&2; exit 1 ;;
  esac
done

echo "==> Reference repair checks"
for lab in "$ROOT"/labs/*; do
  number="$(basename "$lab")"; number="${number%%-*}"
  "$ROOT/scripts/solve-lab.sh" "$number" >/dev/null
  out="$("$ROOT/scripts/check-lab.sh" "$number" 2>&1)" \
    || { printf '%s\n' "$out" >&2; echo "Reference repair did not pass: $(basename "$lab")" >&2; exit 1; }
done

echo "E2E reference-state test: PASS"
