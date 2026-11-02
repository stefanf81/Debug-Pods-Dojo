#!/usr/bin/env bash
# Keep these scripts runnable on bash 3.2 (the macOS default): no mapfile/readarray, no associative arrays.
CLUSTER="${CLUSTER:-debug-pods-dojo}"
DOJO_CONTEXT="k3d-${CLUSTER}"
# shellcheck source=scripts/images.env
source "$(dirname "${BASH_SOURCE[0]}")/images.env"
PROBE_IMAGE="${PROBE_IMAGE:-$NETSHOOT_IMAGE}"
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
  local wrapped="for i in \$(seq 1 $attempts); do ( $script ) && exit 0; sleep 2; done; exit 1"
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

restore_previous_context() {
  local current file previous
  file="$(context_state_file)"
  [[ -f "$file" ]] || return 0
  previous="$(head -n 1 "$file" 2>/dev/null || true)"
  current="$(kubectl config current-context 2>/dev/null || true)"
  if [[ -z "$previous" ]]; then
    rm -f "$file"
    return 0
  fi
  # Never override a deliberate switch: only take the context back while the dojo still owns it
  # (or while nothing is current, which is what deleting the cluster's context leaves behind).
  if [[ -n "$current" && "$current" != "$DOJO_CONTEXT" ]]; then
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
