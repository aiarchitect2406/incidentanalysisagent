#!/usr/bin/env bash
# Print the exact Google Cloud Console URLs the L400 demo walks through.
# Copy/paste each URL into a browser tab BEFORE the demo so tab-switching
# is instant during the live walk-through.
set -euo pipefail

PROJECT_ID="${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT}"
LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
MCP_SERVICE_NAME="${MCP_SERVICE_NAME:-sre-mcp-gateway}"
MODEL_ARMOR_TEMPLATE="${MODEL_ARMOR_TEMPLATE:-enterprise-security-template}"

resource_id=""
if [[ -f .agent_engine_id ]]; then
  resource_id="$(cut -d/ -f6 < .agent_engine_id)"
fi

q() { python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))' "$1"; }

header() { printf '\n\033[1m[ %s ]\033[0m\n' "$1"; }
url() { printf '  %-26s %s\n' "$1" "$2"; }

header "Build"
url "Skill Registry" \
  "https://console.cloud.google.com/gemini-enterprise/skill-registry?project=${PROJECT_ID}"
url "Agent Registry (MCP)" \
  "https://console.cloud.google.com/gemini-enterprise/agent-registry/mcp-servers?project=${PROJECT_ID}"

header "Scale"
if [[ -n "$resource_id" ]]; then
  url "Agent Runtime (this agent)" \
    "https://console.cloud.google.com/gemini-enterprise/agent-runtime/locations/${LOCATION}/reasoning-engines/${resource_id}?project=${PROJECT_ID}"
else
  url "Agent Runtime" \
    "https://console.cloud.google.com/gemini-enterprise/agent-runtime?project=${PROJECT_ID}"
fi
url "Sessions" \
  "https://console.cloud.google.com/gemini-enterprise/sessions?project=${PROJECT_ID}"
url "Memory Bank" \
  "https://console.cloud.google.com/gemini-enterprise/memory-bank?project=${PROJECT_ID}"

header "Govern"
url "Agent Identity" \
  "https://console.cloud.google.com/gemini-enterprise/agent-identity?project=${PROJECT_ID}"
url "Model Armor template" \
  "https://console.cloud.google.com/security/modelarmor/templates/${MODEL_ARMOR_TEMPLATE}?project=${PROJECT_ID}"
url "Cloud Run service auth" \
  "https://console.cloud.google.com/run/detail/${LOCATION}/${MCP_SERVICE_NAME}/security?project=${PROJECT_ID}"

header "Optimize"
if [[ -n "$resource_id" ]]; then
  url "Observability Overview" \
    "https://console.cloud.google.com/gemini-enterprise/agent-registry/agents/${resource_id}/observability?project=${PROJECT_ID}"
  url "Traces" \
    "https://console.cloud.google.com/gemini-enterprise/agent-registry/agents/${resource_id}/traces?project=${PROJECT_ID}"
  url "Topology" \
    "https://console.cloud.google.com/gemini-enterprise/agent-registry/agents/${resource_id}/topology?project=${PROJECT_ID}"
fi
url "Cloud Logging (Model Armor)" \
  "https://console.cloud.google.com/logs/query;query=$(q 'jsonPayload.event=~"model_armor_.*"')?project=${PROJECT_ID}"
url "Cloud Logging (tool calls)" \
  "https://console.cloud.google.com/logs/query;query=$(q 'jsonPayload.event="tool_invoked"')?project=${PROJECT_ID}"

echo
echo "Tip: 'bash console_checklist.sh | awk \"/https/{print \\\$NF}\" | xargs -n1 open' opens all tabs (macOS)."
