#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# STEP 05 — Deploy YOUR agent to Agent Runtime (Vertex AI Agent Engine).
#
# GEAP pillar: Scale (managed multi-agent runtime + Agent Identity)
# What it creates in the project:
#   * ONE Agent Engine (reasoningEngine) resource named
#     enterprise_skills_support_agent-<LAB_USER_ID>, containing your
#     three sub-agents (triage → remediation → notification).
#   * That's it. This script does NOT touch the shared MCP gateway,
#     Agent Registry entry, Model Armor template, or Skill Registry
#     entry — those were provisioned once by the admin and are pointed
#     to here via env vars (auto-read from Secret Manager).
#
# Why this is a per-engineer step:
#   Each engineer wants their own Agent Engine instance so their sessions
#   and traces are theirs to inspect in the Console. ~90 seconds to deploy.
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Scale" "Deploy YOUR agent to Vertex AI Agent Engine"

require_env GOOGLE_CLOUD_PROJECT LAB_USER_ID
require_cmd gcloud python3

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-global}"
AGENT_ENGINE_LOCATION="${AGENT_ENGINE_LOCATION:-us-central1}"

info "Project:              ${GOOGLE_CLOUD_PROJECT}"
info "Your LAB_USER_ID:     ${LAB_USER_ID}"
info "Agent display name:   enterprise_skills_support_agent-${LAB_USER_ID}"
info "Model location:       ${GOOGLE_CLOUD_LOCATION}"
info "Agent Engine region:  ${AGENT_ENGINE_LOCATION}"

# --- Read shared resources from Secret Manager / project ------------
info "Reading shared MCP gateway URL from Secret Manager (${SHARED_MCP_URL_SECRET})..."
MCP_GATEWAY_URL="$(gcloud secrets versions access latest \
  --secret="$SHARED_MCP_URL_SECRET" --project="$GOOGLE_CLOUD_PROJECT" 2>/dev/null || true)"
[[ -n "$MCP_GATEWAY_URL" ]] || die "Secret ${SHARED_MCP_URL_SECRET} not found or empty. Ask the instructor if the shared setup ran (scripts/lab/admin/*)."
info "Using shared MCP gateway: ${MCP_GATEWAY_URL}"

# Every engineer's Agent Engine points at the SAME shared skill and MCP entry.
SKILL_REGISTRY_INCIDENT_SKILL="${SHARED_SKILL_ID}"
MODEL_ARMOR_TEMPLATE="${SHARED_MODEL_ARMOR_TEMPLATE}"

# --- Staging bucket (per-engineer; names are globally unique) -------
PROJECT_NUMBER="$(project_number)"
STAGING_BUCKET_NAME="${SHARED_STAGING_BUCKET_SUFFIX}-${PROJECT_NUMBER}-${LAB_USER_ID}"
if gcloud storage buckets describe "gs://${STAGING_BUCKET_NAME}" --project="$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
  ok "Staging bucket already exists: gs://${STAGING_BUCKET_NAME}"
else
  info "Creating your staging bucket: gs://${STAGING_BUCKET_NAME}"
  gcloud storage buckets create "gs://${STAGING_BUCKET_NAME}" \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --location="$AGENT_ENGINE_LOCATION" \
    --uniform-bucket-level-access >/dev/null
  ok "Bucket created."
fi
AGENT_STAGING_BUCKET="gs://${STAGING_BUCKET_NAME}"

# --- Deploy the agent ------------------------------------------------
info "Deploying agent to Agent Engine (this usually takes 3-5 minutes)..."
export GOOGLE_CLOUD_PROJECT LAB_USER_ID
export GOOGLE_CLOUD_LOCATION="$GOOGLE_CLOUD_LOCATION"
export AGENT_ENGINE_LOCATION="$AGENT_ENGINE_LOCATION"
export AGENT_STAGING_BUCKET
export MCP_GATEWAY_URL
export SKILL_REGISTRY_INCIDENT_SKILL
export MODEL_ARMOR_TEMPLATE
export PYTHONPATH="$REPO_ROOT"

cd "$REPO_ROOT"
python3 "${REPO_ROOT}/scripts/lab/_lib/deploy_agent.py"

ENGINE_ID_FILE="${REPO_ROOT}/.agent_engine_id"
[[ -f "$ENGINE_ID_FILE" ]] || die "Deploy script did not write .agent_engine_id — check output above."
RESOURCE_NAME="$(cat "$ENGINE_ID_FILE")"
RESOURCE_ID="$(basename "$RESOURCE_NAME")"

ok "Agent deployed: ${RESOURCE_NAME}"
console_url "https://console.cloud.google.com/gemini-enterprise/agent-runtime/locations/${AGENT_ENGINE_LOCATION}/reasoning-engines/${RESOURCE_ID}?project=${GOOGLE_CLOUD_PROJECT}"

ok "Deploy complete. Next: bash scripts/lab/engineer/06-verify.sh"
