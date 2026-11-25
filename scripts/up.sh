#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
echo "==> Debug Pods Dojo"
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

  # The kubelet of the pinned k3s release refuses to start on cgroup v1, and k3d only reports that
  # after its node wait times out (5 minutes per attempt), so stop here instead.
  if [[ "$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)" == "1" ]]; then
    cat >&2 <<'MSG'
Docker runs on a cgroup v1 host. The k3s release the dojo uses (Kubernetes 1.35) refuses cgroup v1,
so the cluster nodes would never become ready. Use a host or Docker VM with cgroup v2: current
Docker Desktop, Rancher Desktop, colima and Linux distributions from the last few years all use it.
MSG
    exit 1
  fi

  local mem_gib
  mem_gib="$(docker info --format '{{.MemTotal}}' 2>/dev/null | awk '{printf "%d", $1 / 1073741824}')"
  if [[ "$mem_gib" =~ ^[0-9]+$ ]] && (( mem_gib > 0 && mem_gib < 6 )); then
    echo "Warning: Docker reports ${mem_gib} GiB of memory; about 6 GiB is recommended for all labs." >&2
  fi

  # `kubectl debug --custom`, which Labs 07-11 use, is available by default from kubectl 1.31.
  local kubectl_minor
  kubectl_minor="$(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"minor": *"\([0-9]*\).*/\1/p' | head -n 1)"
  if [[ "$kubectl_minor" =~ ^[0-9]+$ ]] && (( kubectl_minor < 31 )); then
    echo "Warning: kubectl 1.${kubectl_minor} lacks 'kubectl debug --custom', which Labs 07-11 use; install kubectl 1.31 or newer." >&2
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

images=()
while IFS= read -r image; do
  images+=("$image")
done <<<"$(local_images)"

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

# The distinct error lines of a k3s node log (read on stdin), oldest first, with a repeat count;
# lines that differ only in numbers (timestamps, ports, PIDs) count as the same. A node that fails
# usually retries the same request every two seconds, so the plain end of the log is one repeated
# line and the cause, logged once at start-up, is far above it. Without error lines, the distinct
# lines of the last 40 are shown instead.
summarize_node_log() {
  awk '
    function add(line, kind,   key) {
      sub(/^time="[^"]*" /, "", line)
      sub(/^[EFW][0-9][0-9][0-9][0-9] [0-9:.]+ +[0-9]+ /, "", line)
      line = substr(line, 1, 300)
      key = line
      gsub(/[0-9]+/, "#", key)
      if (!((kind, key) in count)) { n[kind]++; order[kind, n[kind]] = key; text[kind, key] = line }
      count[kind, key]++
    }
    { last[NR % 40] = $0 }
    /level=(error|fatal)|^[EF][0-9][0-9][0-9][0-9] |^Error|panic:/ { add($0, "err") }
    END {
      kind = "err"
      if (!n["err"]) { kind = "tail"; for (i = (NR > 40 ? NR - 39 : 1); i <= NR; i++) add(last[i % 40], kind) }
      first = n[kind] > 15 ? n[kind] - 14 : 1
      if (first > 1) print "(" first - 1 " earlier distinct lines omitted)"
      for (i = first; i <= n[kind]; i++) {
        key = order[kind, i]
        print text[kind, key] (count[kind, key] > 1 ? "   [x" count[kind, key] "]" : "")
      }
    }'
}

# Print the distinct errors of each node container's log. k3d's own error only says a node "failed
# to get ready"; the reason (a crash-looping k3s agent, a resource limit) is in the container log.
dump_node_logs() {
  local node
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    echo "----- $node ($(docker inspect -f '{{.State.Status}}, restarts={{.RestartCount}}' "$node" 2>/dev/null || echo unknown)) -----" >&2
    docker logs "$node" 2>&1 | summarize_node_log | sed 's/^/    /' >&2 || true
  done <<<"$(docker ps -a --filter "label=k3d.cluster=$CLUSTER" --format '{{.Names}}' 2>/dev/null | sort)"
}

# Create the cluster, retrying when a node fails to come up. --no-rollback keeps the failed node
# containers so their logs can be printed before the cluster is deleted; without it k3d deletes
# them first and the cause is lost. One retry covers a node that fails once at start-up (a k3s
# agent crash-looped on a CI runner while the same commit passed on other runners).
# The Ingress and the Kubernetes API are published on 127.0.0.1 only. The dojo runs privileged and
# node-level debug Pods, so anyone on the network who reached its API (k3d's default binds it to every
# interface) could take over the host. `127.0.0.1:random` keeps k3d's random API port; `:0` would
# write an unusable https://127.0.0.1:0 into the kubeconfig.
create_cluster() {
  local attempt=1 attempts="${CLUSTER_CREATE_ATTEMPTS:-2}"
  while :; do
    echo "==> Creating 1-server + 2-agent k3d cluster (Ingress on 127.0.0.1:$INGRESS_PORT)"
    if k3d cluster create "$CLUSTER" \
      --image "$K3S_IMAGE" \
      --servers 1 \
      --agents 2 \
      --api-port "127.0.0.1:random" \
      --port "127.0.0.1:${INGRESS_PORT}:80@loadbalancer" \
      --wait \
      --timeout "${CLUSTER_START_TIMEOUT:-300}s" \
      --no-rollback; then
      return 0
    fi
    echo "Cluster creation failed (attempt $attempt of $attempts). Node container logs:" >&2
    dump_node_logs
    k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
    (( attempt < attempts )) || { echo "Could not create k3d cluster '$CLUSTER'." >&2; exit 1; }
    attempt=$((attempt + 1))
    sleep 5
  done
}

