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
[[ -n "$ns" ]] || { echo "Could not determine namespace for $name" >&2; exit 2; }
if ! kubectl --context "$DOJO_CONTEXT" get namespace "$ns" >/dev/null 2>&1; then
  echo "$name is not deployed (namespace $ns not found). Deploy it with: ./scripts/reset-lab.sh $num" >&2
  exit 2
fi

# Checks test the lab's success condition (its README), not the exact reference fix, so any
# correct repair passes. Probes run from a short-lived Netshoot Pod inside the lab namespace.
# Exit status: 0 fixed, 1 not fixed yet, 2 the check itself could not run.
pass() { echo "PASS: $name"; exit 0; }
fail() { echo "NOT FIXED YET: $name"; echo "Hint: $*"; echo "(CHECK_VERBOSE=1 ./scripts/check-lab.sh $num shows what the probe saw)"; exit 1; }
ready() { wait_rollout "$ns" "$1" || fail "deployment/$1 is not rolled out and ready yet"; }

# Probe script: <base-url>/dependency must answer UP from the backend Service. The app echoes its
# target as "dependency=<url>", so pointing DEPENDENCY_URL at any other endpoint that answers UP fails.
reaches_backend() {
  local base="$1" max_time="$2"
  echo "b=\$(curl -fsS --max-time $max_time $base/dependency) && echo \"\$b\" | grep -q '^dependency=http://backend[.:/]' && echo \"\$b\" | grep -qx UP"
}

# The training app lists its live dojo-* fault threads on /stats; an empty list means normal mode.
# The Java Deployments have a readiness probe, so once `ready` returns the app answers and its fault
# mode cannot change any more: a second attempt only covers a transient network error.
fault_threads_stopped() {
  local deploy="$1" ips ip
  ready "$deploy"
  ips="$(pod_ips "$ns" "app=$deploy")"
  [[ -n "$ips" ]] || return 1
  for ip in $ips; do
    probe "$ns" "curl -fsS --max-time 3 http://$ip:8080/stats | grep -qx 'dojoThreads='" 2 || return 1
  done
}

# True when the scheduler rejected a Pod of the victim Deployment's current revision. Pods of an
# older revision are ignored, so a repair that is still rolling out is not mistaken for a failure.
victim_unschedulable() {
  local k=(kubectl --context "$DOJO_CONTEXT" -n "$ns") out gen observed rev hash
  out="$("${k[@]}" get deployment victim -o jsonpath='{.metadata.generation} {.status.observedGeneration} {.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null)" || return 1
  read -r gen observed rev <<<"$out"
  # Until the controller has seen the latest spec, the revision annotation may still be the old one.
  [[ -n "$rev" && "$gen" == "$observed" ]] || return 1
  hash="$("${k[@]}" get replicasets -l app=victim \
    -o jsonpath='{range .items[*]}{.metadata.annotations.deployment\.kubernetes\.io/revision} {.metadata.labels.pod-template-hash}{"\n"}{end}' 2>/dev/null \
    | awk -v rev="$rev" '$1 == rev {print $2; exit}')"
  [[ -n "$hash" ]] || return 1
  "${k[@]}" get pods -l "app=victim,pod-template-hash=$hash" \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="PodScheduled")].reason}{"\n"}{end}' 2>/dev/null \
    | grep -qx Unschedulable
}

case "$num" in
  01)
    ready api
    probe "$ns" 'curl -fsS --max-time 3 http://api:8080/health >/dev/null' \
      && pass || fail "curl http://api:8080/health still fails through the Service"
    ;;
  02)
    ready backend; ready caller
    probe "$ns" "$(reaches_backend http://caller:8080 5)" \
      && pass || fail "caller's /dependency still does not reach the backend Service"
    ;;
  03)
    ready backend; ready client
    ips="$(pod_ips "$ns" app=client)"
    [[ -n "$ips" ]] || fail "client has no running Pod"
    for ip in $ips; do
      # NetworkPolicy changes converge asynchronously on K3s, so allow ~30s of retries.
      probe "$ns" "$(reaches_backend "http://$ip:8080" 4)" 15 \
        || fail "the client workload still cannot reach backend:8080"
    done
    # Only now that the dataplane has converged: an unlabelled Pod must be refused on every attempt,
    # so a deleted or loosened policy cannot pass on a deny rule that has not been removed yet.
    probe "$ns" 'for i in 1 2 3; do if nc -z -w 2 backend 8080; then exit 1; fi; sleep 1; done' 1 \
      || fail "backend now accepts unlabelled clients; keep the NetworkPolicy and admit the client instead"
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
    probe "$ns" 'curl -fsS --max-time 1 http://api:8080/slow >/dev/null' 2 \
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
    authenticated=""
    for _ in 1 2 3 4 5; do
      if kubectl --context "$DOJO_CONTEXT" -n "$ns" exec deploy/db-client -c client -- \
        sh -c 'PGCONNECT_TIMEOUT=3 psql -h postgres -tAc "select 1"' 2>/dev/null | grep -qx 1; then
        authenticated=1
        break
      fi
      sleep 2
    done
    [[ -n "$authenticated" ]] || fail "db-client still cannot authenticate to PostgreSQL with its configured credentials"
    # The success condition is authenticating "with the Secret", so a password copied into the manifest does not pass.
    literal="$(kubectl --context "$DOJO_CONTEXT" -n "$ns" get deployment db-client \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="client")].env[?(@.name=="PGPASSWORD")].value}' 2>/dev/null || true)"
    [[ -z "$literal" ]] && pass || fail "db-client authenticates, but PGPASSWORD is a literal value in the manifest; read it from the postgres-auth Secret"
    ;;
  13) fault_threads_stopped writer && pass || fail "the periodic dojo-pvc-writer is still running" ;;
  14)
    wait_rollout "$ns" port-holder || fail "keep port-holder running; move the victim instead"
    # The broken victim never schedules, so do not spend the whole CHECK_TIMEOUT waiting for it:
    # stop as soon as the scheduler has rejected a Pod of the current revision.
    deadline=$((SECONDS + CHECK_TIMEOUT))
    until kubectl --context "$DOJO_CONTEXT" -n "$ns" rollout status deployment/victim --timeout=2s >/dev/null 2>&1; do
      victim_unschedulable && fail "victim still cannot schedule; its host port conflicts with a listener on the node"
      (( SECONDS < deadline )) || fail "victim is not rolled out and ready yet"
    done
    pass
    ;;
  15)
    ready api
    probe "$ns" 'curl -fsS --max-time 0.3 http://api:8080/slow >/dev/null' 2 \
      && pass || fail "/slow still takes longer than 300 ms"
    ;;
  16) fault_threads_stopped api && pass || fail "the dojo-cpu-burner thread is still running" ;;
  *) echo "No checker for $name" >&2; exit 2 ;;
esac
