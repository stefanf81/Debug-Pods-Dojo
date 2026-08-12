#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
require_dojo_context

printf '%-26s %-36s %-8s %-18s %s\n' NAMESPACE POD READY STATUS RESTARTS
kubectl --context "$DOJO_CONTEXT" get pods -A --no-headers | \
  awk '$1 ~ /^dojo-/ {printf "%-26s %-36s %-8s %-18s %s\n", $1,$2,$3,$4,$5}'

echo
echo "Lab namespaces:"
kubectl --context "$DOJO_CONTEXT" get ns -l debug-dojo=true --no-headers 2>/dev/null || true
