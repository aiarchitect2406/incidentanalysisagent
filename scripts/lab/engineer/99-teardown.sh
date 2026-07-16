#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# TEARDOWN (yours) — delete YOUR Agent Engine instance and staging bucket.
# Leaves all shared workshop infrastructure alone. Safe by construction:
# this script cannot touch anything the admin created.
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Teardown" "Delete YOUR agent (leaves shared infra alone)"

require_env GOOGLE_CLOUD_PROJECT LAB_USER_ID

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
AGENT_ENGINE_LOCATION="${AGENT_ENGINE_LOCATION:-us-central1}"
ENGINE_ID_FILE="${REPO_ROOT}/.agent_engine_id"

if [[ -f "$ENGINE_ID_FILE" ]]; then
  RESOURCE_NAME="$(cat "$ENGINE_ID_FILE")"
  info "Deleting Agent Engine: ${RESOURCE_NAME}"
  python3 - <<PY 2>&1 || warn "Delete failed — the instance may already be gone."
import vertexai
from vertexai import agent_engines
vertexai.init(project="${GOOGLE_CLOUD_PROJECT}", location="${AGENT_ENGINE_LOCATION}")
agent_engines.get("${RESOURCE_NAME}").delete()
print("deleted")
PY
  rm -f "$ENGINE_ID_FILE" "${REPO_ROOT}/.agent_identity"
  ok "Deleted Agent Engine + local state files."
else
  warn "No .agent_engine_id found — nothing to delete."
fi

# Also delete this engineer's staging bucket.
PROJECT_NUMBER="$(project_number)"
STAGING_BUCKET_NAME="${SHARED_STAGING_BUCKET_SUFFIX}-${PROJECT_NUMBER}-${LAB_USER_ID}"
if gcloud storage buckets describe "gs://${STAGING_BUCKET_NAME}" --project="$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
  info "Deleting staging bucket gs://${STAGING_BUCKET_NAME}..."
  gcloud storage rm -r "gs://${STAGING_BUCKET_NAME}" --project="$GOOGLE_CLOUD_PROJECT" --quiet
  ok "Bucket deleted."
else
  info "Staging bucket already gone."
fi

ok "Your teardown complete. Shared infra untouched."
