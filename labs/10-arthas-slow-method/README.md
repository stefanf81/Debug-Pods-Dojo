# Lab 10: Arthas: method-level live debugging

**Required debug image:** `debug-dojo-arthas-jdk21:local`

## Goal

`GET /slow` takes about four seconds. Use Arthas against the running distroless JVM to show exactly which method is responsible and observe its result.

## What to practice

- `dashboard`, `jvm`, `memory`
- `sc`, `sm`, `jad`
- `trace dojo.DojoApp slowWork`
- `watch ... '{params,returnObj,throwExp}'`
- `stack`
- `profiler start/stop`

## Success condition

`/slow` completes quickly after the reference repair, and you have traced `slowWork` live.

Use `../../scripts/check-lab.sh 10` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
