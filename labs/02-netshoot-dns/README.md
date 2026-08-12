# Lab 02: Netshoot: DNS resolution

**Required debug image:** `nicolaka/netshoot`

## Goal

`caller` returns 502 when it tries to reach its dependency. Determine whether DNS itself is broken or the application is asking for the wrong name.

## What to practice

- `dig`, `drill`, `nslookup`
- `/etc/resolv.conf`
- FQDN versus short Service names
- `curl` to the dependency from the caller Pod network namespace

## Success condition

`curl http://caller:8080/dependency` returns the backend health response.

Use `../../scripts/check-lab.sh 02` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
