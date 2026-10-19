# Debug Pods Dojo — Lab Guide

Do not open `fixed.yaml` or `ANSWERS.md` until you want the reference repair.

Run the commands from the repository root: the `profiles/` files passed to `--custom` and the `./scripts/` paths are relative to it.

## Common debug patterns

### Ephemeral container in an existing Pod

```bash
kubectl debug -n <namespace> -it pod/<podname> \
  --container="debug-$(date +%s)" \
  --target=<containername> \
  --image=<debug-image> \
  --profile=general \
  -- <shell>
```

Use `--profile=netadmin` for packet/network administration and `--profile=sysadmin` only when privileged process/kernel access is required.

### Independent throwaway debug Pod

```bash
kubectl run debug -n <namespace> --rm -it --restart=Never \
  --image=<debug-image> -- <shell>
```

### Node debug Pod

```bash
kubectl debug -it node/<nodename> \
  --image=<debug-image> \
  --profile=sysadmin \
  -- <shell>
```

The node filesystem is available under `/host`.

The node debug Pod stays behind after you exit (as `node-debugger-<node>-<suffix>` in the current namespace), and lab resets do not remove it. Delete it when you are done:

```bash
kubectl get pods -o name | grep node-debugger- | xargs kubectl delete
```

---

## Lab 01 — Netshoot: Service/TCP path

Namespace: `dojo-01-service`

Start with an independent client:

```bash
kubectl run netshoot -n dojo-01-service --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 -- zsh
```

Practice:

```bash
# dig does not use resolv.conf search domains unless +search is requested
dig +search api
curl -v http://api:8080/health
nc -vz api 8080
```

Find the application Pod IP and compare direct access:

```bash
kubectl get pod -n dojo-01-service -l app=api -o wide
```

Then attach Netshoot to the app Pod:

```bash
kubectl debug -n dojo-01-service -it pod/<podname> \
  --container="netshoot-$(date +%s)" \
  --target=app \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 \
  --profile=netadmin -- zsh
```

Inside:

```bash
ss -lntp
ip addr
ip route
curl -v http://127.0.0.1:8080/health
```

Goal: prove that the application listens correctly but the Service sends traffic to the wrong target port.

---

## Lab 02 — Netshoot: DNS

Namespace: `dojo-02-dns`

Attach Netshoot to the caller Pod:

```bash
kubectl debug -n dojo-02-dns -it pod/<caller-pod> \
  --container="netshoot-$(date +%s)" \
  --target=app \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 \
  --profile=general -- zsh
```

Inside:

```bash
cat /etc/resolv.conf

# Useful contrast: bare dig does not apply the resolv.conf search list by default.
dig backend

# Explicitly apply the Pod search list for a short Service name.
dig +search backend

# FQDN queries do not need a search suffix.
dig backend.dojo-02-dns.svc.cluster.local
drill backend.dojo-02-dns.svc.cluster.local

# nslookup follows the resolver/search behavior, so the short name should resolve.
nslookup backend

# The actual application typo should remain unresolved.
dig +search backned
curl -v http://backend:8080/health
curl -v http://backned:8080/health
```

Goal: distinguish a broken cluster resolver from an application typo.

---

## Lab 03 — Netshoot: NetworkPolicy

Namespace: `dojo-03-netpol`

Try an unlabelled client:

```bash
kubectl run netshoot-denied -n dojo-03-netpol --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 -- zsh
```

Inside:

```bash
dig +search backend
nc -vz -w 3 backend 8080
curl --connect-timeout 3 -v http://backend:8080/health
```

Now create a labelled debug client:

```bash
kubectl run netshoot-allowed -n dojo-03-netpol --rm -it --restart=Never \
  --labels=access=allowed \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 -- zsh
```

Repeat the same tests. The contrast is the point of the lab.

> **K3s note:** the NetworkPolicy dataplane is reconciled asynchronously. If you create the labelled Pod and test immediately, the first connection can still be denied briefly. Retry the `nc`/`curl` check for a few seconds before concluding the label is not allowed.

---

## Lab 04 — Netshoot: TLS/protocol mismatch

Namespace: `dojo-04-tls`

```bash
kubectl run netshoot -n dojo-04-tls --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 -- zsh
```

