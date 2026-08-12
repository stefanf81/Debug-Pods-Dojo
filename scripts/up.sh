#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOJO_VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo unknown)"
echo "==> Debug Pods Dojo ${DOJO_VERSION}"
CLUSTER="${CLUSTER:-debug-pods-dojo}"
BUILD_IMAGE="${IMAGE:-debug-dojo-java:local}"
LAB_IMAGE="debug-dojo-java:local"
ARTHAS_IMAGE="debug-dojo-arthas-jdk21:local"
CONTEXT="k3d-${CLUSTER}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }
need docker
need k3d
need kubectl

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
  echo "==> Creating 1-server + 2-agent k3d cluster"
  k3d cluster create "$CLUSTER" \
    --servers 1 \
    --agents 2 \
    --port "8080:80@loadbalancer" \
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

echo "==> Deploying 16 debug-pod-focused scenarios"
for lab in "$ROOT"/labs/*; do
  [[ -f "$lab/broken.yaml" ]] || continue
  echo "    $(basename "$lab")"
  kubectl --context "$CONTEXT" apply -f "$lab/broken.yaml" >/dev/null
done

cat <<EOF

Debug Pods Dojo is ready.

Context: $CONTEXT
Guide:   $ROOT/LABS.md
Status:  $ROOT/scripts/status.sh
Check:   $ROOT/scripts/check-lab.sh <number>
Reset:   $ROOT/scripts/reset-lab.sh <number>
Fix:     $ROOT/scripts/solve-lab.sh <number>

Ingress exercise: http://localhost:8080/dojo
EOF
