# Changelog

All notable changes to the focused Debug Pods Dojo are recorded here.

## v9-command-validated — 2026-08-12

**Status: frozen, fully validated release.**

- Completed a real Rancher Desktop + k3d command-level validation run with **22 PASS, 0 SKIP, 0 FAIL**.
- Confirmed all 16 debug-pod-focused lab scenarios and learner command families work in the validated environment.
- Fixed Arthas attach across container filesystem boundaries by staging `/opt/arthas` into the shared `/tmp/arthas-shared` `emptyDir` before attachment.
- Added pre-attach validation for `arthas-agent.jar` and its `Agent-Class` manifest entry.
- Confirmed Arthas deadlock detection and the broader Lab 10 diagnostic surface on the real Java 21 target.
- Confirmed storage, PostgreSQL, syscall/perf, node-debug, stress/load, Metrics Server and gProfiler fallback workflows.
- Documented that gProfiler normal perf mode may be unavailable under VM-backed Rancher Desktop; the runtime-only fallback passed.
- Updated release documentation to reflect the final runtime result.

## v8-command-validated — 2026-08-12

- Added a project-built `debug-dojo-arthas-jdk21:local` image based on Temurin 21 with the Arthas distribution copied from the pinned official image.
- Stopped using the public Arthas container's own Java runtime directly against the Java 21 target.
- Improved Arthas failure logging and version visibility.
- Added the `VERSION` file and startup version banner.

## v7-command-validated — 2026-08-12

- Removed fragile nested-shell `awk` PID parsing from Java/perf validators.
- Corrected JDK/Arthas PID discovery to match `dojo.jar` for `java -jar` launches.
- Added a local Java 21 `java -jar` / `jcmd` PID-selection smoke test to `validate.sh`.

## v6-command-validated — 2026-08-12

- Made NetworkPolicy validation wait for the labelled debug Pod and retry for dataplane reconciliation.
- Improved diagnostic output for policy failures.

## v5-command-validated — 2026-08-12

- Corrected Kubernetes short-name DNS examples to use `dig +search`.
- Hardened `nmap` assertions to require open ports.
- Added Metrics Server warm-up retries.
- Improved per-command failure diagnostics.

## v4-command-validated — 2026-08-12

- Added `make command-e2e` and command-level validation of learner-facing debug commands.
- Corrected several command/image mismatches, including Netshoot tracing, storage tooling, custom profile usage and bounded automation for interactive tools.

## v3 focused — 2026-08-09

- Refocused the project exclusively on debug-container capabilities.
- Removed generic Kubernetes troubleshooting exercises where a debug Pod was optional.
- Organized the dojo around Netshoot, JDK, Arthas, storage, database, performance, node, stress and profiling capabilities.
