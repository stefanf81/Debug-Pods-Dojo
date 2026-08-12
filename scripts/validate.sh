#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Bash syntax"
for script in "$ROOT"/scripts/*.sh; do bash -n "$script"; done

echo "==> Lab structure"
count=0
for lab in "$ROOT"/labs/*; do
  [[ -d "$lab" ]] || continue
  for file in broken.yaml fixed.yaml README.md; do
    [[ -f "$lab/$file" ]] || { echo "Missing $lab/$file" >&2; exit 1; }
  done
  count=$((count + 1))
done
[[ "$count" == "16" ]] || { echo "Expected 16 labs, found $count" >&2; exit 1; }
echo "    16 labs"

if command -v kubectl >/dev/null 2>&1; then
  echo "==> kubectl client-side manifest decode"
  for file in "$ROOT"/labs/*/{broken,fixed}.yaml; do
    kubectl apply --dry-run=client --validate=false -f "$file" >/dev/null
  done
else
  echo "==> kubectl not installed; skipping kubectl manifest decode"
fi

if command -v javac >/dev/null 2>&1; then
  echo "==> Java 21 compile"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  javac --release 21 -d "$tmp" "$ROOT/images/java-dojo/src/dojo/DojoApp.java"
  if command -v java >/dev/null 2>&1 && command -v jar >/dev/null 2>&1 && command -v jcmd >/dev/null 2>&1; then
    echo "==> Local -jar / jcmd PID-selection smoke"
    jar --create --file "$tmp/dojo.jar" --main-class dojo.DojoApp -C "$tmp" dojo
    (
      PORT=0 DOJO_MODE=cpu JAVA_TOOL_OPTIONS='-XX:NativeMemoryTracking=summary' java -jar "$tmp/dojo.jar" >"$tmp/java-smoke.log" 2>&1 &
      app_pid=$!
      trap 'kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true' EXIT
      found=""
      for _ in $(seq 1 30); do
        found=$(jcmd -l | grep dojo.jar | cut -d" " -f1 | head -1 || true)
        [[ -n "$found" ]] && break
        sleep 0.2
      done
      [[ -n "$found" ]] || { echo "jcmd -l did not report dojo.jar" >&2; exit 1; }
      [[ "$found" == "$app_pid" ]] || { echo "jcmd PID selection chose $found, expected $app_pid" >&2; exit 1; }
      jcmd "$found" Thread.print -l | grep -q dojo-cpu-burner
    )
  fi
else
  echo "==> javac not installed; Docker build will compile Java"
fi


echo "==> LABS.md command guardrails"
! grep -q 'tracepath ' "$ROOT/LABS.md" || { echo "Netshoot v0.16 does not install tracepath; use tcptraceroute" >&2; exit 1; }
! sed -n '/## Lab 11/,/## Lab 12/p' "$ROOT/LABS.md" | grep -q 'ioping ' || { echo "Storage image does not install ioping" >&2; exit 1; }
for line in $(grep -n -- '--custom=profiles/' "$ROOT/LABS.md" | cut -d: -f1); do
  start=$((line > 5 ? line - 5 : 1))
  sed -n "${start},${line}p" "$ROOT/LABS.md" | grep -q -- '--profile=general' || { echo "Custom debug profile near LABS.md:$line lacks explicit --profile=general" >&2; exit 1; }
done
grep -q "ngrep -d any -W byline '.' 'tcp port 5201'" "$ROOT/LABS.md" || { echo "Expected corrected ngrep syntax is missing" >&2; exit 1; }
grep -q -- '--perf-mode disabled' "$ROOT/LABS.md" || { echo "Expected gProfiler perf-less fallback is missing" >&2; exit 1; }

# BIND dig does not apply resolv.conf search domains by default. Short Service names that are expected to resolve must use +search.
for bad in 'dig api' 'dig backend'; do
  # Lab 02 intentionally keeps one bare "dig backend" as a teaching contrast; reject other bare success examples.
  count=$(grep -Fxc "$bad" "$ROOT/LABS.md" || true)
  if [[ "$bad" == 'dig backend' ]]; then
    [[ "$count" -le 1 ]] || { echo "Unexpected bare short-name dig examples remain: $bad" >&2; exit 1; }
  else
    [[ "$count" -eq 0 ]] || { echo "Bare short-name dig must use +search: $bad" >&2; exit 1; }
  fi
