# Lab 12: Database toolbox: PostgreSQL connectivity/auth

**Required debug image:** `tazhate/k8s-debug-container-db`

## Goal

PostgreSQL is reachable and healthy, but the application client cannot authenticate. Prove network reachability separately from database authentication.

## What to practice

- `pg_isready`
- `psql`
- Distinguish connection refusal, DNS failure, and authentication failure
- Run SQL from a throwaway DB debug Pod

## Success condition

The DB client authenticates with the Secret and its query succeeds.

Use `../../scripts/check-lab.sh 12` after you repair the scenario. Do not open `fixed.yaml` unless you want the reference repair.
