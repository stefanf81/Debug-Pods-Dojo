#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
require_dojo_context

# Rebuild the local Java and Arthas images after changing images/, import them into the running
# cluster and restart the lab Deployments that run the Java app. Running Pods keep the image they
# started with (imagePullPolicy: IfNotPresent), so without the restart a rebuild has no effect.
# Fixes you applied to the Deployments stay in place; only the Pods are replaced.
for cmd in docker k3d; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done
k3d cluster get "$CLUSTER" >/dev/null 2>&1 \
  || { echo "k3d cluster '$CLUSTER' does not exist; run ./scripts/up.sh first." >&2; exit 1; }

build_local_images "$ROOT"

echo "==> Importing local Java and Arthas debug images"
k3d image import -c "$CLUSTER" "$LAB_IMAGE" "$ARTHAS_IMAGE"

echo "==> Restarting lab Deployments that run $LAB_IMAGE"
restarted=()
while read -r ns name images; do
  [[ "$ns" == dojo-* ]] || continue
  [[ " $images " == *" $LAB_IMAGE "* ]] || continue
  kubectl --context "$DOJO_CONTEXT" -n "$ns" rollout restart "deployment/$name" >/dev/null
  restarted+=("$ns/$name")
done < <(kubectl --context "$DOJO_CONTEXT" get deployments -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.template.spec.containers[*].image}{"\n"}{end}')

if (( ${#restarted[@]} == 0 )); then
  echo "    no lab Deployments use $LAB_IMAGE"
  exit 0
fi
for target in "${restarted[@]}"; do
  echo "    ${target}"
  kubectl --context "$DOJO_CONTEXT" -n "${target%%/*}" rollout status "deployment/${target#*/}" --timeout=180s >/dev/null
done
echo "Rebuilt and restarted ${#restarted[@]} Deployment(s)."
