# k3d Debug Pods Dojo

A local Kubernetes lab that exists for one purpose: **practice the capabilities of debugging containers**.

This edition intentionally removes generic Kubernetes exercises that are better covered by CKA/CKAD/SadServers-style labs. Every exercise here should make you launch one of the debug images, attach an ephemeral container, create a throwaway debug Pod, or enter a node with `kubectl debug`.

> Safety: the project intentionally creates CPU load, memory growth, failed connectivity, privileged debug sessions and synthetic storage tests. Run it only in the disposable k3d cluster created by this repository.

## Debug images covered

| Debug image | Labs | Main capabilities exercised |
|---|---:|---|
| `nicolaka/netshoot:v0.16` | 01–06, 14 | DNS, HTTP/TCP, routing, sockets, NetworkPolicy, TLS, nmap, tcpdump, iperf3, node namespaces |
| `eclipse-temurin:21.0.12.1_1-jdk-jammy` | 07–09 | jcmd, jstat, thread dumps, heap histograms/dumps, NMT, JFR |
| `debug-dojo-arthas-jdk21:local` | 08, 10 | dashboard, threads, decompile, trace, watch, stack, profiler |
| `tazhate/k8s-debug-container-storage` | 11 | mounts, disk usage, iostat, fio |
| `tazhate/k8s-debug-container-db` | 12 | pg_isready, psql, DB connectivity/auth |
| `tazhate/k8s-debug-container-perf` | 13 | ps/htop, strace, /proc, perf/BCC where supported |
| `tazhate/k8s-debug-container-stress` | 15 | hey, stress-ng, sysbench, controlled load |
| `intel/gprofiler:1.57.1` | 16 | system-wide CPU profiles and local flamegraphs |

