#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
# Deleting the cluster removes its kubectl context. Restore whatever was current before up.sh
# switched to the dojo, but never clobber a context the learner picked deliberately after that.
if k3d cluster get "$CLUSTER" >/dev/null 2>&1; then
  k3d cluster delete "$CLUSTER"
else
  echo "Cluster '$CLUSTER' does not exist; nothing to delete."
fi
restore_previous_context
