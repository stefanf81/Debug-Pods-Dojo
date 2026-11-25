#!/usr/bin/env bash
# Keep these scripts runnable on bash 3.2 (the macOS default): no mapfile/readarray, no associative arrays.
CLUSTER="${CLUSTER:-debug-pods-dojo}"
DOJO_CONTEXT="k3d-${CLUSTER}"
# shellcheck source=scripts/images.env
source "$(dirname "${BASH_SOURCE[0]}")/images.env"
PROBE_IMAGE="${PROBE_IMAGE:-$NETSHOOT_IMAGE}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-90}"
LAB_IMAGE="debug-dojo-java:local"
ARTHAS_IMAGE="debug-dojo-arthas-jdk21:local"

# The locally built images to provide, one per line. The Java training app always; the Arthas debug
# image (about 700 MB) only when it can be used: DOJO_ARTHAS=1 forces it, DOJO_ARTHAS=0 skips it, and
# by default it is skipped only when LABS selects labs that do not include 08 or 10.
local_images() {
  printf '%s\n' "$LAB_IMAGE"
  case "${DOJO_ARTHAS:-auto}" in
    1|yes) printf '%s\n' "$ARTHAS_IMAGE" ;;
    0|no) ;;
    *)
      local prefix
      [[ -n "${LABS:-}" ]] || { printf '%s\n' "$ARTHAS_IMAGE"; return 0; }
      for prefix in ${LABS//,/ }; do
        [[ "$prefix" =~ ^[0-9]+$ ]] && prefix=$(printf '%02d' "$((10#$prefix))")
        case "$prefix" in 08*|10*) printf '%s\n' "$ARTHAS_IMAGE"; return 0 ;; esac
      done
      ;;
  esac
}

# Build the local images named as arguments (default: both). The distroless Java training app comes
# from images/java-dojo, the Java 21 Arthas debug image from images/arthas-jdk21. DOJO_JAVA_IMAGE
# builds the app under another name first and tags it as $LAB_IMAGE.
build_local_images() {
  local root="$1" image build_image="${DOJO_JAVA_IMAGE:-$LAB_IMAGE}"
  shift
  (( $# > 0 )) || set -- "$LAB_IMAGE" "$ARTHAS_IMAGE"
  for image in "$@"; do
    case "$image" in
      "$LAB_IMAGE")
        echo "==> Building distroless Java training image"
        docker build -t "$build_image" "$root/images/java-dojo"
        if [[ "$build_image" != "$LAB_IMAGE" ]]; then
          docker tag "$build_image" "$LAB_IMAGE"
        fi
        ;;
      "$ARTHAS_IMAGE")
        echo "==> Building Java 21 Arthas debug image"
        docker build -t "$ARTHAS_IMAGE" "$root/images/arthas-jdk21"
        ;;
      *) echo "build_local_images: unknown image $image" >&2; return 1 ;;
    esac
  done
}

require_dojo_context() {
  command -v kubectl >/dev/null 2>&1 || { echo "Missing required command: kubectl" >&2; exit 1; }
  local current
  current="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$current" != "$DOJO_CONTEXT" ]]; then
    cat >&2 <<EOF
Refusing to run against Kubernetes context: ${current:-<none>}
Expected disposable context: $DOJO_CONTEXT

EOF
    if context_exists "$DOJO_CONTEXT"; then
      echo "Switch explicitly with:" >&2
      echo "  kubectl config use-context $DOJO_CONTEXT" >&2
    elif command -v k3d >/dev/null 2>&1 && k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
      # Another tool rewrote ~/.kube/config and dropped the dojo's entry; the cluster itself is fine.
      echo "The cluster '$CLUSTER' is running, but its kubeconfig context is missing. Restore it with:" >&2
      echo "  k3d kubeconfig merge $CLUSTER --kubeconfig-merge-default --kubeconfig-switch-context" >&2
    else
      echo "The cluster '$CLUSTER' does not exist. Create it with ./scripts/up.sh" >&2
    fi
    exit 1
  fi
}

