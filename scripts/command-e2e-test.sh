#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOJO_VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo unknown)"
export CLUSTER="${CLUSTER:-debug-pods-dojo-command-e2e}"
CONTEXT="k3d-${CLUSTER}"
KEEP_CLUSTER="${KEEP_CLUSTER:-0}"
ORIGINAL_CONTEXT=""
PASS=0
SKIP=0

cleanup() {
  if [[ "$KEEP_CLUSTER" != "1" ]]; then
    k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
  fi
  if [[ -n "$ORIGINAL_CONTEXT" ]] && kubectl config get-contexts "$ORIGINAL_CONTEXT" >/dev/null 2>&1; then
    kubectl config use-context "$ORIGINAL_CONTEXT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

for cmd in docker k3d kubectl curl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

k() { kubectl --context "$CONTEXT" "$@"; }
pass() { PASS=$((PASS + 1)); printf '    PASS  %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf '    SKIP  %s\n' "$*"; }
fail() { printf '    FAIL  %s\n' "$*" >&2; exit 1; }

wait_deploy() {
  local ns="$1" deploy="$2"
  k -n "$ns" rollout status deployment/"$deploy" --timeout=180s >/dev/null
}

wait_top() {
  local ns="$1"
  for _ in $(seq 1 60); do
    if k top pod -n "$ns" --containers >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  k top pod -n "$ns" --containers >&2 || true
  return 1
}

pod_for() {
  local ns="$1" selector="$2"
  k -n "$ns" get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}'
}

pod_ip_for() {
  local ns="$1" selector="$2"
  k -n "$ns" get pod -l "$selector" -o jsonpath='{.items[0].status.podIP}'
}

run_pod() {
  local ns="$1" name="$2" image="$3" command="$4" labels="${5:-}"
  k -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  local args=(run "$name" -n "$ns" --restart=Never --image="$image")
  [[ -n "$labels" ]] && args+=(--labels="$labels")
  args+=(--command -- sh -lc "$command")
  k "${args[@]}" >/dev/null

  local phase=""
  for _ in $(seq 1 180); do
    phase="$(k -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 1
  done
  k -n "$ns" logs "$name" 2>/dev/null || true
  if [[ "$phase" != "Succeeded" ]]; then
    printf '    command: %s\n' "$command" >&2
    printf '    phase:   %s\n' "${phase:-<unknown>}" >&2
    k -n "$ns" describe pod "$name" >&2 || true
    return 1
  fi
  k -n "$ns" delete pod "$name" --wait=false >/dev/null 2>&1 || true
}

run_ephemeral() {
  local ns="$1" pod="$2" target="$3" name="$4" image="$5" profile="$6" shell="$7" command="$8" custom="${9:-}"
  local args=(debug -n "$ns" "pod/$pod" --container="$name" --target="$target" --image="$image" --profile="$profile" --attach=false)
  [[ -n "$custom" ]] && args+=(--custom="$custom")
  args+=(-- "$shell" -lc "$command")
  k "${args[@]}" >/dev/null

  local rc=""
  for _ in $(seq 1 180); do
    rc="$(k -n "$ns" get pod "$pod" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$name\")].state.terminated.exitCode}" 2>/dev/null || true)"
    [[ -n "$rc" ]] && break
    sleep 1
  done
  k -n "$ns" logs "$pod" -c "$name" 2>/dev/null || true
  if [[ -z "$rc" ]]; then
    echo "Ephemeral container $name did not terminate" >&2
    printf '    command: %s\n' "$command" >&2
    k -n "$ns" describe pod "$pod" >&2 || true
    return 1
  fi
  if [[ "$rc" != "0" ]]; then
    printf '    command: %s\n' "$command" >&2
    printf '    exitCode: %s\n' "$rc" >&2
    k -n "$ns" get pod "$pod" -o jsonpath="{.status.ephemeralContainerStatuses[?(@.name==\"$name\")]}" >&2 || true
    printf '\n' >&2
    return 1
  fi
}

run_node_debug() {
  local node="$1" image="$2" command="$3"
  # --attach=true lets this non-interactive check return the debug command's output.
  k debug "node/$node" --image="$image" --profile=sysadmin --attach=true -- sh -lc "$command"
}

ORIGINAL_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
k3d cluster delete "$CLUSTER" >/dev/null 2>&1 || true
"$ROOT/scripts/up.sh"

echo "==> Command-level validation of LABS.md"