# Wait until every node container of $CLUSTER is up and stays up. `k3d cluster start --wait` can
# return while a node container is still in Docker's restart loop (a k3s agent or the nginx load
# balancer that started before its peers were reachable, exiting and being restarted by Docker);
# importing images then fails with "container is restarting" or a missing containerd socket. A node
# counts as ready when it is running, its container did not restart during two checks 3 s apart
# and, for servers and agents, containerd's socket exists.
wait_nodes_stable() {
  local deadline=$((SECONDS + ${1:-120})) snapshot previous="" node role ok
  while (( SECONDS < deadline )); do
    ok=1
    snapshot=""
    while IFS=' ' read -r node role; do
      [[ -n "$node" ]] || continue
      # Only cluster nodes count: a k3d tools container left behind by an interrupted image import
      # is not restarted by `k3d cluster start` and would otherwise never look ready.
      case "$role" in server|agent|loadbalancer) ;; *) continue ;; esac
      snapshot+="$node $(docker inspect -f '{{.State.Status}} {{.RestartCount}}' "$node" 2>/dev/null) "
      if [[ "$(docker inspect -f '{{.State.Status}}' "$node" 2>/dev/null)" != running ]]; then
        ok=0
      elif [[ "$role" != loadbalancer ]] \
        && ! docker exec "$node" test -S /run/k3s/containerd/containerd.sock >/dev/null 2>&1; then
        ok=0
      fi
    done <<<"$(docker ps -a --filter "label=k3d.cluster=$CLUSTER" --format '{{.Names}} {{.Label "k3d.role"}}' | sort)"
    # Ready on two consecutive checks with an unchanged status and restart count.
    if (( ok )) && [[ "$snapshot" == "$previous" ]]; then return 0; fi
    previous=""
    (( ! ok )) || previous="$snapshot"
    sleep 3
  done
  return 1
}

# Start a stopped cluster, retrying once from a clean stop when a node fails to come back. After a
# restart k3d sometimes reports the load balancer as "restarting" and never ready, or returns while
# k3s agents are still crash-looping; the same cluster starts fine a moment later. Print the node
# logs for the record, stop everything and try again before giving up.
start_cluster() {
  local attempt=1 attempts="${CLUSTER_START_ATTEMPTS:-2}"
  while :; do
    if k3d cluster start "$CLUSTER" --wait --timeout "${CLUSTER_START_TIMEOUT:-300}s" \
      && wait_nodes_stable "${CLUSTER_STABLE_TIMEOUT:-120}"; then
      return 0
    fi
    echo "Cluster start failed (attempt $attempt of $attempts). Node container logs:" >&2
    dump_node_logs
    (( attempt < attempts )) || { echo "Could not start k3d cluster '$CLUSTER'." >&2; exit 1; }
    attempt=$((attempt + 1))
    k3d cluster stop "$CLUSTER" >/dev/null 2>&1 || true
    sleep 5
    echo "==> Starting the stopped cluster (attempt $attempt of $attempts)"
  done
}

build_local_images "$ROOT" "${images[@]}"
if [[ " ${images[*]} " != *" $ARTHAS_IMAGE "* ]]; then
  if [[ "${DOJO_ARTHAS:-auto}" == 0 || "${DOJO_ARTHAS:-auto}" == no ]]; then
    echo "==> Skipping the Arthas debug image (DOJO_ARTHAS=${DOJO_ARTHAS})"
  else
    echo "==> Skipping the Arthas debug image: the selected labs do not include 08 or 10"
    echo "    (./scripts/rebuild.sh builds and imports it later; DOJO_ARTHAS=1 forces it here)"
  fi
fi

# Capture the pre-dojo context before k3d creates the cluster and switches to it.
remember_previous_context

if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  echo "==> k3d cluster '$CLUSTER' already exists"
  echo "    (running Pods keep their current image; use ./scripts/rebuild.sh to roll out a rebuilt Java image)"
  # `k3d cluster stop` leaves the containers in place; importing into them and waiting for the
  # cluster would otherwise fail only after the component timeouts below.
  if (( $(k3d_stopped_node_count) > 0 )); then
    echo "==> Starting the stopped cluster"
    start_cluster
  fi
else
  if port_is_listening "$INGRESS_PORT"; then
    echo "Host port ${INGRESS_PORT} is already in use. Stop the process using it or set INGRESS_PORT=<port>." >&2
    exit 1
  fi
  create_cluster
