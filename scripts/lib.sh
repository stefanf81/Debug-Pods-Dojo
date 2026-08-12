#!/usr/bin/env bash
CLUSTER="${CLUSTER:-debug-pods-dojo}"
DOJO_CONTEXT="k3d-${CLUSTER}"

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

lab_namespace() {
  awk '/^kind: Namespace$/{seen=1; next} seen && /^  name: dojo-/{print $2; exit}' "$1/broken.yaml"
}
