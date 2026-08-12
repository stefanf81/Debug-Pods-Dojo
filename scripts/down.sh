#!/usr/bin/env bash
set -euo pipefail
CLUSTER="${CLUSTER:-debug-pods-dojo}"
k3d cluster delete "$CLUSTER"
