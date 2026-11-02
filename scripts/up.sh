#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
echo "==> Debug Pods Dojo"
BUILD_IMAGE="${DOJO_JAVA_IMAGE:-debug-dojo-java:local}"
LAB_IMAGE="debug-dojo-java:local"
ARTHAS_IMAGE="debug-dojo-arthas-jdk21:local"
CONTEXT="$DOJO_CONTEXT"
# Host port for the k3d load balancer (Ingress). Override to run several dojo clusters side by side.
INGRESS_PORT="${INGRESS_PORT:-8080}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1" >&2; exit 1; }; }

preflight() {
  docker info >/dev/null 2>&1 \
    || { echo "Docker is installed but not reachable. Start Docker and retry." >&2; exit 1; }

  local version major
  version="$(k3d version 2>/dev/null | awk '/^k3d version/ {print $3; exit}' || true)"
  major="${version#v}"
  major="${major%%.*}"
  if [[ "$major" =~ ^[0-9]+$ ]] && (( major < 5 )); then
    echo "k3d ${version:-unknown} is too old; k3d 5.x is required." >&2
    exit 1
  fi

  local mem_gib
  mem_gib="$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%d", $1 / 1073741824}')"
  if [[ "$mem_gib" =~ ^[0-9]+$ ]] && (( mem_gib > 0 && mem_gib < 6 )); then
    echo "Warning: Docker reports ${mem_gib} GiB of memory; about 6 GiB is recommended for all labs." >&2
  fi
}

# True when something already accepts TCP connections on a host port.
port_is_listening() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

need docker
need k3d
need kubectl
preflight

lab_list="$(selected_labs "$ROOT")"
labs=()
while IFS= read -r lab; do
  if [[ -n "$lab" ]]; then labs+=("$lab"); fi
done <<<"$lab_list"
(( ${#labs[@]} > 0 )) || { echo "No labs selected (LABS='${LABS:-}')" >&2; exit 2; }

wait_deployment() {
  local namespace="$1" name="$2" deadline=$((SECONDS + 180))
  echo "    waiting for ${namespace}/deployment/${name}"
  # K3s creates some packaged components after the cluster reports ready (Traefik comes from a Helm
  # job), and `rollout status` fails at once for a Deployment that does not exist yet.
  until kubectl --context "$CONTEXT" -n "$namespace" get deployment "$name" >/dev/null 2>&1; do
    (( SECONDS < deadline )) || { echo "Timed out waiting for ${namespace}/deployment/${name} to be created" >&2; exit 1; }
    sleep 2
  done
  kubectl --context "$CONTEXT" -n "$namespace" rollout status deployment/"$name" --timeout=180s
}

echo "==> Building distroless Java training image"
docker build -t "$BUILD_IMAGE" "$ROOT/images/java-dojo"
if [[ "$BUILD_IMAGE" != "$LAB_IMAGE" ]]; then
  docker tag "$BUILD_IMAGE" "$LAB_IMAGE"
fi

echo "==> Building Java 21 Arthas debug image"
docker build -t "$ARTHAS_IMAGE" "$ROOT/images/arthas-jdk21"

# Capture the pre-dojo context before k3d creates the cluster and switches to it.
remember_previous_context

if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  echo "==> k3d cluster '$CLUSTER' already exists"
else
  if port_is_listening "$INGRESS_PORT"; then
    echo "Host port ${INGRESS_PORT} is already in use. Stop the process using it or set INGRESS_PORT=<port>." >&2
    exit 1
  fi
  echo "==> Creating 1-server + 2-agent k3d cluster (Ingress on host port $INGRESS_PORT)"
  k3d cluster create "$CLUSTER" \
    --servers 1 \
    --agents 2 \
    --port "${INGRESS_PORT}:80@loadbalancer" \
    --wait \
    --timeout "${CLUSTER_START_TIMEOUT:-300}s"
fi

echo "==> Importing local Java and Arthas debug images"
k3d image import -c "$CLUSTER" "$LAB_IMAGE" "$ARTHAS_IMAGE"

if ! context_exists "$CONTEXT"; then
  echo "==> Restoring missing kubeconfig context for '$CLUSTER'"
  k3d kubeconfig merge "$CLUSTER" --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null
fi
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

# An existing cluster keeps the port it was created with, so report the real mapping. Under pipefail a
# failing `docker port` (no load balancer container) would abort here, so fall back to INGRESS_PORT.
ingress_port="$(docker port "k3d-${CLUSTER}-serverlb" 80/tcp 2>/dev/null | head -1 | sed 's/.*://' || true)"

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
