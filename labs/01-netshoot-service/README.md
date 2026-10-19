# Lab 01: Netshoot: Service/TCP path

**Required debug image:** `nicolaka/netshoot`

## Goal

The application Pod is healthy, but the Service does not work. Use Netshoot to prove where the request stops.

## What to practice

- Same-Pod ephemeral Netshoot
- Separate Netshoot client Pod
- `curl`, `nc`, `ss`, `ip addr`, `ip route`, `dig`
- Compare Pod IP access with Service access

## Success condition

`curl http://api:8080/health` succeeds through the Service.

From the repository root, run `./scripts/check-lab.sh 01` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
