# Lab 14: Node debug: host namespaces and sockets

**Required debug image:** `nicolaka/netshoot` via `kubectl debug node/...`

## Goal

A workload cannot schedule because a required host port is already occupied on the exact node it must use. Enter the node namespaces with a debug Pod and identify the listener.

## What to practice

- `kubectl debug node/<node> --profile=sysadmin`
- `ss -lntp`, `ip addr`, `ip route`, `ps`
- Inspect `/host`
- Understand host-network/hostPort state from inside the node debug Pod

## Success condition

The victim runs on a non-conflicting host port.

From the repository root, run `./scripts/check-lab.sh 14` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
