#!/usr/bin/env bash
CLUSTER="${CLUSTER:-debug-pods-dojo}"
DOJO_CONTEXT="k3d-${CLUSTER}"
PROBE_IMAGE="${PROBE_IMAGE:-nicolaka/netshoot:v0.16}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-90}"

require_dojo_context() {
  command -v kubectl >/dev/null 2>&1 || { echo "Missing required command: kubectl" >&2; exit 1; }
  local current
  current="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$current" != "$DOJO_CONTEXT" ]]; then
    cat >&2 <<EOF
Refusing to run against Kubernetes context: ${current:-<none>}
Expected disposable context: $DOJO_CONTEXT

Switch explicitly with:
  kubectl config use-context $DOJO_CONTEXT
EOF
    exit 1
  fi
}

find_lab() {
  local root="$1" prefix="$2"
  if [[ "$prefix" =~ ^[0-9]+$ ]]; then
    prefix=$(printf '%02d' "$((10#$prefix))")
  fi
  local matches=()
  mapfile -t matches < <(find "$root/labs" -mindepth 1 -maxdepth 1 -type d -name "${prefix}*" -print | sort)
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
probe() {
  local ns="$1" script="$2" attempts="${3:-5}"
  local name="dojo-check-${RANDOM}${RANDOM}" phase="" k=(kubectl --context "$DOJO_CONTEXT" -n "$ns")
  local wrapped="for i in \$(seq 1 $attempts); do ( $script ) && exit 0; sleep 2; done; exit 1"
  "${k[@]}" run "$name" --restart=Never --image="$PROBE_IMAGE" --labels=dojo-check=true \
    --command -- sh -c "$wrapped" >/dev/null || return 1
  for _ in $(seq 1 $((CHECK_TIMEOUT + attempts * 8))); do
    phase="$("${k[@]}" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 1
  done
  [[ -n "${CHECK_VERBOSE:-}" ]] && "${k[@]}" logs "$name" >&2 2>/dev/null
  "${k[@]}" delete pod "$name" --wait=false >/dev/null 2>&1 || true
  [[ "$phase" == "Succeeded" ]]
}
