#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
require_dojo_context

num="${1:-}"
[[ -n "$num" ]] || { echo "Usage: $0 <lab-number-or-prefix>" >&2; exit 2; }
lab="$(find_lab "$ROOT" "$num")"
ns="$(lab_namespace "$lab")"
[[ -n "$ns" ]] || { echo "Could not determine namespace for $(basename "$lab")" >&2; exit 1; }

# Bound the wait like reset-all.sh: without --timeout kubectl waits up to a week for a stuck namespace.
kubectl --context "$DOJO_CONTEXT" delete namespace "$ns" --ignore-not-found --wait=true --timeout=180s >/dev/null \
  || { echo "Timed out waiting for namespace $ns to be deleted; see: kubectl get namespace $ns -o yaml" >&2; exit 1; }
kubectl --context "$DOJO_CONTEXT" apply -f "$lab/broken.yaml"
echo "Reset $(basename "$lab")"