done
grep -q 'dig +search api' "$ROOT/LABS.md" || { echo "Expected dig +search api examples are missing" >&2; exit 1; }
grep -q 'dig +search backend' "$ROOT/LABS.md" || { echo "Expected dig +search backend examples are missing" >&2; exit 1; }
grep -q 'drill backend.dojo-02-dns.svc.cluster.local' "$ROOT/LABS.md" || { echo "Expected FQDN drill example is missing" >&2; exit 1; }

# Nested-shell PID-selection guardrails. The training app is started with `java -jar /app/dojo.jar`,
# so jcmd/jps report the JAR path rather than the main class name. Avoid awk `$1` programs
# embedded in single-quoted bash -lc strings: that quoting shape caused a real command-E2E failure.
! grep -q 'awk "/dojo.DojoApp' "$ROOT/scripts/command-e2e-test.sh" || { echo "Fragile nested awk PID parsing returned" >&2; exit 1; }
! grep -q 'jcmd -l | grep dojo.DojoApp' "$ROOT/scripts/command-e2e-test.sh" || { echo "jcmd -l must match dojo.jar for -jar launches" >&2; exit 1; }
! grep -q 'jps -l | grep dojo.DojoApp' "$ROOT/scripts/command-e2e-test.sh" || { echo "jps -l must match dojo.jar for -jar launches" >&2; exit 1; }
grep -q 'jcmd -l | grep dojo.jar' "$ROOT/scripts/command-e2e-test.sh" || { echo "Expected dojo.jar jcmd PID selection is missing" >&2; exit 1; }
grep -q 'jps -l | grep dojo.jar' "$ROOT/scripts/command-e2e-test.sh" || { echo "Expected dojo.jar jps PID selection is missing" >&2; exit 1; }

echo "Validation completed"

# Command-E2E NetworkPolicy guardrails
grep -q 'wait --for=condition=Ready pod/cmd03allow' "$ROOT/scripts/command-e2e-test.sh"
grep -q 'metadata.labels.access' "$ROOT/scripts/command-e2e-test.sh"
grep -q 'seq 1 30' "$ROOT/scripts/command-e2e-test.sh"

# Arthas debug image must use the Java 21 JDK while sourcing official Arthas files.
grep -q '^FROM eclipse-temurin:21-jdk-jammy' "$ROOT/images/arthas-jdk21/Dockerfile"
grep -q '^FROM hengyunabc/arthas@sha256:' "$ROOT/images/arthas-jdk21/Dockerfile"
grep -q 'debug-dojo-arthas-jdk21:local' "$ROOT/LABS.md"
if grep -q -- '--image=hengyunabc/arthas' "$ROOT/LABS.md"; then
  echo "LABS.md still launches the JDK8-based public Arthas image directly" >&2
  exit 1
fi

# Arthas ephemeral-container attach must stage the agent on a filesystem visible to the target JVM.
python3 - "$ROOT/scripts/command-e2e-test.sh" "$ROOT/LABS.md" "$ROOT/profiles/java-attach.yaml" <<'PY'
from pathlib import Path
import sys
script=Path(sys.argv[1]).read_text()
labs=Path(sys.argv[2]).read_text()
profile=Path(sys.argv[3]).read_text()
assert script.count('cp -R /opt/arthas/. /tmp/arthas-shared/') >= 2, 'Arthas E2E checks must stage files into shared /tmp'
assert script.count('java -jar /tmp/arthas-shared/arthas-boot.jar') >= 2, 'Arthas E2E checks must launch boot jar from shared /tmp'
assert labs.count('cp -R /opt/arthas/. /tmp/arthas-shared/') >= 2, 'LABS.md must teach shared Arthas staging'
assert 'name: shared-tmp' in profile and 'mountPath: /tmp' in profile, 'java attach profile must mount shared /tmp'
print('Arthas shared-filesystem attach guardrails: PASS')
PY
