# Lab 08: Temurin JDK / Arthas: Java deadlock

**Required debug image:** `eclipse-temurin:21.0.12.1_1-jdk-jammy or debug-dojo-arthas-jdk21:local`

## Goal

The HTTP process is alive but two background threads are deadlocked. Prove the deadlock from an attached debugger.

## What to practice

- `jcmd <PID> Thread.print -l`
- Arthas `thread` and `thread --state BLOCKED`
- Compare JVM process visibility from an ephemeral container

## Success condition

The deliberate deadlock is identified and the deployment is returned to normal mode.

From the repository root, run `./scripts/check-lab.sh 08` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
