#!/usr/bin/env bash
# toggle-flag.sh — Enable or disable a flagd feature flag by patching the
# Kubernetes ConfigMap and restarting the flagd deployment.
#
# Usage:
#   ./scripts/toggle-flag.sh <flag-name> <on|off> [namespace] [release-name]
#
# Examples:
#   ./scripts/toggle-flag.sh paymentFailure on
#   ./scripts/toggle-flag.sh cartFailure on otel-demo my-otel-demo
#   ./scripts/toggle-flag.sh paymentFailure off
#
# Available flags:
#   adFailure                  adManualGc                adHighCpu
#   cartFailure                emailMemoryLeak           failedReadinessProbe
#   imageSlowLoad              kafkaQueueProblems        llmInaccurateResponse
#   llmRateLimitError          loadGeneratorFloodHomepage paymentFailure
#   paymentUnreachable         productCatalogFailure     recommendationCacheFailure
#
# Notes:
#   - For flags with multiple variants (e.g. paymentFailure, emailMemoryLeak,
#     imageSlowLoad), 'on' sets defaultVariant to the first non-'off' variant.
#     To set a specific variant, use --variant:
#       ./scripts/toggle-flag.sh paymentFailure on --variant="50%"
#       ./scripts/toggle-flag.sh emailMemoryLeak on --variant="100x"
#       ./scripts/toggle-flag.sh imageSlowLoad on --variant="5sec"
#
#   - A flagd pod restart is required because flagd copies its ConfigMap to a
#     local read-write volume on startup and does not watch for later changes.
#     See: https://github.com/open-telemetry/opentelemetry-demo/issues/1953

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# ── Argument parsing ───────────────────────────────────────────────────────────
FLAG_NAME="${1:-}"
STATE="${2:-}"
NAMESPACE="${3:-$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo 'default')}"
RELEASE_NAME="${4:-}"
VARIANT_OVERRIDE=""

# Parse optional --variant flag from remaining args
shift 4 2>/dev/null || true
for arg in "$@"; do
  case "$arg" in
    --variant=*) VARIANT_OVERRIDE="${arg#*=}" ;;
    *) ;;
  esac
done

if [[ -z "$FLAG_NAME" || -z "$STATE" ]]; then
  echo "Usage: $0 <flag-name> <on|off> [namespace] [release-name] [--variant=<variant>]"
  echo ""
  echo "Examples:"
  echo "  $0 paymentFailure on"
  echo "  $0 paymentFailure on otel-demo my-otel-demo --variant='50%'"
  echo "  $0 cartFailure off"
  exit 1
fi

if [[ "$STATE" != "on" && "$STATE" != "off" ]]; then
  die "State must be 'on' or 'off', got: '$STATE'"
fi

CONFIGMAP_NAME="${RELEASE_NAME:+${RELEASE_NAME}-}flagd-config"
DEPLOYMENT_NAME="${RELEASE_NAME:+${RELEASE_NAME}-}flagd"

# ── Prerequisite checks ────────────────────────────────────────────────────────
for cmd in kubectl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    die "'$cmd' is not installed or not in PATH."
  fi
done

# ── Find flagd pod ─────────────────────────────────────────────────────────────
FLAGD_POD=$(kubectl get po -l app.kubernetes.io/component=flagd \
  -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$FLAGD_POD" ]]; then
  die "flagd pod not found in namespace '$NAMESPACE'. Is the cluster accessible?"
fi

# ── Read live flag state from the pod (source of truth) ───────────────────────
info "Reading live flag config from pod '$FLAGD_POD'..."
CURRENT_JSON=$(kubectl exec "$FLAGD_POD" -c flagd-ui -n "$NAMESPACE" -- \
  cat /app/data/demo.flagd.json)

# Verify the flag exists
if ! echo "$CURRENT_JSON" | jq -e ".flags[\"${FLAG_NAME}\"]" &>/dev/null; then
  echo ""
  error "Flag '$FLAG_NAME' not found."
  echo ""
  echo "Available flags:"
  echo "$CURRENT_JSON" | jq -r '.flags | keys[]' | sort | sed 's/^/  /'
  echo ""
  exit 1
fi

# ── Determine the target variant ───────────────────────────────────────────────
if [[ "$STATE" == "off" ]]; then
  TARGET_VARIANT="off"
elif [[ -n "$VARIANT_OVERRIDE" ]]; then
  if ! echo "$CURRENT_JSON" | jq -e ".flags[\"${FLAG_NAME}\"].variants[\"${VARIANT_OVERRIDE}\"]" &>/dev/null; then
    echo ""
    error "Variant '$VARIANT_OVERRIDE' does not exist for flag '$FLAG_NAME'."
    echo ""
    echo "Available variants:"
    echo "$CURRENT_JSON" | jq -r ".flags[\"${FLAG_NAME}\"].variants | keys[]" | sed 's/^/  /'
    echo ""
    exit 1
  fi
  TARGET_VARIANT="$VARIANT_OVERRIDE"
else
  TARGET_VARIANT=$(echo "$CURRENT_JSON" | \
    jq -r ".flags[\"${FLAG_NAME}\"].variants | keys[] | select(. != \"off\")" | head -1)
  if [[ -z "$TARGET_VARIANT" ]]; then
    TARGET_VARIANT="on"
  fi
fi

CURRENT_VARIANT=$(echo "$CURRENT_JSON" | jq -r ".flags[\"${FLAG_NAME}\"].defaultVariant")
info "Flag: ${FLAG_NAME}"
info "Current variant: ${CURRENT_VARIANT}"
info "Target variant:  ${TARGET_VARIANT}"

if [[ "$CURRENT_VARIANT" == "$TARGET_VARIANT" ]]; then
  warn "Flag '$FLAG_NAME' is already set to '$TARGET_VARIANT' — no change needed."
  exit 0
fi

# ── Update the JSON ────────────────────────────────────────────────────────────
UPDATED_JSON=$(echo "$CURRENT_JSON" | \
  jq ".flags[\"${FLAG_NAME}\"].defaultVariant = \"${TARGET_VARIANT}\"")

# ── Sync updated JSON back to the ConfigMap (preserves all live flag state) ────
info "Syncing live config back to ConfigMap '$CONFIGMAP_NAME'..."
PATCH_PAYLOAD=$(jq -n \
  --arg json "$UPDATED_JSON" \
  '{"data": {"demo.flagd.json": $json}}')

kubectl patch configmap "$CONFIGMAP_NAME" \
  -n "$NAMESPACE" \
  --type merge \
  --patch "$PATCH_PAYLOAD"

success "ConfigMap updated"

# ── Restart flagd to pick up the new ConfigMap ─────────────────────────────────
info "Restarting flagd deployment '$DEPLOYMENT_NAME'..."
kubectl rollout restart deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE"

info "Waiting for rollout to complete..."
kubectl rollout status deployment/"$DEPLOYMENT_NAME" -n "$NAMESPACE" --timeout=120s

success "flagd restarted successfully"
echo ""
echo -e "${GREEN}✓ Flag '${FLAG_NAME}' is now set to '${TARGET_VARIANT}'${NC}"
echo ""

if [[ "$STATE" == "on" ]]; then
  echo -e "  Watch for effects in Kibana → Observability → APM"
fi
