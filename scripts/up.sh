#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
echo "==> Debug Pods Dojo"
BUILD_IMAGE="${IMAGE:-debug-dojo-java:local}"
LAB_IMAGE="debug-dojo-java:local"
ARTHAS_IMAGE="debug-dojo-arthas-jdk21:local"
CONTEXT="$DOJO_CONTEXT"
# Host port for the k3d load balancer (Ingress). Override to run several dojo clusters side by side.
INGRESS_PORT="${INGRESS_PORT:-8080}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need docker
need k3d
need kubectl

lab_list="$(selected_labs "$ROOT")"
mapfile -t labs <<<"$lab_list"

wait_deployment() {
  local namespace="$1" name="$2"
  echo "    waiting for ${namespace}/deployment/${name}"
  kubectl --context "$CONTEXT" -n "$namespace" rollout status deployment/"$name" --timeout=180s
}

echo "==> Building distroless Java training image"
docker build -t "$BUILD_IMAGE" "$ROOT/images/java-dojo"
if [[ "$BUILD_IMAGE" != "$LAB_IMAGE" ]]; then
  docker tag "$BUILD_IMAGE" "$LAB_IMAGE"
fi

echo "==> Building Java 21 Arthas debug image"
docker build -t "$ARTHAS_IMAGE" "$ROOT/images/arthas-jdk21"

if k3d cluster list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$CLUSTER"; then
  echo "==> k3d cluster '$CLUSTER' already exists"
else
  echo "==> Creating 1-server + 2-agent k3d cluster (Ingress on host port $INGRESS_PORT)"
  k3d cluster create "$CLUSTER" \
    --servers 1 \
    --agents 2 \
    --port "${INGRESS_PORT}:80@loadbalancer" \
    --wait \
    --timeout 180s
fi

echo "==> Importing local Java and Arthas debug images"
k3d image import -c "$CLUSTER" "$LAB_IMAGE" "$ARTHAS_IMAGE"

kubectl config use-context "$CONTEXT" >/dev/null

echo "==> Waiting for K3s packaged components used by the labs"
wait_deployment kube-system coredns
wait_deployment kube-system metrics-server
wait_deployment kube-system traefik

echo "==> Deploying ${#labs[@]} debug-pod-focused scenarios"
for lab in "${labs[@]}"; do
  echo "    $(basename "$lab")"
  kubectl --context "$CONTEXT" apply -f "$lab/broken.yaml" >/dev/null
done

# An existing cluster keeps the port it was created with, so report the real mapping.
ingress_port="$(docker port "k3d-${CLUSTER}-serverlb" 80/tcp 2>/dev/null | head -1 | sed 's/.*://')"

cat <<EOF

Debug Pods Dojo is ready.

Context: $CONTEXT
Guide:   $ROOT/LABS.md
Status:  $ROOT/scripts/status.sh
Check:   $ROOT/scripts/check-lab.sh <number>
Reset:   $ROOT/scripts/reset-lab.sh <number>
Fix:     $ROOT/scripts/solve-lab.sh <number>

Ingress exercise: http://localhost:${ingress_port:-$INGRESS_PORT}/dojo
EOF
