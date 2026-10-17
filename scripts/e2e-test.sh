#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLUSTER="${CLUSTER:-debug-pods-dojo-e2e}"
# Use a separate host port so the test can run while the main dojo cluster is up.
export INGRESS_PORT="${INGRESS_PORT:-8180}"
unset LABS
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
ORIGINAL_CONTEXT=""

cleanup() {
  if [[ "$KEEP_CLUSTER" != "1" ]]; then
    k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ORIGINAL_CONTEXT" ]] && kubectl config get-contexts "$ORIGINAL_CONTEXT" >/dev/null 2>&1; then
    kubectl config use-context "$ORIGINAL_CONTEXT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for cmd in docker k3d kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

ORIGINAL_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
"$ROOT/scripts/up.sh"

echo "==> Broken-state reference checks"
for lab in "$ROOT"/labs/*; do
  number="$(basename "$lab")"; number="${number%%-*}"
  if "$ROOT/scripts/check-lab.sh" "$number" >/dev/null 2>&1; then
    echo "Broken scenario unexpectedly passed: $(basename "$lab")" >&2
    exit 1
  fi
done

echo "==> Reference repair checks"
for lab in "$ROOT"/labs/*; do
  number="$(basename "$lab")"; number="${number%%-*}"
  "$ROOT/scripts/solve-lab.sh" "$number" >/dev/null
  "$ROOT/scripts/check-lab.sh" "$number" >/dev/null
done

echo "E2E reference-state test: PASS"
