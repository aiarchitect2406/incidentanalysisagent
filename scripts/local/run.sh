#!/usr/bin/env bash
# Run the enterprise support agent fully locally: MCP gateway on localhost,
# `adk api_server` for the agent, in-memory session/memory services. No
# Cloud Run, Secret Manager, Skill Registry, or Agent Engine dependency —
# use this to get the agent working end to end BEFORE deploying anything.
#
# Requires GOOGLE_CLOUD_PROJECT (still needed for direct Gemini/Model Armor
# calls) and the root requirements.txt + enterprise_support_agent/requirements.txt
# installed in the active Python environment.
set -euo pipefail

PROJECT_ID="${GOOGLE_CLOUD_PROJECT:?Set GOOGLE_CLOUD_PROJECT}"
MCP_PORT="${MCP_PORT:-8080}"
AGENT_PORT="${AGENT_PORT:-8000}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"
export GOOGLE_GENAI_USE_VERTEXAI=TRUE
export GOOGLE_CLOUD_LOCATION=global
export MCP_GATEWAY_URL="http://127.0.0.1:${MCP_PORT}"
export MCP_GATEWAY_REQUIRES_AUTH=false

echo "Starting local MCP gateway on :${MCP_PORT} ..."
PORT="$MCP_PORT" python3 "${REPO_ROOT}/enterprise_support_agent/mcp_server.py" &
MCP_PID=$!
trap 'echo "Stopping local MCP gateway (pid ${MCP_PID})"; kill "${MCP_PID}" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  if curl -s -o /dev/null "http://127.0.0.1:${MCP_PORT}/mcp"; then
    break
  fi
  if ! kill -0 "$MCP_PID" 2>/dev/null; then
    echo "MCP gateway process died before it started listening — check the output above." >&2
    exit 1
  fi
  sleep 0.5
done
echo "MCP gateway is up: ${MCP_GATEWAY_URL}"

echo "Starting adk api_server on :${AGENT_PORT} (in-memory sessions) ..."
cd "$REPO_ROOT"
adk api_server \
  --session_service_uri="memory://" \
  --port "$AGENT_PORT" \
  .
