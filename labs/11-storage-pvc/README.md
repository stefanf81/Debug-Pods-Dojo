# Lab 11: Storage toolbox: mounted PVC diagnostics

**Required debug image:** `tazhate/k8s-debug-container-storage`

## Goal

The distroless app cannot write its mounted PVC. Mount the same volume into a storage debug ephemeral container and inspect it directly.

## What to practice

- `id`, `ls -ld`, `/proc/mounts`, `df`, `du`, `ncdu`
- `iostat`
- Safe `fio` against a dedicated test file
- Compare debug-container UID/GID and mount permissions

## Success condition

The Java writer can create `/data/dojo.txt`.

From the repository root, run `./scripts/check-lab.sh 11` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