Inside:

```bash
nc -vz tls-server 443

openssl s_client \
  -connect tls-server:443 \
  -servername dojo-tls.local

curl -vk https://tls-server/health
```

Find the Pod and inspect both application ports:

```bash
nmap -p 8080,8443 <tls-server-pod-ip>

curl -v http://<tls-server-pod-ip>:8080/health
curl -vk https://<tls-server-pod-ip>:8443/health
```

Goal: recognize "TCP works but this isn't TLS" and identify the correct backend protocol/port.

---

## Lab 05 — Netshoot: Ingress → Service → Pod

Namespace: `dojo-05-ingress`

From a debug Pod:

```bash
kubectl run netshoot -n dojo-05-ingress --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 -- zsh
```

Test the Service:

```bash
dig +search api
curl -v http://api:8080/dojo
```

From your host (use your `INGRESS_PORT` if you changed it):

```bash
curl -v http://localhost:8080/dojo
```

The purpose is to prove the backend and Service before blaming the application.

---

## Lab 06 — Netshoot: nmap, iperf3, tcpdump, mtr

Namespace: `dojo-06-throughput`

Get the server Pod IP:

```bash
kubectl get pod -n dojo-06-throughput -l app=iperf-server -o wide
```

Run Netshoot:

```bash
kubectl run netshoot -n dojo-06-throughput --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 -- zsh
```

Inside:

```bash
nmap <iperf-server-pod-ip>

iperf3 -c <iperf-server-pod-ip>
iperf3 -c iperf-server

mtr -rw <iperf-server-pod-ip>
```

For packet capture, attach another Netshoot ephemeral container to the iperf server:

```bash
kubectl debug -n dojo-06-throughput -it pod/<iperf-server-pod> \
  --container="capture-$(date +%s)" \
  --target=server \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 \
  --profile=netadmin -- zsh
```

Inside:

```bash
# Listening sockets and process ownership
ss -lntp

# Packet capture
tcpdump -i any -nn port 5201

# Protocol-aware capture alternative
tshark -i any -f 'tcp port 5201'

# Payload-oriented grep (useful for plaintext protocols)
ngrep -d any -W byline '.' 'tcp port 5201'
```

Run `iperf3` from another terminal while capturing. Also practice:

```bash
ping -c 4 iperf-server
mtr -rw -c 5 iperf-server
tcptraceroute iperf-server 5201
nmap -sT -p 5201 iperf-server
```

`termshark` is also available when you want an interactive terminal UI over packet captures.

---

## Java attach profile used by Labs 07–10

The Java image is distroless. The debugger is injected rather than installed in the application.

```bash
kubectl debug -n <namespace> -it pod/<podname> \
  --container="jdk-$(date +%s)" \
  --target=app \
  --image=eclipse-temurin:21.0.12.1_1-jdk-jammy@sha256:742daacb9316be4b6fc60258f6e4ac2a11882f6c597373c92290a57bfad0d2e0 \
  --profile=general \
  --custom=profiles/java-attach.yaml -- bash
```

Inside:

```bash
jcmd -l
jps -lv
```

Use the Java PID shown by `jcmd`. The labs emphasize `jcmd` because it exposes most modern HotSpot diagnostics, but also practice the dedicated JDK tools where useful:

```bash
jstack <PID>
jmap -histo <PID>
jinfo -flags <PID>
```

---

## Lab 07 — Temurin JDK: CPU, threads, JFR and NMT

Namespace: `dojo-07-java-cpu`

Useful commands:

```bash
jcmd <PID> VM.version
jcmd <PID> VM.flags
jcmd <PID> VM.native_memory summary
jcmd <PID> Thread.print -l
jstat -gc <PID> 1000
```

Look for:

```text
dojo-cpu-burner
```

Start a JFR:

```bash
jcmd <PID> JFR.start \
  name=dojo \
  settings=profile \
  duration=60s \
  filename=/tmp/cpu.jfr

jcmd <PID> JFR.check
```

Copy it while the debug container is still running:

```bash
kubectl cp -n dojo-07-java-cpu \
  -c <jdk-debug-container-name> \
  <podname>:/tmp/cpu.jfr ./cpu.jfr
```

