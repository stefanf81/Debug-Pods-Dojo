#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

die() { echo "$*" >&2; exit 1; }
need_text() { grep -qF -- "$2" "$1" || die "$3"; }
forbid_text() { ! grep -qF -- "$2" "$1" || die "$3"; }
occurrences() { grep -oF -- "$2" "$1" | wc -l; }

echo "==> Bash syntax and executable bits"
for script in "$ROOT"/scripts/*.sh; do
  bash -n "$script"
  [[ "$(basename "$script")" == lib.sh || -x "$script" ]] \
    || die "$script is not executable; run: git update-index --chmod=+x ${script#"$ROOT"/}"
done
# macOS ships bash 3.2, which has no mapfile/readarray.
! grep -nE '^([^#]*[^#[:alnum:]_])?(mapfile|readarray)[[:space:]]' "$ROOT"/scripts/*.sh \
  || die "Scripts must stay bash 3.2 compatible: read into arrays with a while-read loop instead of mapfile/readarray"

echo "==> Lab structure"
count=0
for lab in "$ROOT"/labs/*; do
  [[ -d "$lab" ]] || continue
  for file in broken.yaml fixed.yaml README.md; do
    [[ -f "$lab/$file" ]] || die "Missing $lab/$file"
  done
  [[ -n "$(lab_namespace "$lab")" ]] || die "Cannot determine the dojo-* Namespace of $(basename "$lab")"
  num="$(basename "$lab")"; num="${num%%-*}"
  grep -qE "^  ${num}\)" "$ROOT/scripts/check-lab.sh" || die "check-lab.sh has no checker for lab $num"
  count=$((count + 1))
done
(( count > 0 )) || die "No labs found"
echo "    $count labs"

if command -v kubectl >/dev/null 2>&1; then
  # `kubectl label --local` decodes manifests without contacting any cluster or reading the current context.
  echo "==> kubectl offline manifest decode"
  for file in "$ROOT"/labs/*/{broken,fixed}.yaml; do
    KUBECONFIG="$tmp/no-kubeconfig" kubectl label --local -f "$file" dojo-validate=true -o name >/dev/null \
      || die "kubectl could not decode $file"
  done
else
  echo "==> kubectl not installed; skipping manifest decode"
fi
if command -v kubeconform >/dev/null 2>&1; then
  echo "==> kubeconform schema validation"
  kubeconform -strict -summary -kubernetes-version "${KUBERNETES_VERSION:-1.31.0}" "$ROOT"/labs/*/{broken,fixed}.yaml
else
  # `kubectl label --local` only catches YAML syntax errors, not misspelled fields or wrong types.
  echo "==> kubeconform not installed; skipping schema validation (CI installs it)"
fi

if command -v javac >/dev/null 2>&1; then
  echo "==> Java 21 compile"
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
      [[ -n "$found" ]] || die "jcmd -l did not report dojo.jar"
      [[ "$found" == "$app_pid" ]] || die "jcmd PID selection chose $found, expected $app_pid"
      # jcmd -l lists the JVM during VM startup, before main() has started the burner thread, so poll the dump too.
      shown=""
      for _ in $(seq 1 50); do
        if jcmd "$found" Thread.print -l >"$tmp/threads.txt" 2>&1 && grep -q dojo-cpu-burner "$tmp/threads.txt"; then
          shown=1
          break
        fi
        sleep 0.2
      done
      [[ -n "$shown" ]] || die "jcmd Thread.print did not show dojo-cpu-burner"
    )
  fi
else
  echo "==> javac not installed; Docker build will compile Java"
fi

LABS_MD="$ROOT/LABS.md"
CMD_E2E="$ROOT/scripts/command-e2e-test.sh"

echo "==> LABS.md command guardrails"
forbid_text "$LABS_MD" 'tracepath ' "Netshoot v0.16 does not install tracepath; use tcptraceroute"
! sed -n '/## Lab 11/,/## Lab 12/p' "$LABS_MD" | grep -q 'ioping ' || die "Storage image does not install ioping"
for line in $(grep -n -- '--custom=profiles/' "$LABS_MD" | cut -d: -f1); do
  start=$((line > 5 ? line - 5 : 1))
  sed -n "${start},${line}p" "$LABS_MD" | grep -q -- '--profile=general' || die "Custom debug profile near LABS.md:$line lacks explicit --profile=general"
done
need_text "$LABS_MD" "ngrep -d any -W byline '.' 'tcp port 5201'" "Expected corrected ngrep syntax is missing"
need_text "$LABS_MD" '--perf-mode disabled' "Expected gProfiler perf-less fallback is missing"

# BIND dig does not apply resolv.conf search domains by default. Short Service names that are expected to resolve must use +search.
for bad in 'dig api' 'dig backend'; do
  # Lab 02 intentionally keeps one bare "dig backend" as a teaching contrast; reject other bare success examples.
  count=$(grep -Fxc "$bad" "$LABS_MD" || true)
  if [[ "$bad" == 'dig backend' ]]; then
    [[ "$count" -le 1 ]] || die "Unexpected bare short-name dig examples remain: $bad"
  else
    [[ "$count" -eq 0 ]] || die "Bare short-name dig must use +search: $bad"
  fi
done
need_text "$LABS_MD" 'dig +search api' "Expected dig +search api examples are missing"
need_text "$LABS_MD" 'dig +search backend' "Expected dig +search backend examples are missing"
need_text "$LABS_MD" 'drill backend.dojo-02-dns.svc.cluster.local' "Expected FQDN drill example is missing"

# Nested-shell PID-selection guardrails. The training app is started with `java -jar /app/dojo.jar`,
# so jcmd/jps report the JAR path rather than the main class name. Avoid awk `$1` programs
# embedded in single-quoted bash -lc strings: that quoting shape caused a real command-E2E failure.
forbid_text "$CMD_E2E" 'awk "/dojo.DojoApp' "Fragile nested awk PID parsing returned"
forbid_text "$CMD_E2E" 'jcmd -l | grep dojo.DojoApp' "jcmd -l must match dojo.jar for -jar launches"
forbid_text "$CMD_E2E" 'jps -l | grep dojo.DojoApp' "jps -l must match dojo.jar for -jar launches"
need_text "$CMD_E2E" 'jcmd -l | grep dojo.jar' "Expected dojo.jar jcmd PID selection is missing"
need_text "$CMD_E2E" 'jps -l | grep dojo.jar' "Expected dojo.jar jps PID selection is missing"

echo "==> Command-E2E NetworkPolicy guardrails"
need_text "$CMD_E2E" 'wait --for=condition=Ready pod/cmd03allow' "Lab 03 E2E must wait for the allowed debug Pod"
need_text "$CMD_E2E" 'metadata.labels.access' "Lab 03 E2E must verify the access label"
need_text "$CMD_E2E" 'seq 1 30' "Lab 03 E2E must retry during NetworkPolicy convergence"

echo "==> Image pinning guardrails"
for dockerfile in "$ROOT"/images/*/Dockerfile; do
  while read -r from; do
    [[ "$from" == *@sha256:* ]] || die "${dockerfile#"$ROOT"/}: base image is not pinned by digest: $from"
  done < <(awk '$1 == "FROM" {print $2}' "$dockerfile")
