#!/usr/bin/env bash
# Register the sre-mcp-gateway Cloud Run service in GEAP Agent Registry so
# it appears as a discoverable MCP server (Topology view, Agent Gateway
# egress policies, search_mcp_servers).
#
# Re-run after redeploying the gateway — `services update` keeps the tool
# specification current.
#
# Uses the documented Agent Registry API/CLI (agentregistry.googleapis.com
# via `gcloud agent-registry`), not a hand-rolled REST call — a previous
# version of this script POSTed to a discoveryengine.googleapis.com
# `agentRegistry/mcpServers` path that doesn't correspond to any documented
# Agent Registry endpoint.
#
# Reference: https://docs.cloud.google.com/agent-registry/register-mcp-servers
set -euo pipefail

PROJECT_ID="${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT}"
LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"

# LAB_USER_ID: per-engineer suffix so concurrent enablement-lab runs in one
# shared project don't collide on the same Agent Registry service ID. Must
# match the `lab_user_id` Terraform variable / config.lab_user_id() used for
# the rest of the deploy. Empty = solo/dev run, no suffix.
LAB_USER_ID="${LAB_USER_ID:-}"
if [[ -n "$LAB_USER_ID" ]]; then
  DEFAULT_SERVICE_NAME="sre-mcp-gateway-${LAB_USER_ID}"
else
  DEFAULT_SERVICE_NAME="sre-mcp-gateway"
fi
SERVICE_NAME="${MCP_SERVICE_NAME:-$DEFAULT_SERVICE_NAME}"
TOOLSPEC="${TOOLSPEC_PATH:-$(dirname "$0")/../enterprise_support_agent/toolspec.json}"

if [[ ! -f "$TOOLSPEC" ]]; then
  echo "Tool spec not found at $TOOLSPEC (set TOOLSPEC_PATH to override)" >&2
  exit 1
fi

GATEWAY_URL="$(gcloud run services describe "$SERVICE_NAME" \
  --region "$LOCATION" --format='value(status.url)' --project "$PROJECT_ID")"

if [[ -z "$GATEWAY_URL" ]]; then
  echo "Could not resolve Cloud Run URL for $SERVICE_NAME in $LOCATION" >&2
  exit 1
fi

echo "Registering ${SERVICE_NAME} -> ${GATEWAY_URL}/mcp in Agent Registry (project=${PROJECT_ID}, location=${LOCATION})..."

if gcloud agent-registry services describe "$SERVICE_NAME" \
    --project="$PROJECT_ID" --location="$LOCATION" >/dev/null 2>&1; then
  gcloud agent-registry services update "$SERVICE_NAME" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --mcp-server-spec-content="$TOOLSPEC"
  echo "Updated existing Agent Registry service entry."
else
  gcloud agent-registry services create "$SERVICE_NAME" \
    --project="$PROJECT_ID" \
    --location="$LOCATION" \
    --display-name="$SERVICE_NAME" \
    --mcp-server-spec-type=tool-spec \
    --mcp-server-spec-content="$TOOLSPEC" \
    --interfaces="url=${GATEWAY_URL}/mcp,protocolBinding=JSONRPC"
  echo "Created new Agent Registry service entry."
fi

echo
echo "Verify:"
echo "  gcloud agent-registry mcp-servers list --project=${PROJECT_ID} --location=${LOCATION}"
echo "  Console: https://console.cloud.google.com/gemini-enterprise/agent-registry/mcp-servers?project=${PROJECT_ID}"
echo
echo "Next (Govern pillar, network-layer Model Armor + least-privilege egress):"
echo "  see docs/agent-gateway-setup.md to front this server with an Agent Gateway"
echo "  egress and grant the agent's identity roles/iap.egressor on it."
