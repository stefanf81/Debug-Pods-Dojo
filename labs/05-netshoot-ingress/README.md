# Lab 05: Netshoot: Ingress → Service → Pod

**Required debug image:** `nicolaka/netshoot`

## Goal

Direct Pod and Service access work, but the path exposed through Traefik does not. Prove each hop independently with Netshoot.

## What to practice

- `curl` Pod IP, Service, and Ingress
- `dig`
- `nc`
- Endpoint/port comparison from a network toolbox

## Success condition

`curl http://localhost:8080/dojo` succeeds from the host.

Use `../../scripts/check-lab.sh 05` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
