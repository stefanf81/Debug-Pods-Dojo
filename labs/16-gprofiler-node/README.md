# Lab 16: gProfiler: node-wide CPU profile

**Required debug image:** `intel/gprofiler`

## Goal

A Java workload burns CPU. Profile it from the node rather than attaching Java tooling directly to the application.

## What to practice

- Find the node hosting the Pod
- Run `intel/gprofiler` with host PID visibility / privileged access
- Generate a time-bounded local profile/flame graph
- Distinguish Java application frames from JVM/native/kernel activity

## Success condition

The CPU burner is visible in a system-wide profile and is then disabled. This lab is optional on Docker Desktop/hosts that restrict perf/ptrace features.

From the repository root, run `./scripts/check-lab.sh 16` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
