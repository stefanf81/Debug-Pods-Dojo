#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
require_dojo_context

# Remove the Pods that debugging leaves behind. Lab workloads and your repairs are not touched.
#   - node debug Pods (`kubectl debug node/...` creates node-debugger-* in the current namespace)
#   - checker probe Pods (labelled dojo-check=true) that an interrupted check did not delete
k=(kubectl --context "$DOJO_CONTEXT")
namespace="$("${k[@]}" config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
namespace="${namespace:-default}"

removed=0
while read -r name; do
  [[ -n "$name" ]] || continue
  "${k[@]}" -n "$namespace" delete pod "$name" --wait=false >/dev/null
  echo "deleted node debug Pod $namespace/$name"
  removed=$((removed + 1))
done < <("${k[@]}" -n "$namespace" get pods -o name 2>/dev/null | sed 's#^pod/##' | grep '^node-debugger-' || true)

while read -r ns name; do
  [[ -n "$name" ]] || continue
  "${k[@]}" -n "$ns" delete pod "$name" --wait=false >/dev/null
  echo "deleted checker probe Pod $ns/$name"
  removed=$((removed + 1))
done < <("${k[@]}" get pods -A -l dojo-check=true \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

echo "Removed $removed Pod(s)."
