# Lab 13: Performance toolbox: syscalls and processes

**Required debug image:** `tazhate/k8s-debug-container-perf`

## Goal

The Java process performs periodic filesystem writes. Attach a privileged performance toolbox and observe the behavior at process/syscall level.

## What to practice

- `ps`, `htop`
- `strace -p <PID>` and file-related syscall filters
- `/proc/<PID>/fd`
- `perf top` / `perf record` where the host kernel permits it
- BCC tools where supported by your Docker/k3d host

## Success condition

The periodic writer is identified and disabled. Kernel-level `perf`/BCC steps are optional if your host blocks them.

Use `../../scripts/check-lab.sh 13` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
