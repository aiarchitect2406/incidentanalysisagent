#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# STEP 06 — Verify: hit your deployed agent with Scenario A + Scenario B.
#
# GEAP pillar: Optimize (traces + logs prove the flow worked)
# What it does:
#   * Reads .agent_engine_id from step 05.
#   * Runs the smoke test against your deployed Agent Engine — Scenario A
#     (autonomous remediation of INC-101) + Scenario B (INC-666 prompt-
#     injection ticket).
#   * Prints links to Cloud Trace + your agent's Observability tab so you
#     can see the tool sequence you just triggered.
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Optimize" "Verify your deployed agent (Scenario A + B smoke)"

require_env GOOGLE_CLOUD_PROJECT LAB_USER_ID
require_cmd python3

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ENGINE_ID_FILE="${REPO_ROOT}/.agent_engine_id"
[[ -f "$ENGINE_ID_FILE" ]] || die ".agent_engine_id not found — run scripts/lab/engineer/05-deploy-agent.sh first."
RESOURCE_NAME="$(cat "$ENGINE_ID_FILE")"
RESOURCE_ID="$(basename "$RESOURCE_NAME")"

info "Target agent: ${RESOURCE_NAME}"
info "Running smoke tests (Scenario A + B)..."

export PYTHONPATH="$REPO_ROOT"
cd "$REPO_ROOT"
python3 "${REPO_ROOT}/tests/smoke_test.py"

AGENT_ENGINE_LOCATION="${AGENT_ENGINE_LOCATION:-us-central1}"
console_url "https://console.cloud.google.com/gemini-enterprise/agent-registry/agents/${RESOURCE_ID}/observability?project=${GOOGLE_CLOUD_PROJECT}"
console_url "https://console.cloud.google.com/gemini-enterprise/agent-registry/agents/${RESOURCE_ID}/traces?project=${GOOGLE_CLOUD_PROJECT}"

ok "Verify complete. To interact with your agent in a browser: make lab-web"