find_lab() {
  local root="$1" prefix="$2"
  if [[ "$prefix" =~ ^[0-9]+$ ]]; then
    prefix=$(printf '%02d' "$((10#$prefix))")
  fi
  local matches=() match
  while IFS= read -r match; do
    matches+=("$match")
  done < <(find "$root/labs" -mindepth 1 -maxdepth 1 -type d -name "${prefix}*" -print | sort)
  if (( ${#matches[@]} == 0 )); then
    echo "Lab not found: $prefix" >&2
    return 1
  fi
  if (( ${#matches[@]} > 1 )); then
    echo "Ambiguous lab prefix '$prefix':" >&2
    printf '  %s\n' "${matches[@]##*/}" >&2
    return 1
  fi
  printf '%s\n' "${matches[0]}"
}

# Lab directories selected by LABS (space- or comma-separated numbers/prefixes); all labs when unset.
selected_labs() {
  local root="$1" lab prefix
  if [[ -z "${LABS:-}" ]]; then
    for lab in "$root"/labs/*; do
      [[ -f "$lab/broken.yaml" ]] && printf '%s\n' "$lab"
    done
    return 0
  fi
  for prefix in ${LABS//,/ }; do
    find_lab "$root" "$prefix" || return 1
  done
}

lab_namespace() {
  awk '/^kind: Namespace$/{seen=1; next} seen && /^  name: dojo-/{print $2; exit}' "$1/broken.yaml"
}

wait_rollout() {
  local ns="$1" deploy="$2"
  kubectl --context "$DOJO_CONTEXT" -n "$ns" rollout status deployment/"$deploy" --timeout="${CHECK_TIMEOUT}s" >/dev/null 2>&1
}

# IPs of the selected Pods that are not terminating, space separated.
pod_ips() {
  local ns="$1" selector="$2"
  kubectl --context "$DOJO_CONTEXT" -n "$ns" get pods -l "$selector" \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{if .status.podIP}}{{.status.podIP}} {{end}}{{end}}{{end}}' 2>/dev/null
}

# Run a shell snippet in a throwaway Netshoot Pod in the namespace, retrying up to <attempts>
# times two seconds apart. Succeeds only if one attempt exits 0. CHECK_VERBOSE=1 prints the Pod log.
# A probe Pod that cannot be created or does not finish (image pull failure, unschedulable) says
# nothing about the lab, so that is reported as a check error and the script exits 2.
probe() {
  local ns="$1" script="$2" attempts="${3:-5}"
  local name="dojo-check-${RANDOM}${RANDOM}" phase="" reason="" k=(kubectl --context "$DOJO_CONTEXT" -n "$ns")
  local wrapped="for i in \$(seq 1 $attempts); do ( $script ) && exit 0; [ \$i -lt $attempts ] && sleep 2; done; exit 1"
  if ! "${k[@]}" run "$name" --restart=Never --image="$PROBE_IMAGE" --labels=dojo-check=true \
    --command -- sh -c "$wrapped" >/dev/null; then
    echo "CHECK ERROR: could not create the probe Pod in namespace $ns" >&2
    exit 2
  fi
  # Do not leave the probe Pod behind if the check is interrupted. The trap expands now on purpose:
  # ns and name are locals and would be out of scope when the signal arrives.
  # shellcheck disable=SC2064
  trap "kubectl --context '$DOJO_CONTEXT' -n '$ns' delete pod '$name' --wait=false >/dev/null 2>&1; exit 130" INT TERM
  for _ in $(seq 1 $((CHECK_TIMEOUT + attempts * 8))); do
    phase="$("${k[@]}" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 1
  done
  if [[ "$phase" != "Succeeded" && "$phase" != "Failed" ]]; then
    reason="$("${k[@]}" get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}{.status.conditions[?(@.type=="PodScheduled")].reason}' 2>/dev/null || true)"
    "${k[@]}" delete pod "$name" --wait=false >/dev/null 2>&1 || true
    echo "CHECK ERROR: the probe Pod did not finish (phase: ${phase:-unknown}${reason:+, $reason}), so the lab could not be checked." >&2
    echo "The probe uses $PROBE_IMAGE; make sure the cluster can pull it, then run the check again." >&2
    exit 2
  fi
  [[ -n "${CHECK_VERBOSE:-}" ]] && "${k[@]}" logs "$name" >&2 2>/dev/null
  "${k[@]}" delete pod "$name" --wait=false >/dev/null 2>&1 || true
  trap - INT TERM
  [[ "$phase" == "Succeeded" ]]
}

# --- loading images into the k3d nodes ----------------------------------------
# Running k3d node containers of $CLUSTER, one per line (servers first).
k3d_node_containers() {
  local role
  for role in server agent; do
    docker ps --filter "label=k3d.cluster=$CLUSTER" --filter "label=k3d.role=$role" --format '{{.Names}}'
  done
}

# Port bindings of the $CLUSTER load balancer (the Ingress and the Kubernetes API) that are not on
# 127.0.0.1, one "<port>/tcp -> <address>:<port>" per line; nothing when every binding is local or
# the load balancer is not running. up.sh creates the cluster with localhost-only bindings.
published_beyond_localhost() {
  docker port "k3d-${CLUSTER}-serverlb" 2>/dev/null | grep -v -- '-> 127\.0\.0\.1:' || true
}

# Number of k3d server/agent containers of $CLUSTER that exist but are not running (a stopped cluster).
k3d_stopped_node_count() {
  local all running
  all="$(docker ps -a -q --filter "label=k3d.cluster=$CLUSTER" --filter "label=k3d.role=server" | wc -l)"
  all=$((all + $(docker ps -a -q --filter "label=k3d.cluster=$CLUSTER" --filter "label=k3d.role=agent" | wc -l)))
  running="$(k3d_node_containers | grep -c . || true)"
  echo $((all - running))
}

# Digests that identify the local image <name> for node_has_local_image, one per line: Docker's
# image ID and, where Docker can report it, the manifest for its own platform. With Docker's
# containerd image store the ID is an index digest that changes on every build, even a fully cached
# one (BuildKit writes a new attestation manifest), while the platform manifest stays the same; with
# the classic store the ID is the image config digest, which is also stable.
local_image_digests() {
  local platform
  docker image inspect -f '{{.Id}}' "$1" || return 1
  platform="$(docker version -f '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null || true)"
  [[ -n "$platform" ]] && docker image inspect --platform "$platform" -f '{{.Id}}' "$1" 2>/dev/null || true
}

# True when the node holds the local image <name> with one of the given digests: the digest the
# image name points to, a digest that target references (an index lists its platform manifests, a
# manifest its config) or the config digest crictl reports as the image ID.
node_has_local_image() {
  local node="$1" ref="docker.io/library/$2" digests="$3"
  # shellcheck disable=SC2016
  docker exec "$node" sh -c '
    t="$(ctr -n k8s.io images ls 2>/dev/null | awk -v ref="$1" "\$1 == ref {print \$3}")"
    [ -n "$t" ] || exit 0
    echo "$t"
    ctr -n k8s.io content get "$t" 2>/dev/null | grep -o "sha256:[0-9a-f]*"
    crictl inspecti -o go-template --template "{{.status.id}}" "$1" 2>/dev/null' _ "$ref" \
    | grep -xF -f <(printf '%s\n' "$digests" | grep .) >/dev/null
}

# Import the local images named as arguments (default: both) into every node, skipping nodes that
# already hold the same build, and prove it worked. `k3d image import` can print "Successfully
# imported" and exit 0 while the nodes failed to read its tarball (seen on CI runners); the Java labs
# then never start because the local image cannot be pulled. So check each node and fall back to
# loading the image with Docker directly.
import_local_images() {
  local image id node tarball tmp stale nodes=()
  (( $# > 0 )) || set -- "$LAB_IMAGE" "$ARTHAS_IMAGE"
  while IFS= read -r node; do
    [[ -n "$node" ]] && nodes+=("$node")
  done <<<"$(k3d_node_containers)"
  (( ${#nodes[@]} > 0 )) || { echo "No running k3d nodes found for cluster '$CLUSTER'." >&2; return 1; }
  tmp="$(mktemp -d)"
  for image in "$@"; do
    id="$(local_image_digests "$image")" \
      || { rm -rf "$tmp"; echo "Local image $image does not exist; build it first." >&2; return 1; }
    stale=()
    for node in "${nodes[@]}"; do
      node_has_local_image "$node" "$image" "$id" || stale+=("$node")
    done
    if (( ${#stale[@]} == 0 )); then
      echo "    $image is up to date on all ${#nodes[@]} node(s)"
      continue
    fi
    k3d image import -c "$CLUSTER" "$image" || true
    tarball=""
    for node in "${stale[@]}"; do
      node_has_local_image "$node" "$image" "$id" && continue
      echo "    $node is missing $image after k3d image import; loading it with docker save"
      if [[ -z "$tarball" ]]; then
        tarball="$tmp/image.tar"
        docker save "$image" -o "$tarball"
      fi
      docker cp "$tarball" "$node:/tmp/local-image.tar"
      docker exec "$node" ctr -n k8s.io images import /tmp/local-image.tar >/dev/null
      docker exec "$node" rm -f /tmp/local-image.tar >/dev/null 2>&1 || true
      node_has_local_image "$node" "$image" "$id" \
        || { rm -rf "$tmp"; echo "Could not load $image into $node." >&2; return 1; }
    done
    rm -f "$tmp/image.tar"
  done
  rm -rf "$tmp"
}

# --- running checks -----------------------------------------------------------
# Run check-lab.sh for each lab directory given, <jobs> at a time. For lab NN, the output goes to
# <outdir>/NN.out and the exit status to <outdir>/NN.rc.
run_lab_checks() {
  local root="$1" outdir="$2" max="$3" lab num
  shift 3
  for lab in "$@"; do
    num="$(basename "$lab")"
    num="${num%%-*}"
    while (( $(jobs -rp | wc -l) >= max )); do sleep 0.5; done
    (
      rc=0
      "$root/scripts/check-lab.sh" "$num" >"$outdir/$num.out" 2>&1 || rc=$?
      echo "$rc" >"$outdir/$num.rc"
    ) &
  done
  wait
}

# --- kubectl context handover -------------------------------------------------
# up.sh switches the user's kubectl context to the disposable cluster. Save the context that was
# active before the switch so down.sh can restore it. The state file is keyed by cluster name so
# side-by-side dojos (the E2E clusters, or two clusters created with different CLUSTER values) do
# not overwrite each other.
context_state_file() {
  printf '%s/debug-pods-dojo/%s.previous-context\n' \
    "${XDG_STATE_HOME:-$HOME/.local/state}" "$CLUSTER"
}

remember_previous_context() {
  local current file
  current="$(kubectl config current-context 2>/dev/null || true)"
  # Re-running up.sh while the dojo is already current must not overwrite the saved context.
  [[ -n "$current" && "$current" != "$DOJO_CONTEXT" ]] || return 0
  file="$(context_state_file)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  printf '%s\n' "$current" >"$file" 2>/dev/null || true
}

context_exists() {
  kubectl config get-contexts "$1" >/dev/null 2>&1
}

# True when the dojo's context is the current kubectl context, or none is (the cluster was deleted
# some other way). Check it before deleting the cluster: when k3d deletes the current context, it
# makes some other remaining context current, not necessarily the one from before, so afterwards
# k3d's pick would look like a deliberate switch.
dojo_context_is_current() {
  local current
  current="$(kubectl config current-context 2>/dev/null || true)"
  [[ -z "$current" || "$current" == "$DOJO_CONTEXT" ]]
}

# Switch back to the saved context when <dojo-was-current> is "yes", i.e. the dojo's context was
# still current before the cluster was deleted. Otherwise the learner switched deliberately after
# up.sh, and that context is left alone.
restore_previous_context() {
  local file previous
  file="$(context_state_file)"
  [[ -f "$file" ]] || return 0
  previous="$(head -n 1 "$file" 2>/dev/null || true)"
  if [[ -z "$previous" || "${1:-}" != yes ]]; then
    rm -f "$file"
    return 0
  fi
  if ! context_exists "$previous"; then
    echo "Previous kubectl context '$previous' no longer exists; leaving the current context unchanged." >&2
    rm -f "$file"
    return 0
  fi
  # Keep the saved state until the switch has actually worked, so a failure can be retried.
  if kubectl config use-context "$previous" >/dev/null; then
    rm -f "$file"
    echo "Restored kubectl context: $previous"
  else
    echo "Could not switch back to '$previous'; run: kubectl config use-context $previous" >&2
  fi
}

forget_previous_context() {
  rm -f "$(context_state_file)" 2>/dev/null || true
}