`kubectl cp` depends on `tar` being available in the debug container. If copying fails, stream the file instead:

```bash
kubectl exec -n dojo-07-java-cpu \
  -c <jdk-debug-container-name> \
  <podname> -- cat /tmp/cpu.jfr > ./cpu.jfr
```

---

## Lab 08 — Temurin / Arthas: deadlock

Namespace: `dojo-08-java-deadlock`

JDK:

```bash
jcmd <PID> Thread.print -l
```

Look for:

```text
dojo-deadlock-A
dojo-deadlock-B
```

Arthas alternative:

The dojo builds `debug-dojo-arthas-jdk21:local`, which combines the official Arthas files with a Temurin 21 JDK. Matching the debugger JDK major to the Java 21 target avoids cross-JDK attach surprises while keeping the Arthas tooling itself unchanged.

```bash
kubectl debug -n dojo-08-java-deadlock -it pod/<podname> \
  --container="arthas-$(date +%s)" \
  --target=app \
  --image=debug-dojo-arthas-jdk21:local \
  --profile=general \
  --custom=profiles/java-attach.yaml -- /bin/sh
```

The ephemeral container can see the target process, but it does **not** share the target container's root filesystem. Arthas loads an agent JAR into the target JVM, so stage the Arthas distribution into the Pod's shared `/tmp` volume first:

```bash
rm -rf /tmp/arthas-shared
mkdir -p /tmp/arthas-shared
cp -R /opt/arthas/. /tmp/arthas-shared/
java -jar /tmp/arthas-shared/arthas-boot.jar
```

This is important: `/tmp` is backed by the `shared-tmp` `emptyDir` mounted in both the application and debug containers, so the target JVM can resolve the Arthas agent JAR path. `jcmd`/`jstack` can attach without injecting an external agent JAR, which is why the JDK labs work without this staging step; Arthas specifically calls the Attach API to load `arthas-agent.jar`.

Inside Arthas:

```text
dashboard
thread
thread --state BLOCKED
```

---

## Lab 09 — Temurin JDK: memory growth and heap dump

Namespace: `dojo-09-java-memory`

Attach early; the lab intentionally keeps allocating.

About ten minutes after each start the heap is exhausted: the JVM writes `/tmp/oome.hprof`, exits, and the kubelet restarts the container (watch the `RESTARTS` column) so the leak starts over. The restart also ends any ephemeral debug container targeting `app`, because it shares that container's PID namespace, so start a new debug session afterwards. To start from a fresh, small heap, run `./scripts/reset-lab.sh 09`.

```bash
jcmd <PID> GC.class_histogram
jstat -gc <PID> 1000
jcmd <PID> VM.native_memory summary
```

Repeat the histogram and observe growing `byte[]` retention.

Create a heap dump:

```bash
jcmd <PID> GC.heap_dump /tmp/heap.hprof
```

Copy it out before terminating the debug session. For large heap dumps, streaming avoids any dependency on `tar`:

```bash
kubectl exec -n dojo-09-java-memory \
  -c <jdk-debug-container-name> \
  <podname> -- cat /tmp/heap.hprof > ./heap.hprof
```

---

## Lab 10 — Arthas: live method diagnostics

Namespace: `dojo-10-arthas-slow`

Attach Arthas:

This uses the dojo's Java-21-matched Arthas debug image (`debug-dojo-arthas-jdk21:local`). After attaching the ephemeral container, copy `/opt/arthas` into the shared `/tmp` volume before starting Arthas; the target JVM must be able to see the agent JAR path from its own filesystem namespace.

```bash
kubectl debug -n dojo-10-arthas-slow -it pod/<podname> \
  --container="arthas-$(date +%s)" \
  --target=app \
  --image=debug-dojo-arthas-jdk21:local \
  --profile=general \
  --custom=profiles/java-attach.yaml -- /bin/sh
```

Stage the Arthas distribution on the shared volume and start it from there:

```bash
rm -rf /tmp/arthas-shared
mkdir -p /tmp/arthas-shared
cp -R /opt/arthas/. /tmp/arthas-shared/
java -jar /tmp/arthas-shared/arthas-boot.jar
```

Useful commands:

