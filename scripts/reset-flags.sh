#!/usr/bin/env bash
# reset-flags.sh — Turn off all flagd feature flags.
# Reads the live flag config from the flagd pod, sets every flag's
# defaultVariant to "off", syncs back to the ConfigMap, then restarts flagd.
#
# Run this after cluster creation to start from a clean baseline.
#
# Usage:
#   ./scripts/reset-flags.sh

set -euo pipefail

NAMESPACE="${NAMESPACE:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo 'default')}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Find flagd pod ─────────────────────────────────────────────────────────────
FLAGD_POD=$(kubectl get po -l app.kubernetes.io/component=flagd \
  -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -z "$FLAGD_POD" ]] && die "flagd pod not found. Is kubectl configured correctly?"

# ── Read live config and set all flags to off ──────────────────────────────────
info "Reading live flag config from pod '$FLAGD_POD'..."
CURRENT_JSON=$(kubectl exec "$FLAGD_POD" -c flagd-ui -n "$NAMESPACE" -- \
  cat /app/data/demo.flagd.json)

RESET_JSON=$(echo "$CURRENT_JSON" | jq '
  .flags |= with_entries(.value.defaultVariant = "off")
')

# Show what will be turned off
ACTIVE=$(echo "$CURRENT_JSON" | jq -r '
  .flags | to_entries[]
  | select(.value.defaultVariant != "off")
  | "  \(.key): \(.value.defaultVariant)"
')

if [[ -z "$ACTIVE" ]]; then
  success "All flags are already off — nothing to do."
  exit 0
fi

echo ""
echo "The following flags will be turned off:"
echo "$ACTIVE"
echo ""
read -r -p "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ── Patch ConfigMap ────────────────────────────────────────────────────────────
CONFIGMAP_NAME="flagd-config"
info "Patching ConfigMap '$CONFIGMAP_NAME'..."
PATCH_PAYLOAD=$(jq -n --arg json "$RESET_JSON" '{"data": {"demo.flagd.json": $json}}')
kubectl patch configmap "$CONFIGMAP_NAME" -n "$NAMESPACE" --type merge --patch "$PATCH_PAYLOAD"
success "ConfigMap updated"

# ── Restart flagd ──────────────────────────────────────────────────────────────
info "Restarting flagd..."
kubectl rollout restart deployment/flagd -n "$NAMESPACE"
kubectl rollout status deployment/flagd -n "$NAMESPACE" --timeout=120s

success "All flags reset to off"
echo ""
echo -e "  Verify with: ${CYAN}./scripts/list-flags.sh${NC}"
echo ""
