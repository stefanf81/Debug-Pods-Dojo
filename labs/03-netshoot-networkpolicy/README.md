# Lab 03: Netshoot: NetworkPolicy isolation

**Required debug image:** `nicolaka/netshoot`

## Goal

The backend is healthy and DNS resolves, but the application client cannot connect. Use differently labelled Netshoot Pods to demonstrate exactly what the policy permits.

## What to practice

- Independent Netshoot Pod with and without `access=allowed`
- `curl`, `nc`, `tcpdump`
- Distinguish DNS success from TCP policy failure

## Success condition

The real `client` workload can reach `backend:8080`.

Use `../../scripts/check-lab.sh 03` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
