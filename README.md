# k3d Debug Pods Dojo

A local Kubernetes lab that exists for one purpose: **practice the capabilities of debugging containers**.

This edition intentionally removes generic Kubernetes exercises that are better covered by CKA/CKAD/SadServers-style labs. Every exercise here should make you launch one of the debug images, attach an ephemeral container, create a throwaway debug Pod, or enter a node with `kubectl debug`.

> Safety: the project intentionally creates CPU load, memory growth, failed connectivity, privileged debug sessions and synthetic storage tests. Run it only in the disposable k3d cluster created by this repository.

## Release status — fully validated v9

**v9-command-validated is the first frozen, fully validated release of the Debug Pods Dojo.**

On **August 12, 2026**, the complete learner-command suite was executed successfully on a real **Rancher Desktop + k3d** environment using the repository's disposable **1-server + 2-agent** cluster:

```text
Command-level test complete: 22 PASS, 0 SKIP
Cluster: k3d-debug-pods-dojo-command-e2e
COMMAND E2E: PASS
```

The successful run covered all 16 lab scenarios and the complete supported debug-tool surface: Netshoot, Temurin/JDK diagnostics, Arthas, storage, PostgreSQL, syscall/performance debugging, node debugging, load generation, metrics, and gProfiler's runtime-only fallback.

This runtime validation is in addition to the normal broken/fixed-state E2E suite and the local/static validation performed by `scripts/validate.sh`. See [`COMMAND-VALIDATION.md`](COMMAND-VALIDATION.md) for the validation matrix and [`CHANGELOG.md`](CHANGELOG.md) for the release history.

Confirm the package revision before testing:

```bash
cat VERSION
```

For this package it should print `v9-command-validated`.

## Validate the actual learner commands

`make e2e` verifies the broken/fixed reference states. A separate command-level suite now validates the actual debug-image workflows and binaries documented in `LABS.md`:

```bash
make command-e2e
```

It creates a separate disposable `debug-pods-dojo-command-e2e` cluster, exercises throwaway debug Pods, ephemeral `kubectl debug` containers, custom debug profiles, node debug Pods, JDK attach, Arthas attach, storage/DB/perf/stress toolboxes, and gProfiler, then deletes the cluster and restores your previous kubeconfig context. Set `KEEP_CLUSTER=1` to retain the test cluster after the run.

The frozen v9 release has been run end-to-end with this target and completed with **22 PASS, 0 SKIP**. On the validated Rancher Desktop environment, full gProfiler perf mode was unavailable, so the suite correctly exercised and passed the documented runtime-only fallback.

`./scripts/validate.sh` also includes a local Java 21 `java -jar`/`jcmd` smoke test so PID-selection and nested-shell quoting mistakes are caught before the cluster-level suite runs.

## Debug images covered

| Debug image | Labs | Main capabilities exercised |
|---|---:|---|
| `nicolaka/netshoot:v0.16` | 01–06, 14 | DNS, HTTP/TCP, routing, sockets, NetworkPolicy, TLS, nmap, tcpdump, iperf3, node namespaces |
| `eclipse-temurin:21-jdk-jammy` | 07–09 | jcmd, jstat, thread dumps, heap histograms/dumps, NMT, JFR |
| `debug-dojo-arthas-jdk21:local` | 08, 10 | dashboard, threads, decompile, trace, watch, stack, profiler |
| `tazhate/k8s-debug-container-storage` | 11 | mounts, disk usage, iostat, fio |
| `tazhate/k8s-debug-container-db` | 12 | pg_isready, psql, DB connectivity/auth |
| `tazhate/k8s-debug-container-perf` | 13 | ps/htop, strace, /proc, perf/BCC where supported |
| `tazhate/k8s-debug-container-stress` | 15 | hey, stress-ng, sysbench, controlled load |
| `intel/gprofiler:latest` | 16 | system-wide CPU profiles and local flamegraphs |

`grafana/alloy` + Pyroscope is intentionally not part of this dojo because it is a continuously deployed observability/profiling component rather than an on-demand debug Pod.

## What was removed from v2

These labs were removed because the debug image was optional or irrelevant to the core lesson:

- CrashLoop startup configuration
- readiness/liveness/startup probes
- ImagePullBackOff
- init-container failure
- missing ConfigMap key
- RBAC / ServiceAccount
- impossible resource requests
- Pending PVC / StorageClass
- HPA unknown metrics
- ResourceQuota

Those are good Kubernetes troubleshooting exercises, but they do not specifically train debug-container functionality.

## Prerequisites

- Docker
- k3d 5.x
- kubectl
- About 6 GB of Docker memory is comfortable

## Start

```bash
chmod +x scripts/*.sh
./scripts/up.sh
```

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
./scripts/check-lab.sh 07
```

Reset one lab:

```bash
./scripts/reset-lab.sh 07
```

Apply the reference fix:

```bash
./scripts/solve-lab.sh 07
```

Static validation:

```bash
./scripts/validate.sh
```

Full disposable-cluster reference test:

```bash
./scripts/e2e-test.sh
```

Destroy:

```bash
./scripts/down.sh
```

## Design

The training Java application is Java 21 running on a distroless runtime, deliberately without a normal shell. That makes `kubectl debug` the intended way to bring JDK and diagnostic tooling to the running application.

The Java attach labs share `/tmp` with the ephemeral debugger and use `profiles/java-attach.yaml` so the JDK/Arthas process runs as UID/GID 65532, matching the distroless application.

Storage Lab 11 uses `profiles/storage-data.yaml` to mount the application's existing `data` volume into the storage debug container.

## Reference documentation

- Kubernetes `kubectl debug`: https://kubernetes.io/docs/reference/kubectl/generated/kubectl_debug/
- Ephemeral containers: https://kubernetes.io/docs/concepts/workloads/pods/ephemeral-containers/
- Netshoot: https://github.com/nicolaka/netshoot
- Specialized Kubernetes debug containers: https://github.com/tazhate/k8s-debug-container
- Arthas: https://arthas.aliyun.com/en/doc/
- gProfiler: https://github.com/intel/gprofiler


### Arthas filesystem visibility

For Labs 08 and 10, the Arthas ephemeral container stages `/opt/arthas` into `/tmp/arthas-shared` before attaching. `/tmp` is a shared `emptyDir` mounted in the application and debugger containers. This is required because Arthas loads an agent JAR into the target JVM by pathname, and an ephemeral container does not otherwise share the target container's root filesystem.
