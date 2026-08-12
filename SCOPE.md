# Scope: debug-pod functionality only

The guiding rule is:

> If an exercise can be completed meaningfully without launching a debug image, it does not belong in this dojo.

A few labs still use `kubectl get`, `describe`, logs or object inspection for orientation, but the **diagnostic evidence that the lab is designed to teach comes from a debug container**.

## Coverage matrix

| Lab | Debug mode | Image | Distinct capability |
|---|---|---|---|
| 01 | ephemeral + throwaway Pod | Netshoot | Service/TCP path, sockets, route/interface inspection |
| 02 | ephemeral | Netshoot | DNS and resolver configuration |
| 03 | labelled throwaway Pods | Netshoot | NetworkPolicy isolation |
| 04 | throwaway Pod | Netshoot | TLS handshake / protocol mismatch |
| 05 | throwaway Pod | Netshoot | Ingress → Service → Pod hop testing |
| 06 | ephemeral + throwaway Pod | Netshoot | nmap, iperf3, tcpdump, mtr |
| 07 | ephemeral attach | Temurin JDK | hot threads, JFR, jstat, NMT |
| 08 | ephemeral attach | Temurin / Arthas | deadlock analysis |
| 09 | ephemeral attach | Temurin JDK | heap growth, histogram, heap dump |
| 10 | ephemeral attach | Arthas | trace/watch/stack/jad/profiler |
| 11 | ephemeral + volume mount | storage toolbox | PVC/mount and IO analysis |
| 12 | throwaway Pod | DB toolbox | DB network/auth/query diagnosis |
| 13 | privileged ephemeral attach | perf toolbox | strace, process and kernel-level profiling |
| 14 | node debug Pod | Netshoot | host PID/network namespaces and `/host` |
| 15 | throwaway Pod | stress toolbox | repeatable load generation |
| 16 | node debug Pod | gProfiler | system-wide CPU profile / flamegraph |

## Intentionally not tested

This project does not try to become a general Kubernetes exam simulator. It intentionally excludes RBAC, quota, rollout, scheduler, ConfigMap/Secret, probe and image-pull exercises unless those topics are only supporting context for a debug-image capability.
