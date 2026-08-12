# Answers

## Lab 01

Service `api` has `targetPort: 8081`; change it to `8080`.

## Lab 02

`DEPENDENCY_URL` uses `backned`; change it to `backend`.

## Lab 03

The NetworkPolicy admits only Pods with `access=allowed`; add that label to the client Pod template.

## Lab 04

The HTTPS Service targets NGINX's plain HTTP port 8080; target 8443.

## Lab 05

The Ingress backend references Service port 8081; use 8080.

## Lab 06

The iperf Service targets 5202 while the server listens on 5201.

## Lab 07

Disable `DOJO_MODE=cpu` after identifying `dojo-cpu-burner`.

## Lab 08

Disable `DOJO_MODE=deadlock` after proving the deadlock.

## Lab 09

Disable `DOJO_MODE=leak` after proving retained byte-array growth.

## Lab 10

Reduce the deliberate `SLOW_MS` delay after tracing `slowWork`.

## Lab 11

Prepare `/data` for UID/GID 65532 with ownership and write permissions.

## Lab 12

Use `postgres-auth` Secret for `PGPASSWORD` rather than the wrong literal password.

## Lab 13

Disable `DOJO_MODE=writer` after tracing the periodic writes.

## Lab 14

Move the victim to a non-conflicting host port (reference uses 18081).

## Lab 15

Reduce the deliberate `SLOW_MS` value after measuring it with `hey`.

## Lab 16

Disable `DOJO_MODE=cpu` after capturing a system-wide profile.

