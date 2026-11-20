#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"

# Pull the digest-pinned third-party images once on the host and load them into every k3d node, so
# the first lab that needs an image does not wait for (or fail on) a registry pull on each node.
#
#   ./scripts/preload.sh            workload images + every debug image (about 3 GB)
#   ./scripts/preload.sh --runtime  only what the lab workloads and the checker probe run
#   ./scripts/preload.sh --debug    only the debug images used by LABS.md
#
# `k3d image import` cannot resolve `repo:tag@sha256:...` references, so the images are saved with
# Docker and imported into each node's containerd under the `repo@sha256:...` name that kubelet
# looks up for a pinned image.
usage() { echo "Usage: $0 [--all|--runtime|--debug]" >&2; exit 2; }

scope="${1:---all}"
case "$scope" in
  --all)     vars="$RUNTIME_IMAGE_VARS $DEBUG_IMAGE_VARS" ;;
  --runtime) vars="$RUNTIME_IMAGE_VARS" ;;
  --debug)   vars="$DEBUG_IMAGE_VARS" ;;
  *)         usage ;;
esac

command -v docker >/dev/null 2>&1 || { echo "Missing required command: docker" >&2; exit 1; }
command -v k3d >/dev/null 2>&1 || { echo "Missing required command: k3d" >&2; exit 1; }
k3d cluster get "$CLUSTER" >/dev/null 2>&1 \
  || { echo "k3d cluster '$CLUSTER' does not exist; run ./scripts/up.sh first." >&2; exit 1; }

# Only Docker's containerd image store keeps the multi-platform index that a digest-pinned reference
# names. The classic store would give the nodes a single-platform copy under a different digest that
# kubelet never matches, so there is nothing useful to preload.
if [[ "$(docker info --format '{{json .DriverStatus}}' 2>/dev/null)" != *io.containerd.snapshotter* ]]; then
  echo "Docker is not using the containerd image store, so digest-pinned images cannot be preloaded;"
  echo "they will be pulled on first use. (Docker Desktop / Rancher Desktop enable the store in settings.)"
  exit 0
fi

nodes=()
while IFS= read -r node; do
  [[ -n "$node" ]] && nodes+=("$node")
done <<<"$(k3d_node_containers)"
(( ${#nodes[@]} > 0 )) || { echo "No running k3d nodes found for '$CLUSTER'." >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# docker.io/<namespace>/<name> for a pinned reference; official images get the "library" namespace.
containerd_base_name() {
  local repo="${1%%@*}"
  repo="${repo%%:*}"
  [[ "$repo" == */* ]] || repo="library/$repo"
  printf 'docker.io/%s\n' "$repo"
}

# One listing per node up front: images a node already holds under repo@digest are skipped.
for node in "${nodes[@]}"; do
  docker exec "$node" ctr -n k8s.io images ls -q >"$tmp/$node.refs" 2>/dev/null || : >"$tmp/$node.refs"
done

# Copy the tarball into one node, import it and verify kubelet can resolve repo@digest there.
import_into_node() {
  local node="$1" tarball="$2" base="$3" digest="$4"
  docker cp "$tarball" "$node:/tmp/preload-image.tar" >/dev/null
  docker exec "$node" ctr -n k8s.io images import --base-name "$base" --digests /tmp/preload-image.tar >/dev/null 2>&1 \
    && docker exec "$node" ctr -n k8s.io images ls -q 2>/dev/null | grep -xF -- "$base@$digest" >/dev/null
  local rc=$?
  docker exec "$node" rm -f /tmp/preload-image.tar >/dev/null 2>&1 || true
  return "$rc"
}

count=0
skipped=0
unverified=0
for var in $vars; do
  image="${!var}"
  count=$((count + 1))
  base="$(containerd_base_name "$image")"
  digest="${image##*@}"
  missing=()
  for node in "${nodes[@]}"; do
    grep -xF -- "$base@$digest" "$tmp/$node.refs" >/dev/null || missing+=("$node")
  done
  if (( ${#missing[@]} == 0 )); then
    echo "==> [$count] on all nodes    $image"
    skipped=$((skipped + 1))
    continue
  fi
  if docker image inspect "$image" >/dev/null 2>&1; then
    echo "==> [$count] cached on host  $image"
  else
    echo "==> [$count] pulling         $image"
    docker pull --quiet "$image" >/dev/null
  fi
  tarball="$tmp/image.tar"
  docker save "$image" -o "$tarball"
  # Import into the nodes that lack it in parallel; each records its result for the summary below.
  # Kubelet only reuses the image when the node knows it under repo@digest, so anything else is a
  # warning: the image is then simply pulled on first use.
  for node in "${missing[@]}"; do
    ( if import_into_node "$node" "$tarball" "$base" "$digest"; then echo ok; else echo failed; fi >"$tmp/$node.result" ) &
  done
  wait
  for node in "${missing[@]}"; do
    if [[ "$(cat "$tmp/$node.result" 2>/dev/null)" != ok ]]; then
      echo "    warning: $node cannot resolve $base@$digest after import" >&2
      unverified=$((unverified + 1))
    fi
  done
  rm -f "$tarball"
done

if (( unverified > 0 )); then
  echo "Preloaded $count image(s), but $unverified node import(s) could not be verified; kubelet will pull those on first use." >&2
else
  echo "Preloaded $count image(s) into ${#nodes[@]} node(s) ($skipped already present on every node)."
fi
