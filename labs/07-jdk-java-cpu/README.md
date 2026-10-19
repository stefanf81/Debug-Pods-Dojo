# Lab 07: Temurin JDK: high CPU + JFR

**Required debug image:** `eclipse-temurin:21.0.12.1_1-jdk-jammy`

## Goal

The distroless Java process burns CPU. Attach a JDK ephemeral container and identify the hot thread without adding tools to the application image.

## What to practice

- `jcmd -l`, `VM.version`, `VM.flags`
- `Thread.print -l`
- `jstat`
- `JFR.start` / `JFR.check`
- `VM.native_memory summary`
- Copy a `.jfr` recording out of the Pod

## Success condition

The `dojo-cpu-burner` thread is identified and the workload is returned to normal mode.

From the repository root, run `./scripts/check-lab.sh 07` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
