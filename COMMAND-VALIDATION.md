# Command-level validation — v9 final

`v9-command-validated` is the first frozen release for which both the Kubernetes reference states and the learner-facing debug commands have been validated on a real k3d environment.

## Final runtime validation

**Validation date:** August 12, 2026  
**Runtime:** Rancher Desktop  
**Cluster:** k3d, 1 server + 2 agents  
**Architecture observed in the workload:** `aarch64`  
**Dojo version:** `v9-command-validated`

The final command-level run completed with:

```text
Command-level test complete: 22 PASS, 0 SKIP
Cluster: k3d-debug-pods-dojo-command-e2e
COMMAND E2E: PASS
```

No command-level checks failed or were skipped.

## What passed

| Area | Runtime-validated capabilities | Result |
|---|---|---|
| Netshoot / Service | Kubernetes DNS search behavior, direct Pod IP, intentionally broken Service path, ephemeral `ss` / `ip` / localhost access | PASS |
| Netshoot / DNS | `dig`, `drill`, `nslookup`, typo diagnosis | PASS |
| Netshoot / NetworkPolicy | denied client plus labelled/allowed client after policy reconciliation | PASS |
| Netshoot / TLS | `nc`, `openssl`, `curl`, `nmap`, wrong-protocol/TLS diagnosis | PASS |
| Netshoot / Ingress | backend/Service succeeds while intentionally broken Ingress path fails | PASS |
| Netshoot / advanced networking | `nmap`, `iperf3`, `mtr`, `tcptraceroute`, `termshark`, `tcpdump`, `tshark`, `ngrep` | PASS |
| Temurin/JDK | `jcmd`, `jps`, `jstack`, `jmap`, `jinfo`, `jstat`, JFR, Native Memory Tracking | PASS |
| JDK deadlock | blocked-thread / deadlock diagnosis | PASS |
| Arthas deadlock | attach, batch client, `dashboard`, `thread --state BLOCKED` | PASS |
| Java memory | heap histogram, GC/NMT inspection, heap dump | PASS |
| Arthas application diagnostics | `dashboard`, `jvm`, `memory`, `thread`, `classloader`, `sc`, `sm`, `jad`, `logger`, cleanup workflow | PASS |
| Storage | PVC mount, `df`, `du`, `ncdu`, `iostat`, `dd`, `fio` | PASS |
| PostgreSQL | `pg_isready`, `psql`, bad-auth versus valid-auth diagnosis | PASS |
| Syscall/perf | process visibility, `htop`, `strace`, `perf` binary surface | PASS |
| Node debug | host namespaces, `/host`, firewall and service-routing tools | PASS |
| Stress/load | `hey`, `stress-ng`, `sysbench`, `ioping`, `fio` | PASS |
| Metrics | `kubectl top --containers` with Metrics Server warm-up handling | PASS |
| gProfiler | runtime-only fallback when host perf mode is unavailable | PASS |

The script reports **22 PASS** because several labs intentionally contain more than one independently checked debug workflow.

## Validation layers

The project now has three complementary validation layers:

1. **Local/static validation — `make validate` / `scripts/validate.sh`**
   - Bash syntax
   - 16-lab structure
   - Kubernetes manifest decode when `kubectl` is available
   - Java 21 compilation
   - local `java -jar` / `jcmd` PID-selection smoke test
   - learner-command guardrails for known image/tool differences
   - Arthas image and shared-filesystem guardrails

2. **Reference-state E2E — `make e2e`**
   - creates a disposable k3d cluster
   - confirms all scenarios begin in their expected broken reference state
   - applies every reference repair
   - confirms all repaired states pass

3. **Learner-command E2E — `make command-e2e`**
   - creates a separate disposable k3d cluster
   - runs the real commands and debug-image workflows documented in `LABS.md`
   - covers throwaway debug Pods, ephemeral containers, custom profiles and node debug Pods
   - restores the previous kubeconfig context on cleanup

## Important fixes proven by the runtime runs

### Kubernetes DNS search behavior

BIND `dig` does not apply the Pod's search domains by default. Short Service names that should use Kubernetes DNS search suffixes therefore use:

```bash
dig +search +short <service>
```

The DNS lab retains a bare `dig` example deliberately so learners can observe this distinction.

### NetworkPolicy reconciliation

The labelled/allowed Netshoot client is created first, confirmed Ready and correctly labelled, then connectivity is retried for a bounded period. This tests the intended policy result instead of requiring the network-policy controller to reconcile within the first millisecond after Pod creation.

### Java PID selection

The application is launched as:

```text
java -jar /app/dojo.jar
```

Consequently `jcmd -l` and `jps -l` expose the JAR path. The validators select `dojo.jar` rather than assuming the main class name is reported. Fragile nested `awk '$1'` PID parsers were removed after a real shell-quoting failure.

### Arthas JDK and filesystem visibility

The dojo builds `debug-dojo-arthas-jdk21:local`, using Temurin 21 and copying the Arthas distribution from the pinned official Arthas image. This matches the debugger JVM major to the Java 21 target.

The more important Kubernetes-specific fix is filesystem visibility. An ephemeral debugger can target the application process namespace, but it does not share the target container's root filesystem. Arthas instructs the target JVM to load an agent JAR by pathname. Therefore Labs 08 and 10 stage the complete Arthas distribution into:

```text
/tmp/arthas-shared
```

`/tmp` is a shared `emptyDir` mounted by both the application and debug container, so the target JVM can resolve the same agent path. The validator confirms `arthas-agent.jar` exists and includes an `Agent-Class` manifest entry before attaching.

This exact workflow was proven in the final runtime run: Arthas attached to PID 1, reported the Java 21 target, detected both deadlocked threads, and completed the Lab 10 diagnostics.

### gProfiler on Rancher Desktop

The final run found normal host/perf profiling unavailable in the VM-backed Rancher Desktop environment. The suite then used the documented perf-less/runtime-only fallback and passed. This behavior is intentional: the dojo distinguishes a host capability restriction from a broken gProfiler workflow.

## Command guardrails retained in v9

- Netshoot short-name DNS success checks use `dig +search`
- NetworkPolicy allowed-client checks retry for dataplane convergence
- `nmap` assertions require an actual `open` state
- Metrics Server checks tolerate initial metrics warm-up
- Java PID selection matches `dojo.jar`
- nested-shell `awk` PID parsing is rejected
- storage exercises use tools actually present in the storage image; `ioping` stays in the stress image
- long-running or interactive tools use bounded/non-interactive equivalents in automation
- JFR and heap-dump instructions include a streaming fallback for environments where `kubectl cp` cannot use `tar`
- Arthas automated commands are bounded; interactive instrumentation cleanup remains part of the learner guide
- Arthas agent files are staged on the shared `/tmp` volume before attach

## Release decision

With the final **22 PASS / 0 SKIP / 0 FAIL** command-level run, v9 is considered technically validated and frozen. Future changes should be treated as new feature work or a new version and should rerun both:

```bash
make e2e
make command-e2e
```
