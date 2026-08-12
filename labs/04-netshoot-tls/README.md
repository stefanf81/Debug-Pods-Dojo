# Lab 04: Netshoot: TLS/protocol mismatch

**Required debug image:** `nicolaka/netshoot`

## Goal

The Service is advertised as HTTPS, but TLS negotiation fails. Determine whether the problem is certificate validation, TCP connectivity, or the wrong protocol behind the Service.

## What to practice

- `openssl s_client`
- `curl -vk`
- `nc -vz`
- Compare the Pod's HTTP and HTTPS ports
- Inspect the presented certificate and TLS handshake

## Success condition

`curl -k https://tls-server/health` returns `TLS-OK`.

Use `../../scripts/check-lab.sh 04` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
