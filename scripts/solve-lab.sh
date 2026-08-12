#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
require_dojo_context

num="${1:-}"
[[ -n "$num" ]] || { echo "Usage: $0 <lab-number-or-prefix>" >&2; exit 2; }
lab="$(find_lab "$ROOT" "$num")"
kubectl --context "$DOJO_CONTEXT" apply -f "$lab/fixed.yaml"
echo "Applied reference repair for $(basename "$lab")"