fi

# A cluster created before up.sh bound the load balancer to localhost still publishes the Ingress
# and the Kubernetes API on every interface. Its published ports cannot change in place, so warn
# rather than fail: recreating it also redeploys the broken scenarios over any repairs in progress.
exposed="$(published_beyond_localhost)"
if [[ -n "$exposed" ]]; then
  echo "WARNING: cluster '$CLUSTER' publishes ports beyond localhost, so they are reachable from your network:" >&2
  printf '%s\n' "$exposed" | sed 's/^/    /' >&2
  echo "    Recreate it to bind them to 127.0.0.1 (this redeploys every lab): ./scripts/down.sh && ./scripts/up.sh" >&2
fi

echo "==> Importing local images into the nodes"
import_local_images "${images[@]}"

# Optional: load the third-party images into the nodes now instead of pulling them on first use.
#   PRELOAD=runtime  only the images the lab workloads and the checker probe run
#   PRELOAD=all      also every debug image used by LABS.md (about 3 GB)
case "${PRELOAD:-}" in
  ""|0|no) ;;
  runtime) "$ROOT/scripts/preload.sh" --runtime ;;
  all|1|yes) "$ROOT/scripts/preload.sh" --all ;;
  *) echo "Unknown PRELOAD='${PRELOAD}' (use runtime or all)" >&2; exit 2 ;;
esac

if ! context_exists "$CONTEXT"; then
  echo "==> Restoring missing kubeconfig context for '$CLUSTER'"
  k3d kubeconfig merge "$CLUSTER" --kubeconfig-merge-default --kubeconfig-switch-context >/dev/null
fi
kubectl config use-context "$CONTEXT" >/dev/null

# Deploy only the labs whose namespace does not exist yet. Applying broken.yaml over a lab that is
# already there would silently undo the learner's repair; reset-lab.sh and reset-all.sh do that on
# purpose. A namespace that is still being deleted (an interrupted reset) is waited out and redeployed.
to_deploy=()
kept=()
for lab in "${labs[@]}"; do
  ns="$(lab_namespace "$lab")"
  phase=""
  [[ -n "$ns" ]] && phase="$(kubectl --context "$CONTEXT" get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "$phase" == Terminating ]]; then
    echo "==> Waiting for namespace $ns to finish deleting"
    kubectl --context "$CONTEXT" wait --for=delete "namespace/$ns" --timeout=180s >/dev/null 2>&1 \
      || { echo "Timed out waiting for namespace $ns to be deleted" >&2; exit 1; }
    phase=""
  fi
  if [[ -n "$phase" ]]; then kept+=("$lab"); else to_deploy+=("$lab"); fi
done

if (( ${#kept[@]} > 0 )); then
  echo "==> Keeping ${#kept[@]} lab(s) that are already deployed, with any repairs you made"
  for lab in "${kept[@]}"; do echo "    $(basename "$lab")"; done
  echo "    (./scripts/reset-lab.sh <number> or ./scripts/reset-all.sh redeploys the broken scenario)"
fi

# Apply the labs first so their image pulls and JVM starts overlap with K3s installing Traefik and
# metrics-server. Nothing in the lab manifests needs those components to exist when it is created.
if (( ${#to_deploy[@]} > 0 )); then
  echo "==> Deploying ${#to_deploy[@]} debug-pod-focused scenario(s)"
  for lab in "${to_deploy[@]}"; do
    echo "    $(basename "$lab")"
    kubectl --context "$CONTEXT" apply -f "$lab/broken.yaml" >/dev/null
  done
fi

echo "==> Waiting for K3s packaged components used by the labs"
wait_deployment kube-system coredns
wait_deployment kube-system metrics-server
wait_deployment kube-system traefik

# Deployments created above start asynchronously (image pulls, JVM start-up). Wait a bounded time so
# "ready" means ready; the Deployment that is broken on purpose (lab 14's victim) is excluded. Kept
# labs are not waited for: a repair in progress may leave them unavailable on purpose.
wait_labs_ready() {
  local deadline=$((SECONDS + ${LAB_READY_TIMEOUT:-240})) remaining lab ns
  local pending=()
  (( ${#to_deploy[@]} > 0 )) || return 0
  echo "==> Waiting for the lab workloads to start (up to ${LAB_READY_TIMEOUT:-240}s)"
  for lab in "${to_deploy[@]}"; do
    ns="$(lab_namespace "$lab")"
    remaining=$((deadline - SECONDS))
    (( remaining >= 1 )) || remaining=1
    kubectl --context "$CONTEXT" wait --for=condition=Available deployment \
      -l '!dojo-expected-unavailable' -n "$ns" --timeout="${remaining}s" >/dev/null 2>&1 \
      || pending+=("$ns")
  done
  if (( ${#pending[@]} > 0 )); then
    echo "    still starting: ${pending[*]}" >&2
    echo "    this is not an error; follow progress with ./scripts/status.sh" >&2
  fi
}
wait_labs_ready

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
