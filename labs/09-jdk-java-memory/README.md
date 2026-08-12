# Lab 09: Temurin JDK: heap growth and dump

**Required debug image:** `eclipse-temurin:21-jdk-jammy`

## Goal

The Java heap steadily grows. Attach before it reaches OOM and determine what is accumulating.

## What to practice

- `jcmd <PID> GC.class_histogram`
- `jstat -gc`
- `jcmd <PID> GC.heap_dump /tmp/heap.hprof`
- `VM.native_memory summary`
- `kubectl cp` or streamed copy of heap/JFR artifacts

## Success condition

The retained `byte[]` growth is diagnosed and leak mode is disabled.

Use `../../scripts/check-lab.sh 09` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