done
# Every third-party debug image in the guide, the test scripts and the check probe must carry a digest.
debug_images='(nicolaka/netshoot|eclipse-temurin|tazhate/k8s-debug-container-[a-z]+|intel/gprofiler)'
for file in "$LABS_MD" "$CMD_E2E" "$ROOT/scripts/lib.sh" "$ROOT"/labs/*/*.yaml; do
  unpinned="$(grep -noE "${debug_images}[^[:space:]\"'\`)]*" "$file" | grep -v '@sha256:[0-9a-f]\{64\}' || true)"
  [[ -z "$unpinned" ]] || die "${file#"$ROOT"/}: debug images must be pinned by digest: ${unpinned//$'\n'/ }"
done

echo "==> Arthas debug image guardrails"
# Arthas debug image must use the Java 21 JDK while sourcing official Arthas files.
grep -qE '^FROM eclipse-temurin:21[^ ]*-jdk-jammy@sha256:' "$ROOT/images/arthas-jdk21/Dockerfile" || die "Arthas image must build on a pinned Temurin 21 JDK"
grep -q '^FROM hengyunabc/arthas@sha256:' "$ROOT/images/arthas-jdk21/Dockerfile" || die "Arthas files must come from the digest-pinned official image"
need_text "$LABS_MD" 'debug-dojo-arthas-jdk21:local' "LABS.md must use the Java 21 Arthas debug image"
forbid_text "$LABS_MD" '--image=hengyunabc/arthas' "LABS.md still launches the JDK8-based public Arthas image directly"

# Arthas ephemeral-container attach must stage the agent on a filesystem visible to the target JVM.
(( $(occurrences "$CMD_E2E" 'cp -R /opt/arthas/. /tmp/arthas-shared/') >= 2 )) || die "Arthas E2E checks must stage files into shared /tmp"
(( $(occurrences "$CMD_E2E" 'java -jar /tmp/arthas-shared/arthas-boot.jar') >= 2 )) || die "Arthas E2E checks must launch boot jar from shared /tmp"
(( $(occurrences "$LABS_MD" 'cp -R /opt/arthas/. /tmp/arthas-shared/') >= 2 )) || die "LABS.md must teach shared Arthas staging"
need_text "$ROOT/profiles/java-attach.yaml" 'name: shared-tmp' "java attach profile must mount shared /tmp"
need_text "$ROOT/profiles/java-attach.yaml" 'mountPath: /tmp' "java attach profile must mount shared /tmp"

echo "Validation completed"