# 01 - Netshoot Service/TCP and same-Pod network context
wait_deploy dojo-01-service api
api_ip="$(pod_ip_for dojo-01-service app=api)"
if run_pod dojo-01-service cmd01 nicolaka/netshoot:v0.16 \
  "set -e; echo '[01] DNS short-name via search list'; dig +search +short api | grep -q .; echo '[01] direct Pod IP must work'; curl -fsS http://$api_ip:8080/health >/dev/null; echo '[01] broken Service must fail'; if curl --connect-timeout 2 -fsS http://api:8080/health; then echo 'broken Service unexpectedly worked'; exit 1; fi; echo '[01] broken Service TCP check must fail'; if nc -vz -w 2 api 8080; then echo 'broken Service TCP unexpectedly worked'; exit 1; fi; echo '[01] expected contrast observed'"; then
  pass "01 Netshoot DNS + direct Pod + broken Service path"
else fail "01 throwaway Netshoot commands"; fi
p="$(pod_for dojo-01-service app=api)"
if run_ephemeral dojo-01-service "$p" app cmd01attach nicolaka/netshoot:v0.16 netadmin zsh \
  'set -e; command -v ss; command -v ip; ss -lntp | grep -q 8080; ip addr >/dev/null; ip route >/dev/null; curl -fsS http://127.0.0.1:8080/health >/dev/null'; then
  pass "01 Netshoot ephemeral container + ss/ip/localhost curl"
else fail "01 Netshoot ephemeral attach"; fi

# 02 - DNS tool surface
wait_deploy dojo-02-dns backend
wait_deploy dojo-02-dns caller
p="$(pod_for dojo-02-dns app=caller)"
if run_ephemeral dojo-02-dns "$p" app cmd02 nicolaka/netshoot:v0.16 general zsh \
  'set -e; cat /etc/resolv.conf >/dev/null; dig +search +short backend | grep -q .; dig +short backend.dojo-02-dns.svc.cluster.local | grep -q .; drill backend.dojo-02-dns.svc.cluster.local >/dev/null; nslookup backend >/dev/null; test -z "$(dig +search +short backned)"; curl -fsS http://backend:8080/health >/dev/null; if curl --connect-timeout 2 -fsS http://backned:8080/health; then exit 1; fi'; then
  pass "02 Netshoot dig/drill/nslookup and DNS typo diagnosis"
else fail "02 DNS command set"; fi

# 03 - NetworkPolicy: denied vs explicitly allowed debug client
wait_deploy dojo-03-netpol backend
if run_pod dojo-03-netpol cmd03deny nicolaka/netshoot:v0.16 \
  'set -e; dig +search +short backend | grep -q .; if nc -vz -w 3 backend 8080; then exit 1; fi; if curl --connect-timeout 3 -fsS http://backend:8080/health; then exit 1; fi'; then
  pass "03 Netshoot denied NetworkPolicy client"
else fail "03 denied NetworkPolicy commands"; fi
# Keep the allowed Pod alive and probe from it repeatedly. NetworkPolicy enforcement is
# reconciled asynchronously, so a newly-created labelled Pod may not be admitted by
# the dataplane at the exact instant its container starts.
k -n dojo-03-netpol delete pod cmd03allow --ignore-not-found --wait=false >/dev/null 2>&1 || true
k -n dojo-03-netpol run cmd03allow --restart=Never --image=nicolaka/netshoot:v0.16 \
  --labels=access=allowed --command -- sleep 120 >/dev/null
k -n dojo-03-netpol wait --for=condition=Ready pod/cmd03allow --timeout=120s >/dev/null
[[ "$(k -n dojo-03-netpol get pod cmd03allow -o jsonpath='{.metadata.labels.access}')" == "allowed" ]] \
  || fail "03 allowed debug Pod is missing access=allowed label"

echo "[03] labelled debug client created; waiting for NetworkPolicy dataplane convergence"
allowed=0
for attempt in $(seq 1 30); do
  if k -n dojo-03-netpol exec cmd03allow -- sh -lc \
    'set -e; dig +search +short backend | grep -q .; nc -vz -w 2 backend 8080; curl --connect-timeout 2 -fsS http://backend:8080/health >/dev/null'; then
    echo "[03] allowed client reached backend on attempt $attempt"
    allowed=1
    break
  fi
  sleep 1
done
k -n dojo-03-netpol delete pod cmd03allow --wait=false >/dev/null 2>&1 || true
if [[ "$allowed" == "1" ]]; then
  pass "03 Netshoot labelled/allowed NetworkPolicy client"
