#!/usr/bin/env bash
# list-flags.sh — Show the live state of all flagd feature flags.
# Reads directly from the flagd-ui container's live config file,
# which is the true source of truth for the running state.
#
# Usage:
#   ./scripts/list-flags.sh [--active-only]
#
# Options:
#   --active-only   Only show flags that are currently active (not 'off')

set -euo pipefail

ACTIVE_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --active-only) ACTIVE_ONLY=true ;;
  esac
done

FLAGD_POD=$(kubectl get po -l app.kubernetes.io/component=flagd \
  -o jsonpath='{.items[0].metadata.name}')

if [[ -z "$FLAGD_POD" ]]; then
  echo "Error: flagd pod not found. Is the cluster accessible?"
  exit 1
fi

JSON=$(kubectl exec "$FLAGD_POD" -c flagd-ui -- \
  cat /app/data/demo.flagd.json)

echo ""
printf "  %-35s %s\n" "FLAG" "STATE"
printf "  %-35s %s\n" "----" "-----"

echo "$JSON" | jq -r '
  .flags | to_entries[]
  | "\(.key) \(.value.defaultVariant)"
' | sort | while read -r flag variant; do
  if [[ "$ACTIVE_ONLY" == "true" && "$variant" == "off" ]]; then
    continue
  fi
  if [[ "$variant" != "off" ]]; then
    printf "  %-35s \033[0;32m%s\033[0m\n" "$flag" "$variant"
  else
    printf "  %-35s %s\n" "$flag" "$variant"
  fi
done

echo ""