```text
dashboard
jvm
memory
thread -n 10
classloader
sc dojo.DojoApp
sm dojo.DojoApp
jad dojo.DojoApp

trace dojo.DojoApp slowWork -n 5
watch dojo.DojoApp slowWork '{params,returnObj,throwExp}' -x 2 -n 5
stack dojo.DojoApp slowWork -n 5
monitor -c 5 dojo.DojoApp slowWork

# Capture invocations for later inspection (training environment only)
tt -t dojo.DojoApp slowWork -n 5
tt -l

logger

profiler start
profiler stop

# Clear TimeTunnel recordings and remove injected enhancements before leaving
tt --delete-all
reset
stop
```

`tt` retains invocation data in memory, so keep it tightly scoped and clear it after the exercise. `watch`, `trace`, `monitor`, and `tt` are intentionally demonstrated here because they are the capabilities that make Arthas materially different from a plain JDK image.

Generate traffic in another terminal:

```bash
kubectl run load -n dojo-10-arthas-slow --rm -it --restart=Never \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 -- \
  sh -c 'for i in 1 2 3 4 5; do curl -s http://api:8080/slow; done'
```

---

## Lab 11 — Storage toolbox

Namespace: `dojo-11-storage`

Attach the storage image and mount the application's existing PVC volume:

```bash
kubectl debug -n dojo-11-storage -it pod/<writer-pod> \
  --container="storage-$(date +%s)" \
  --target=app \
  --image=tazhate/k8s-debug-container-storage@sha256:8e40c1db9d086e4375040984a6ff0362fcfdfd6f8119a812664225f850a2ff28 \
  --profile=general \
  --custom=profiles/storage-data.yaml -- bash
```

Inside:

```bash
id
ls -ld /data

# Confirm that the PVC is visible in this debug container
grep ' /data ' /proc/mounts || grep '/data' /proc/self/mountinfo

df -h /data
du -sh /data/* 2>/dev/null || true
ncdu /data

# Device-level I/O statistics (sysstat is installed in this image)
iostat -xz 1 3
```

Safe `fio` example using a dedicated test file:

```bash
dd if=/dev/zero of=/data/fio-dojo.tmp bs=1M count=32

fio \
  --name=dojo-read \
  --filename=/data/fio-dojo.tmp \
  --size=32M \
  --rw=read \
  --bs=4k \
  --runtime=10 \
  --time_based

rm -f /data/fio-dojo.tmp
```

Do not run destructive write tests over real application files.

---

## Lab 12 — DB toolbox

Namespace: `dojo-12-db`

```bash
kubectl run db-debug -n dojo-12-db --rm -it --restart=Never \
  --image=tazhate/k8s-debug-container-db@sha256:3f3e58b3f6e4b3e2a1b3846d7a74ec1a6cb7e3742c57498fa60e145a2f6b3672 -- bash
```

Inside:

```bash
pg_isready -h postgres -p 5432

PGPASSWORD=wrong-password \
  psql -h postgres -U dojo -d dojo \
  -c 'select current_database(), current_user;'
```

Get the training password:

```bash
kubectl get secret -n dojo-12-db postgres-auth \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Then retry with the correct password.

This separates "network works" from "database authentication is wrong".

---

## Lab 13 — Performance toolbox: strace and process inspection

Namespace: `dojo-13-perf`

```bash
kubectl debug -n dojo-13-perf -it pod/<writer-pod> \
  --container="perf-$(date +%s)" \
  --target=app \
  --image=tazhate/k8s-debug-container-perf@sha256:a7547e55a0a6a7d0d0cd7bb8ff94143950fdc0794551da3e5718c0add577ebdf \
  --profile=sysadmin -- bash
```

Inside:

```bash
ps aux
htop

ls -l /proc/<PID>/fd

strace -f -p <PID>
```

Narrow it:

```bash
strace -f -p <PID> \
  -e trace=openat,write,close
```

If your host kernel allows it:

```bash
perf top
perf record -p <PID> -g -- sleep 20
perf report
```

`perf` and BCC/eBPF are intentionally best-effort on k3d because Docker Desktop and host kernel security settings can restrict them.

---

## Lab 14 — Node debug with Netshoot

Namespace: `dojo-14-node`

Find the node:

```bash
kubectl get pod -n dojo-14-node -l app=port-holder -o wide
```

Enter it:

```bash
kubectl debug -it node/<nodename> \
  --image=nicolaka/netshoot:v0.16@sha256:b09d9b21381f47a79b3cbcb30da25266dc17186ea00ae65e99fdc51396f48e70 \
  --profile=sysadmin -- zsh