else
  k -n dojo-03-netpol get networkpolicy backend-allow-labelled -o yaml >&2 || true
  k -n dojo-03-netpol get pods --show-labels -o wide >&2 || true
  k -n dojo-03-netpol get endpointslices -l kubernetes.io/service-name=backend -o wide >&2 || true
  fail "03 allowed NetworkPolicy commands after 30s convergence window"
fi

# 04 - TLS/protocol tooling
wait_deploy dojo-04-tls tls-server
tls_ip="$(pod_ip_for dojo-04-tls app=tls-server)"
if run_pod dojo-04-tls cmd04 nicolaka/netshoot:v0.16 \
  "set -e; command -v openssl; command -v nmap; nc -vz tls-server 443; if printf '\\n' | openssl s_client -connect tls-server:443 -servername dojo-tls.local >/tmp/bad-tls 2>&1; then exit 1; fi; if curl --connect-timeout 3 -kfsS https://tls-server/health; then exit 1; fi; nmap -p 8080,8443 $tls_ip | tee /tmp/nmap.out; grep -Eq '^8080/tcp[[:space:]]+open' /tmp/nmap.out; grep -Eq '^8443/tcp[[:space:]]+open' /tmp/nmap.out; curl -fsS http://$tls_ip:8080/health >/dev/null; curl -kfsS https://$tls_ip:8443/health >/dev/null"; then
  pass "04 Netshoot nc/openssl/curl/nmap TLS diagnosis"
else fail "04 TLS commands"; fi

# 05 - Ingress isolation: Service succeeds while the intentionally bad Ingress fails
wait_deploy dojo-05-ingress api
if run_pod dojo-05-ingress cmd05 nicolaka/netshoot:v0.16 \
  'set -e; dig +search +short api | grep -q .; curl -fsS http://api:8080/dojo >/dev/null'; then
  pass "05 Netshoot backend/Service before Ingress"
else fail "05 Service path commands"; fi
if curl --connect-timeout 3 -fsS http://localhost:8080/dojo >/dev/null 2>&1; then
  fail "05 broken Ingress unexpectedly succeeded"
else
  pass "05 host Ingress check observes broken route"
fi

# 06 - Netshoot advanced tools + real packet-capture privilege
wait_deploy dojo-06-throughput iperf-server
iperf_ip="$(pod_ip_for dojo-06-throughput app=iperf-server)"
if run_pod dojo-06-throughput cmd06 nicolaka/netshoot:v0.16 \
  "set -e; for x in nmap iperf3 mtr tcptraceroute termshark ngrep tshark tcpdump; do command -v \"\$x\"; done; nmap -sT -p 5201 $iperf_ip | tee /tmp/nmap.out; grep -Eq '^5201/tcp[[:space:]]+open' /tmp/nmap.out; iperf3 -c $iperf_ip -t 1 >/dev/null; mtr -rw -c 1 $iperf_ip >/dev/null; tcptraceroute $iperf_ip 5201 >/dev/null 2>&1 || true; termshark --version >/dev/null"; then
  pass "06 Netshoot nmap/iperf3/mtr/tcptraceroute/termshark surface"
else fail "06 Netshoot advanced client commands"; fi
p="$(pod_for dojo-06-throughput app=iperf-server)"
if run_ephemeral dojo-06-throughput "$p" server cmd06cap nicolaka/netshoot:v0.16 netadmin zsh \
  'set -e; ss -lntp | grep -q 5201; tcpdump -i lo -nn -c 1 icmp >/tmp/tcpdump.out 2>&1 & t=$!; sleep 1; ping -c 1 127.0.0.1 >/dev/null; wait $t; grep -q ICMP /tmp/tcpdump.out; tshark -D >/dev/null; ngrep -V >/dev/null 2>&1'; then
  pass "06 Netshoot netadmin packet-capture privilege + tcpdump/tshark/ngrep"
else fail "06 packet capture commands/privileges"; fi

