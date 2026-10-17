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

# Checks test the lab's success condition (its README), not the exact reference fix, so any
# correct repair passes. Probes run from a short-lived Netshoot Pod inside the lab namespace.
pass() { echo "PASS: $name"; exit 0; }
fail() { echo "NOT FIXED YET: $name"; echo "Hint: $*"; exit 1; }
ready() { wait_rollout "$ns" "$1" || fail "deployment/$1 is not rolled out and ready yet"; }

# The training app lists its live dojo-* fault threads on /stats; an empty list means normal mode.
fault_threads_stopped() {
  local deploy="$1" ips ip
  ready "$deploy"
  ips="$(pod_ips "$ns" "app=$deploy")"
  [[ -n "$ips" ]] || return 1
  for ip in $ips; do
    probe "$ns" "curl -fsS --max-time 3 http://$ip:8080/stats | grep -qx 'dojoThreads='" || return 1
  done
}

case "$num" in
  01)
    ready api
    probe "$ns" 'curl -fsS --max-time 3 http://api:8080/health >/dev/null' \
      && pass || fail "curl http://api:8080/health still fails through the Service"
    ;;
  02)
    ready backend; ready caller
    probe "$ns" 'curl -fsS --max-time 5 http://caller:8080/dependency | grep -q UP' \
      && pass || fail "caller's /dependency still cannot reach the backend"
    ;;
  03)
    ready backend; ready client
    probe "$ns" '! nc -z -w 2 backend 8080' 3 \
      || fail "backend now accepts unlabelled clients; keep the NetworkPolicy and admit the client instead"
    ips="$(pod_ips "$ns" app=client)"
    [[ -n "$ips" ]] || fail "client has no running Pod"
    for ip in $ips; do
      # NetworkPolicy changes converge asynchronously on K3s, so allow ~30s of retries.
      probe "$ns" "curl -fsS --max-time 4 http://$ip:8080/dependency | grep -q UP" 15 \
        || fail "the client workload still cannot reach backend:8080"
    done
    pass
    ;;
  04)
    ready tls-server
    probe "$ns" 'curl -kfsS --max-time 3 https://tls-server/health | grep -q TLS-OK' \
      && pass || fail "https://tls-server/health does not return TLS-OK"
    ;;
  05)
    ready api
    # Same Ingress -> Service -> Pod path as the host URL, via the Traefik Service inside the cluster.
    probe "$ns" 'curl -fsS --max-time 3 http://traefik.kube-system.svc.cluster.local/dojo | grep -q "via Ingress"' 10 \
      && pass || fail "the /dojo Ingress route still does not reach the api Service"
    ;;
  06)
    ready iperf-server
    probe "$ns" 'iperf3 -c iperf-server -t 1 >/dev/null' \
      && pass || fail "iperf3 -c iperf-server still cannot complete a test"
    ;;
  07) fault_threads_stopped api && pass || fail "the dojo-cpu-burner thread is still running" ;;
  08) fault_threads_stopped api && pass || fail "the deadlocked dojo-deadlock-* threads are still present" ;;
  09) fault_threads_stopped api && pass || fail "the dojo-memory-leak thread is still retaining memory" ;;
  10)
    ready api
    probe "$ns" 'curl -fsS --max-time 1 http://api:8080/slow >/dev/null' \
      && pass || fail "/slow still takes longer than 1 second"
    ;;
  11)
    ready writer
    ips="$(pod_ips "$ns" app=writer)"
    [[ -n "$ips" ]] || fail "writer has no running Pod"
    for ip in $ips; do
      probe "$ns" "curl -fsS --max-time 3 http://$ip:8080/write | grep -q wrote" \
        || fail "the Java writer (UID 65532) still cannot write /data/dojo.txt"
    done
    pass
    ;;
  12)
    ready postgres; ready db-client
    for _ in 1 2 3 4 5; do
      if kubectl --context "$DOJO_CONTEXT" -n "$ns" exec deploy/db-client -c client -- \
        sh -c 'PGCONNECT_TIMEOUT=3 psql -h postgres -tAc "select 1"' 2>/dev/null | grep -qx 1; then
        pass
      fi
      sleep 2
    done
    fail "db-client still cannot authenticate to PostgreSQL with its configured credentials"
    ;;
  13) fault_threads_stopped writer && pass || fail "the periodic dojo-pvc-writer is still running" ;;
  14)
    wait_rollout "$ns" port-holder || fail "keep port-holder running; move the victim instead"
    wait_rollout "$ns" victim && pass || fail "victim still cannot schedule; its host port conflicts with a listener on the node"
    ;;
  15)
    ready api
    probe "$ns" 'curl -fsS --max-time 0.3 http://api:8080/slow >/dev/null' \
      && pass || fail "/slow still takes longer than 300 ms"
    ;;
  16) fault_threads_stopped api && pass || fail "the dojo-cpu-burner thread is still running" ;;
  *) echo "No checker for $name" >&2; exit 2 ;;
esac
