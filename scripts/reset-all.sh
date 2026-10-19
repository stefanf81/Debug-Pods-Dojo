#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
require_dojo_context

lab_list="$(selected_labs "$ROOT")"
labs=()
while IFS= read -r lab; do
  if [[ -n "$lab" ]]; then labs+=("$lab"); fi
done <<<"$lab_list"
(( ${#labs[@]} > 0 )) || { echo "No labs selected (LABS='${LABS:-}')" >&2; exit 2; }

namespaces=()
for lab in "${labs[@]}"; do
  ns="$(lab_namespace "$lab")"
  [[ -n "$ns" ]] || { echo "Could not determine namespace for $(basename "$lab")" >&2; exit 1; }
  namespaces+=("$ns")
  kubectl --context "$DOJO_CONTEXT" delete namespace "$ns" --ignore-not-found --wait=false >/dev/null
done

deadline=$((SECONDS + 180))
while :; do
  remaining=()
  for ns in "${namespaces[@]}"; do
    kubectl --context "$DOJO_CONTEXT" get namespace "$ns" >/dev/null 2>&1 && remaining+=("$ns") || true
  done
  (( ${#remaining[@]} == 0 )) && break
  (( SECONDS < deadline )) || { echo "Timed out waiting for: ${remaining[*]}" >&2; exit 1; }
  sleep 2
done

for lab in "${labs[@]}"; do
  kubectl --context "$DOJO_CONTEXT" apply -f "$lab/broken.yaml" >/dev/null
done
echo "Reset ${#labs[@]} labs"