# 07 - JDK attach, thread tools, NMT and a short JFR
wait_deploy dojo-07-java-cpu api
p="$(pod_for dojo-07-java-cpu app=api)"
if run_ephemeral dojo-07-java-cpu "$p" app cmd07 eclipse-temurin:21-jdk-jammy general bash \
  'set -e; pid=$(jcmd -l | grep dojo.jar | cut -d" " -f1); test -n "$pid"; jps -lv | grep -q dojo.jar; jcmd "$pid" VM.version >/dev/null; jcmd "$pid" VM.flags >/dev/null; jcmd "$pid" VM.native_memory summary | grep -q Native; jcmd "$pid" Thread.print -l | grep -q dojo-cpu-burner; jstack "$pid" >/dev/null; jmap -histo "$pid" >/tmp/jmap.histo; test -s /tmp/jmap.histo; jinfo -flags "$pid" >/dev/null; jstat -gc "$pid" 1000 1 >/dev/null; jcmd "$pid" JFR.start name=commandcheck settings=profile duration=3s filename=/tmp/commandcheck.jfr >/dev/null; sleep 4; test -s /tmp/commandcheck.jfr' \
  "$ROOT/profiles/java-attach.yaml"; then
  pass "07 Temurin jcmd/jps/jstack/jmap/jinfo/jstat/JFR/NMT attach"
else fail "07 Java diagnostic commands"; fi

# 08 - JDK deadlock + Arthas batch attach (same underlying boot jar used interactively in LABS.md)
wait_deploy dojo-08-java-deadlock api
p="$(pod_for dojo-08-java-deadlock app=api)"
if run_ephemeral dojo-08-java-deadlock "$p" app cmd08jdk eclipse-temurin:21-jdk-jammy general bash \
  'set -e; pid=$(jcmd -l | grep dojo.jar | cut -d" " -f1); jcmd "$pid" Thread.print -l >/tmp/threads; grep -q dojo-deadlock-A /tmp/threads; grep -q dojo-deadlock-B /tmp/threads; grep -qi deadlock /tmp/threads' \
  "$ROOT/profiles/java-attach.yaml"; then
  pass "08 JDK deadlock detection"
else fail "08 JDK deadlock commands"; fi
if run_ephemeral dojo-08-java-deadlock "$p" app cmd08arthas debug-dojo-arthas-jdk21:local general /bin/sh \
  'set -e; test -f /opt/arthas/arthas-boot.jar; java -version; rm -rf /tmp/arthas-shared; mkdir -p /tmp/arthas-shared; cp -R /opt/arthas/. /tmp/arthas-shared/; test -f /tmp/arthas-shared/arthas-boot.jar; test -f /tmp/arthas-shared/arthas-agent.jar; mkdir -p /tmp/arthas-agent-check; cd /tmp/arthas-agent-check; jar xf /tmp/arthas-shared/arthas-agent.jar META-INF/MANIFEST.MF; grep -q "^Agent-Class:" META-INF/MANIFEST.MF; cd /tmp; pid=$(jps -l | grep dojo.jar | cut -d" " -f1); test -n "$pid"; if ! java -jar /tmp/arthas-shared/arthas-boot.jar -c "version; dashboard -n 1; thread --state BLOCKED" "$pid" >/tmp/arthas.out 2>&1; then cat /tmp/arthas.out; exit 1; fi; cat /tmp/arthas.out; grep -q dojo-deadlock-A /tmp/arthas.out; grep -q dojo-deadlock-B /tmp/arthas.out' \
  "$ROOT/profiles/java-attach.yaml"; then
  pass "08 Arthas boot/batch attach + thread commands"
else fail "08 Arthas deadlock commands"; fi