```

Inside:

```bash
# Host sockets/interfaces/routes/processes
ss -lntp | grep 18080
ip addr
ip route
ip neigh
ps aux

# Kubernetes node filesystem mounted by kubectl debug
ls /host

# Network-policy / service-routing primitives on the node
iptables -S 2>/dev/null | head -80
nft list ruleset 2>/dev/null | head -120
conntrack -L 2>/dev/null | head
ipvsadm -Ln 2>/dev/null || true
```

Which firewall/service-routing commands return useful state depends on the K3s and host networking backend. The exercise is to learn how to inspect those layers from a node debug container, not to assume that every cluster uses IPVS or nftables.

This is specifically about the difference between **Pod network/process context** and **node host namespaces**.

---

## Lab 15 — Stress/load debug image

Namespace: `dojo-15-stress`

```bash
kubectl run stress -n dojo-15-stress --rm -it --restart=Never \
  --image=tazhate/k8s-debug-container-stress@sha256:ed01e0719cc59b3891f9df73c45e2284dcd97530c2b0101698811444b6281d85 -- bash
```

HTTP load:

```bash
hey -n 100 -c 20 http://api:8080/slow
```

In another terminal:

```bash
kubectl top pod -n dojo-15-stress --containers
```

Also practice controlled load **inside the disposable debug Pod only**:

```bash
stress-ng --cpu 1 --timeout 15s --metrics
sysbench cpu --threads=1 --time=10 run

# Latency and disposable-file I/O from the stress toolbox
ioping -c 5 /tmp
fio --name=dojo-scratch --filename=/tmp/fio-dojo.tmp \
  --size=16M --rw=randrw --bs=4k --runtime=5 --time_based
rm -f /tmp/fio-dojo.tmp
```

---

## Lab 16 — gProfiler node-wide profiling

Namespace: `dojo-16-gprofiler`

This is optional if your Docker/k3d host blocks profiler/perf functionality.

Find the node hosting the CPU-heavy Pod:

```bash
kubectl get pod -n dojo-16-gprofiler -l app=api -o wide
```

Start a privileged node debug shell using the gProfiler image:

```bash
kubectl debug -it node/<nodename> \
  --image=intel/gprofiler:1.57.1@sha256:e204c3ad03bf2ee822cb55b6493685926e64d64907c2b83a683d0c49b47a5c6b \
  --profile=sysadmin -- /bin/sh
```

Inside:

```bash
mkdir -p /host/tmp/gprofiler

/gprofiler \
  --profiling-duration 30 \
  --output-dir /host/tmp/gprofiler \
  --disable-metrics-collection \
  --disable-metadata-collection

ls -lh /host/tmp/gprofiler
```

If gProfiler rejects the PID namespace on your k3d/Docker host, retry with:

```bash
/gprofiler \
  --profiling-duration 30 \
  --output-dir /host/tmp/gprofiler \
  --disable-pidns-check \
  --disable-metrics-collection \
  --disable-metadata-collection
```

If the host blocks system-wide `perf`, retry in runtime-only mode so Java can still be profiled:

```bash
/gprofiler \
  --profiling-duration 30 \
  --output-dir /host/tmp/gprofiler \
  --disable-pidns-check \
  --perf-mode disabled \
  --disable-metrics-collection \
  --disable-metadata-collection
```

You should get a collapsed profile and an HTML flamegraph. The goal is to find the Java CPU burner from a **system-wide profiler** rather than by attaching JDK tools directly.

---

## Reset and check

```bash
./scripts/check-lab.sh <number>
./scripts/reset-lab.sh <number>
./scripts/solve-lab.sh <number>
```

`check-lab.sh` tests each lab's success condition (for example, that the Service answers or that the fault-injection threads are gone), so any correct repair passes, not only the one in `fixed.yaml`. It starts a short-lived Netshoot probe Pod in the lab namespace; set `CHECK_VERBOSE=1` to see what it ran into.