Every third-party image (debug images, the checker's probe image and the images the lab workloads run) is pinned by digest. `scripts/images.env` is the single source of truth; `LABS.md`, the lab manifests, the test scripts and the Dockerfiles must reference exactly those values (the tables here show tags only). `./scripts/validate.sh` fails on any unpinned or drifting reference.

Images are otherwise pulled on first use. To load them into the cluster up front (offline-friendly, no registry waits mid-exercise):

```bash
./scripts/preload.sh               # or: make preload   (workload + debug images, about 3 GB)
./scripts/preload.sh --runtime     # or: make preload SCOPE=runtime
PRELOAD=runtime ./scripts/up.sh    # preload while creating the cluster
```

Preloading needs Docker's containerd image store; with the classic store the script says so and skips, and images are pulled on first use. Images a node already holds are skipped, so running it again is cheap. Either way `up.sh` verifies that the locally built Java and Arthas images arrived on every node, skips nodes that already hold the same build, and loads them with `docker save` when `k3d image import` silently did not.


## Prerequisites

- Docker on a cgroup v2 host (current Docker Desktop, Rancher Desktop, colima and recent Linux distributions all qualify; the pinned k3s release refuses cgroup v1, and `up.sh` stops early if it finds it)
- k3d 5.x (the Kubernetes version is pinned by `K3S_IMAGE` in `scripts/images.env`, not by the k3d release)
- kubectl 1.31 or newer (`kubectl debug --custom`, used by Labs 07–11)
- bash 3.2 or newer (the macOS default works)
- About 6 GB of Docker memory is comfortable

## Start

```bash
./scripts/up.sh        # or: make up
```

Every lab is deployed by default. Labs 07 and 16 each keep half a CPU core busy, so on a small Docker host you can deploy only the labs you are working on:

```bash
LABS="01 07" ./scripts/up.sh
```

Running `up.sh` again is safe: it starts a stopped cluster and deploys only labs that are not deployed yet, so your repairs stay in place (use `./scripts/reset-lab.sh` or `./scripts/reset-all.sh` to start a lab over). `LABS` is also honoured by `./scripts/reset-all.sh`. When `LABS` leaves out Labs 08 and 10, `up.sh` skips building the 700 MB Arthas debug image; `./scripts/rebuild.sh` builds it later, and `DOJO_ARTHAS=1` forces it. The Ingress is published on `127.0.0.1:8080`; set `INGRESS_PORT` when creating the cluster to use another port. Both the Ingress and the Kubernetes API are bound to localhost only, because the dojo runs privileged and node-level debug Pods that must not be reachable from your network. A cluster created by an older revision still listens on every interface; `up.sh` warns about it, and `./scripts/down.sh && ./scripts/up.sh` recreates it with localhost bindings (this redeploys every lab).

Every lab workload sets CPU and memory requests and limits, so one lab that runs away cannot starve the others. Debug tools you attach as ephemeral containers run inside the Pod's limits; the labs that attach heavy tools (Arthas in 08 and 10, perf in 13) have more headroom, and the Lab 06 iperf3 server has no CPU limit so throttling does not distort throughput measurements.

Then:

```bash
./scripts/status.sh
```

Read:

```bash
less LABS.md
```

Validate a repair:

```bash
./scripts/check-lab.sh 07   # or: make check LAB=07
```

Check every deployed lab at once:

```bash
./scripts/check-all.sh      # or: make check-all
```

It runs four checks in parallel (`CHECK_JOBS=8` to change that), prints one result per lab in order, and exits 0 when everything passes, 1 when a lab is not fixed yet and 2 when a check could not run or none of the selected labs is deployed.

The checker tests the lab's success condition rather than comparing your manifest with `fixed.yaml`, so any correct repair passes. Most checks start a short-lived, digest-pinned `nicolaka/netshoot:v0.16` Pod in the lab namespace to probe the workload; set `CHECK_VERBOSE=1` to print its output. If that probe Pod cannot run (for example, its image cannot be pulled), the checker reports a check error and exits with status 2 instead of calling the lab not fixed.

Reset one lab:

```bash
./scripts/reset-lab.sh 07   # or: make reset-lab LAB=07
```

Apply the reference fix:

```bash
./scripts/solve-lab.sh 07   # or: make solve LAB=07
```

Static validation (offline; also runs in CI with `shellcheck`):

```bash
./scripts/validate.sh       # or: make validate
```

Full disposable-cluster reference test (checks fail on every broken lab and pass after every reference fix):

```bash
./scripts/e2e-test.sh       # or: make e2e
```

Command-level test that runs the `LABS.md` debug commands in a disposable cluster:

```bash
./scripts/command-e2e-test.sh   # or: make command-e2e
```

Both tests create their own k3d cluster on a separate host port (8180 and 8280) with a private kubeconfig, so they can run while the main dojo is up without touching it or your current kubectl context. They ignore `CLUSTER` and `INGRESS_PORT`; set `E2E_CLUSTER` or `E2E_INGRESS_PORT` to override the test cluster's name or port, and `KEEP_CLUSTER=1` to keep it afterwards. `E2E_LABS="01 07"` limits `e2e-test.sh` to a subset of labs for a faster smoke test; it runs the checks `CHECK_JOBS` (default 4) at a time. GitHub Actions runs both suites nightly and on demand through the `e2e` workflow.

Two k3s clusters at once need more inotify instances than the Docker VM's default of 128. If the second cluster fails to start with `too many open files`, raise the limit (it is reset when the VM restarts), for example on Docker Desktop or Rancher Desktop:

```bash
docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -n -i \
  sysctl -w fs.inotify.max_user_instances=1024
```

Alternatively stop the main dojo with `k3d cluster stop debug-pods-dojo` while a test runs, and resume it afterwards with `./scripts/up.sh` (or `k3d cluster start debug-pods-dojo`). `LABS.md` has a [troubleshooting table](LABS.md#troubleshooting) for the other common problems.

Destroy:

```bash
./scripts/down.sh
```

`up.sh` switches the active kubectl context to the dojo and records the previously active one; `down.sh` restores that context after deleting the cluster (unless you switched away yourself in the meantime).

## Design

The training Java application is Java 21 running on a distroless runtime, deliberately without a normal shell. That makes `kubectl debug` the intended way to bring JDK and diagnostic tooling to the running application.

The Java attach labs share `/tmp` with the ephemeral debugger and use `profiles/java-attach.yaml` so the JDK/Arthas process runs as UID/GID 65532, matching the distroless application.

Storage Lab 11 uses `profiles/storage-data.yaml` to mount the application's existing `data` volume into the storage debug container.

## Reference documentation

- `kubernetes-debug-pods-cheat-sheet-1.pdf`: a general debug-image cheat sheet. It is background reading only: its examples use a different app (`taskflow`) and unpinned image tags, so use the digest-pinned commands in `LABS.md` for the labs.

- Kubernetes `kubectl debug`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_debug/
- Ephemeral containers: https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/
- Netshoot: https://github.com/nicolaka/netshoot
- Specialized Kubernetes debug containers: https://github.com/tazhate/k8s-debug-container
- Arthas: https://arthas.aliyun.com/en/doc/
- gProfiler: https://github.com/intel/gprofiler


### Arthas filesystem visibility

For Labs 08 and 10, the Arthas ephemeral container stages `/opt/arthas` into `/tmp/arthas-shared` before attaching. `/tmp` is a shared `emptyDir` mounted in the application and debugger containers. This is required because Arthas loads an agent JAR into the target JVM by pathname, and an ephemeral container does not otherwise share the target container's root filesystem.