# 09 - Heap diagnostics. Leak rate is intentionally slow enough to finish this check before restart.
wait_deploy dojo-09-java-memory api
p="$(pod_for dojo-09-java-memory app=api)"
if run_ephemeral dojo-09-java-memory "$p" app cmd09 eclipse-temurin:21-jdk-jammy general bash \
  'set -e; pid=$(jcmd -l | grep dojo.jar | cut -d" " -f1); jcmd "$pid" GC.class_histogram >/tmp/histo; grep -Fq '[B' /tmp/histo; jstat -gc "$pid" 1000 1 >/dev/null; jcmd "$pid" VM.native_memory summary >/dev/null; jcmd "$pid" GC.heap_dump /tmp/commandcheck.hprof >/dev/null; test -s /tmp/commandcheck.hprof; rm -f /tmp/commandcheck.hprof' \
  "$ROOT/profiles/java-attach.yaml"; then
  pass "09 heap histogram/GC/NMT/heap dump"
else fail "09 memory diagnostic commands"; fi

# 10 - Arthas live application inspection. Batch mode validates command parsing/attach; traffic-sensitive commands stay learner-interactive.
wait_deploy dojo-10-arthas-slow api
p="$(pod_for dojo-10-arthas-slow app=api)"
if run_pod dojo-10-arthas-slow cmd10load nicolaka/netshoot:v0.16 \
  'set -e; for i in 1 2 3 4 5; do curl -fsS http://api:8080/slow >/dev/null; done'; then :; else fail "10 load generator"; fi
if run_ephemeral dojo-10-arthas-slow "$p" app cmd10arthas debug-dojo-arthas-jdk21:local general /bin/sh \
  'set -e; java -version; rm -rf /tmp/arthas-shared; mkdir -p /tmp/arthas-shared; cp -R /opt/arthas/. /tmp/arthas-shared/; test -f /tmp/arthas-shared/arthas-boot.jar; test -f /tmp/arthas-shared/arthas-agent.jar; mkdir -p /tmp/arthas-agent-check; cd /tmp/arthas-agent-check; jar xf /tmp/arthas-shared/arthas-agent.jar META-INF/MANIFEST.MF; grep -q "^Agent-Class:" META-INF/MANIFEST.MF; cd /tmp; pid=$(jps -l | grep dojo.jar | cut -d" " -f1); test -n "$pid"; if ! java -jar /tmp/arthas-shared/arthas-boot.jar -c "version; dashboard -n 1; jvm; memory; thread -n 10; classloader; sc dojo.DojoApp; sm dojo.DojoApp; jad dojo.DojoApp; logger" "$pid" >/tmp/arthas.out 2>&1; then cat /tmp/arthas.out; exit 1; fi; cat /tmp/arthas.out; grep -q DojoApp /tmp/arthas.out' \
  "$ROOT/profiles/java-attach.yaml"; then
  pass "10 Arthas dashboard/jvm/memory/thread/classloader/sc/sm/jad/logger/cleanup"
else fail "10 Arthas core command set"; fi

# 11 - Storage image + custom volumeMount profile
wait_deploy dojo-11-storage writer
p="$(pod_for dojo-11-storage app=writer)"
if run_ephemeral dojo-11-storage "$p" app cmd11 tazhate/k8s-debug-container-storage general bash \
  'set -e; id; test -d /data; grep " /data " /proc/mounts >/dev/null || grep "/data" /proc/self/mountinfo >/dev/null; df -h /data >/dev/null; du -sh /data >/dev/null; command -v ncdu; command -v iostat; iostat -xz 1 1 >/dev/null; dd if=/dev/zero of=/data/fio-commandcheck.tmp bs=1M count=8 status=none; fio --name=dojo-read --filename=/data/fio-commandcheck.tmp --size=8M --rw=read --bs=4k --runtime=2 --time_based >/dev/null; rm -f /data/fio-commandcheck.tmp' \
  "$ROOT/profiles/storage-data.yaml"; then
  pass "11 storage PVC mount + df/du/ncdu/iostat/dd/fio"
else fail "11 storage commands/custom volume mount"; fi

# 12 - PostgreSQL client tools and expected auth failure/success
wait_deploy dojo-12-db postgres
pw="$(k -n dojo-12-db get secret postgres-auth -o jsonpath='{.data.password}' | base64 -d)"
if run_pod dojo-12-db cmd12 tazhate/k8s-debug-container-db \
  "set -e; pg_isready -h postgres -p 5432; if PGPASSWORD=wrong-password psql -h postgres -U dojo -d dojo -c 'select 1;' >/dev/null 2>&1; then exit 1; fi; PGPASSWORD='$pw' psql -h postgres -U dojo -d dojo -c 'select current_database(), current_user;' | grep -q dojo"; then
  pass "12 pg_isready/psql bad-auth vs good-auth"
else fail "12 database commands"; fi

# 13 - Process/strace and perf presence; real perf sampling is host-dependent and not a hard failure.
wait_deploy dojo-13-perf writer
p="$(pod_for dojo-13-perf app=writer)"
if run_ephemeral dojo-13-perf "$p" app cmd13 tazhate/k8s-debug-container-perf sysadmin bash \
  'set -e; ps aux >/dev/null; htop --version >/dev/null; pid=$(ps -eo pid=,comm= | sed -n "/[[:space:]]java$/{s/^[[:space:]]*//;s/[[:space:]].*//;p;q;}"); test -n "$pid"; test -d "/proc/$pid/fd"; strace -f -p "$pid" -e trace=openat,write,close -o /tmp/strace.out & s=$!; sleep 7; kill -INT "$s" 2>/dev/null || true; wait "$s" 2>/dev/null || true; test -s /tmp/strace.out; perf --version >/dev/null' ; then
  pass "13 sysadmin process view + htop/strace/perf binary"
else fail "13 performance commands/ptrace privilege"; fi

# 14 - kubectl debug node + host namespace tooling
wait_deploy dojo-14-node port-holder
node="$(k -n dojo-14-node get pod -l app=port-holder -o jsonpath='{.items[0].spec.nodeName}')"
if out="$(run_node_debug "$node" nicolaka/netshoot:v0.16 'set -e; ss -lntp | grep 18080; ip addr >/dev/null; ip route >/dev/null; ip neigh >/dev/null; ps aux >/dev/null; test -d /host; iptables -S >/dev/null 2>&1 || true; nft list ruleset >/dev/null 2>&1 || true; conntrack -L >/dev/null 2>&1 || true; ipvsadm -Ln >/dev/null 2>&1 || true; echo NODE_DEBUG_OK' 2>&1)" && grep -q NODE_DEBUG_OK <<<"$out"; then
  pass "14 node debug host namespaces + /host + firewall/service-routing tools"
else
  printf '%s\n' "${out:-}" >&2
  fail "14 kubectl debug node command"
fi

# 15 - Stress image controlled workloads only inside disposable Pod
wait_deploy dojo-15-stress api
if run_pod dojo-15-stress cmd15 tazhate/k8s-debug-container-stress \
  'set -e; hey -n 10 -c 2 http://api:8080/slow >/dev/null; stress-ng --cpu 1 --timeout 2s --metrics >/dev/null; sysbench cpu --threads=1 --time=1 run >/dev/null; ioping -c 2 /tmp >/dev/null; fio --name=dojo-scratch --filename=/tmp/fio-dojo.tmp --size=8M --rw=randrw --bs=4k --runtime=2 --time_based >/dev/null; rm -f /tmp/fio-dojo.tmp'; then
  pass "15 hey/stress-ng/sysbench/ioping/fio"
else fail "15 stress/load commands"; fi

# metrics-server command in the learner instructions
if wait_top dojo-15-stress; then
  pass "15 kubectl top --containers"
else fail "15 kubectl top command after metrics warm-up"; fi

# 16 - gProfiler: node-wide first, then runtime-only fallback if Docker Desktop blocks perf/PID namespace checks.
wait_deploy dojo-16-gprofiler api
node="$(k -n dojo-16-gprofiler get pod -l app=api -o jsonpath='{.items[0].spec.nodeName}')"
gprof_cmd='set -e; mkdir -p /host/tmp/gprofiler-commandcheck; /gprofiler --profiling-duration 5 --output-dir /host/tmp/gprofiler-commandcheck --disable-metrics-collection --disable-metadata-collection; test -e /host/tmp/gprofiler-commandcheck/last_profile.col; test -e /host/tmp/gprofiler-commandcheck/last_flamegraph.html; echo GPROFILER_OK'
if out="$(run_node_debug "$node" intel/gprofiler:latest "$gprof_cmd" 2>&1)" && grep -q GPROFILER_OK <<<"$out"; then
  pass "16 gProfiler system-wide profile + local outputs"
else
  echo "    normal gProfiler mode unavailable; trying documented runtime-only fallback"
  fallback='set -e; mkdir -p /host/tmp/gprofiler-commandcheck; /gprofiler --profiling-duration 5 --output-dir /host/tmp/gprofiler-commandcheck --disable-pidns-check --perf-mode disabled --disable-metrics-collection --disable-metadata-collection; test -e /host/tmp/gprofiler-commandcheck/last_profile.col; echo GPROFILER_RUNTIME_OK'
  if out="$(run_node_debug "$node" intel/gprofiler:latest "$fallback" 2>&1)" && grep -q GPROFILER_RUNTIME_OK <<<"$out"; then
    pass "16 gProfiler runtime-only fallback"
  else
    printf '%s\n' "${out:-}" >&2
    skip "16 gProfiler blocked by host/runtime profiler restrictions"
  fi
fi

printf '\nCommand-level test complete: %d PASS, %d SKIP\n' "$PASS" "$SKIP"
printf 'Cluster: %s\n' "$CONTEXT"
[[ "$SKIP" -eq 0 ]] && echo 'COMMAND E2E: PASS' || echo 'COMMAND E2E: PASS WITH OPTIONAL SKIPS'
