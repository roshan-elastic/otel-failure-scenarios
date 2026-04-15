#!/usr/bin/env bash
# teardown.sh — Destroy the oteldemo oblt cluster.
#
# Usage:
#   ./scripts/teardown.sh <cluster-name>

set -euo pipefail

CLUSTER_NAME="${1:-}"

if [[ -z "$CLUSTER_NAME" ]]; then
  echo "Usage: $0 <cluster-name>"
  echo "Find your cluster name with: oblt-cli cluster list"
  exit 1
fi

echo "About to destroy cluster: ${CLUSTER_NAME}"
read -r -p "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

oblt-cli cluster destroy --cluster-name="${CLUSTER_NAME}"
