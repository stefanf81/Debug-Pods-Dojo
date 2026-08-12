#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
require_dojo_context

num="${1:-}"
[[ -n "$num" ]] || { echo "Usage: $0 <lab-number-or-prefix>" >&2; exit 2; }
lab="$(find_lab "$ROOT" "$num")"
name="$(basename "$lab")"
ns="$(lab_namespace "$lab")"
num="${name%%-*}"

pass() { echo "PASS: $name"; exit 0; }
fail() { echo "NOT FIXED YET: $name"; echo "Hint: $*"; exit 1; }
jp() { kubectl --context "$DOJO_CONTEXT" -n "$ns" get "$1" -o "jsonpath=$2" 2>/dev/null || true; }

case "$num" in
  01) [[ "$(jp svc/api '{.spec.ports[0].targetPort}')" == "8080" ]] && pass || fail "Service still targets the wrong application port" ;;
  02) [[ "$(jp deploy/caller '{.spec.template.spec.containers[0].env[0].value}')" == "http://backend:8080/health" ]] && pass || fail "caller still uses the wrong dependency hostname" ;;
  03) [[ "$(jp deploy/client '{.spec.template.metadata.labels.access}')" == "allowed" ]] && pass || fail "client still lacks the label admitted by NetworkPolicy" ;;
  04) [[ "$(jp svc/tls-server '{.spec.ports[0].targetPort}')" == "8443" ]] && pass || fail "HTTPS Service still targets the plain HTTP port" ;;
  05) [[ "$(jp ingress/api '{.spec.rules[0].http.paths[0].backend.service.port.number}')" == "8080" ]] && pass || fail "Ingress still points to the wrong Service port" ;;
  06) [[ "$(jp svc/iperf-server '{.spec.ports[0].targetPort}')" == "5201" ]] && pass || fail "iperf Service still targets the wrong port" ;;
  07) [[ "$(jp deploy/api '{.spec.template.spec.containers[0].env[0].value}')" == "normal" ]] && pass || fail "CPU burner is still enabled" ;;
  08) [[ "$(jp deploy/api '{.spec.template.spec.containers[0].env[0].value}')" == "normal" ]] && pass || fail "deadlock mode is still enabled" ;;
  09) [[ "$(jp deploy/api '{.spec.template.spec.containers[0].env[0].value}')" == "normal" ]] && pass || fail "memory leak mode is still enabled" ;;
  10) [[ "$(jp deploy/api '{.spec.template.spec.containers[0].env[0].value}')" == "100" ]] && pass || fail "slowWork delay is still the broken value" ;;
  11)
    cmd="$(jp deploy/writer '{.spec.template.spec.initContainers[0].command[2]}')"
    [[ "$cmd" == *"chown 65532:65532 /data"* && "$cmd" == *"chmod 0770 /data"* ]] && pass || fail "PVC ownership/permissions are not prepared for UID 65532"
    ;;
  12) [[ "$(jp deploy/db-client '{.spec.template.spec.containers[0].env[2].valueFrom.secretKeyRef.name}')" == "postgres-auth" ]] && pass || fail "db-client still uses a bad literal password" ;;
  13) [[ "$(jp deploy/writer '{.spec.template.spec.containers[0].env[0].value}')" == "normal" ]] && pass || fail "periodic writer is still enabled" ;;
  14) [[ "$(jp deploy/victim '{.spec.template.spec.containers[0].ports[0].hostPort}')" == "18081" ]] && pass || fail "victim still requests the occupied host port" ;;
  15) [[ "$(jp deploy/api '{.spec.template.spec.containers[0].env[0].value}')" == "50" ]] && pass || fail "slow endpoint is still at the broken delay" ;;
  16) [[ "$(jp deploy/api '{.spec.template.spec.containers[0].env[0].value}')" == "normal" ]] && pass || fail "CPU burner is still enabled" ;;
  *) echo "No checker for $name" >&2; exit 2 ;;
esac
