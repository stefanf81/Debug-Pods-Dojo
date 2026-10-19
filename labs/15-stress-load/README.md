# Lab 15: Stress toolbox: reproduce load

**Required debug image:** `tazhate/k8s-debug-container-stress`

## Goal

The service is functionally correct but slow enough that concurrency amplifies the problem. Use the stress/debug image to reproduce the symptom consistently and quantify the difference after the repair.

## What to practice

- `hey -n ... -c ... http://api:8080/slow`
- `stress-ng` and `sysbench` for controlled CPU/memory experiments in the debug Pod
- `fio` only on scratch data
- Observe the target with `kubectl top` while generating load

## Success condition

Repeated `hey` runs show the repaired `/slow` endpoint completing much faster.

From the repository root, run `./scripts/check-lab.sh 15` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
