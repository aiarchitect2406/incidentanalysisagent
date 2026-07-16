#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# TEARDOWN (shared) — remove everything scripts/lab/admin/0*.sh created.
#
# WARNING: this deletes resources that ALL engineers depend on. Only run this
# AFTER every engineer has run scripts/lab/engineer/99-teardown.sh.
# Their Agent Engine instances still work briefly after this runs, but will
# start failing on the next MCP tool call (gateway is gone).
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Teardown" "Delete shared workshop infrastructure"

require_env GOOGLE_CLOUD_PROJECT
require_cmd gcloud
GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"

warn "This will delete: Cloud Run service, Agent Registry entry, Model Armor template,"
warn "Skill Registry entry, Secret Manager secret, Artifact Registry repo."
warn "Every engineer's still-running Agent Engine will start failing on MCP calls."
printf '%sType YES to proceed: %s' "$YELLOW" "$RESET"
read -r confirm
[[ "$confirm" == "YES" ]] || die "Cancelled."

# --- Cloud Run ------------------------------------------------------
info "Deleting Cloud Run service ${SHARED_MCP_SERVICE}..."
gcloud run services delete "$SHARED_MCP_SERVICE" \
  --region="$GOOGLE_CLOUD_LOCATION" --project="$GOOGLE_CLOUD_PROJECT" --quiet 2>/dev/null \
  && ok "Deleted." || warn "Cloud Run service not present (or already deleted)."

# --- Agent Registry -------------------------------------------------
info "Deleting Agent Registry entry ${SHARED_MCP_SERVICE}..."
gcloud agent-registry services delete "$SHARED_MCP_SERVICE" \
  --location="$GOOGLE_CLOUD_LOCATION" --project="$GOOGLE_CLOUD_PROJECT" --quiet 2>/dev/null \
  && ok "Deleted." || warn "Agent Registry entry not present."

# --- Model Armor ----------------------------------------------------
info "Deleting Model Armor template ${SHARED_MODEL_ARMOR_TEMPLATE}..."
python3 - <<PY 2>/dev/null || warn "Model Armor template not present."
from google.api_core.client_options import ClientOptions
from google.cloud import modelarmor_v1
c = modelarmor_v1.ModelArmorClient(client_options=ClientOptions(
    api_endpoint="modelarmor.${GOOGLE_CLOUD_LOCATION}.rep.googleapis.com"))
c.delete_template(name="projects/${GOOGLE_CLOUD_PROJECT}/locations/${GOOGLE_CLOUD_LOCATION}/templates/${SHARED_MODEL_ARMOR_TEMPLATE}")
print("deleted")
PY
ok "Model Armor cleanup attempted."

# --- Skill Registry -------------------------------------------------
info "Deleting Skill Registry entry ${SHARED_SKILL_ID}..."
python3 - <<PY 2>/dev/null || warn "Skill not present."
import vertexai
c = vertexai.Client(project="${GOOGLE_CLOUD_PROJECT}", location="us-central1",
                     http_options={"api_version":"v1beta1"})
c.skills.delete(name="projects/${GOOGLE_CLOUD_PROJECT}/locations/us-central1/skills/${SHARED_SKILL_ID}")
print("deleted")
PY
ok "Skill cleanup attempted."

# --- Secret Manager -------------------------------------------------
info "Deleting Secret Manager secret ${SHARED_MCP_URL_SECRET}..."
gcloud secrets delete "$SHARED_MCP_URL_SECRET" \
  --project="$GOOGLE_CLOUD_PROJECT" --quiet 2>/dev/null \
  && ok "Deleted." || warn "Secret not present."

# --- Artifact Registry ----------------------------------------------
info "Deleting Artifact Registry repo ${SHARED_ARTIFACT_REPO}..."
gcloud artifacts repositories delete "$SHARED_ARTIFACT_REPO" \
  --location="$GOOGLE_CLOUD_LOCATION" --project="$GOOGLE_CLOUD_PROJECT" --quiet 2>/dev/null \
  && ok "Deleted." || warn "Artifact repo not present."

ok "Shared teardown complete."
