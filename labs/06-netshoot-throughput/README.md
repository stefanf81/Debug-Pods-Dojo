# Lab 06: Netshoot: nmap, iperf3 and packet capture

**Required debug image:** `nicolaka/netshoot`

## Goal

A non-HTTP performance endpoint is unreachable through its Service. Discover the real listening port, repair the Service, then benchmark and capture the traffic.

## What to practice

- `nmap` against Pod IP
- `ss` inside the server Pod namespace
- `iperf3 -c iperf-server`
- `tcpdump -i any -nn port 5201`
- Optional `mtr` between Pods

## Success condition

`iperf3 -c iperf-server` completes successfully.

Use `../../scripts/check-lab.sh 06` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
