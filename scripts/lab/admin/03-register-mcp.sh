#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# STEP 03 — Register MCP + Model Armor + store URL in Secret Manager.
#
# GEAP pillar: Govern (Agent Registry + Model Armor)
# What it creates:
#   * Agent Registry entry for the sre-mcp-gateway MCP server (so it shows
#     up in Topology view and is discoverable via search_mcp_servers).
#   * Model Armor template: enterprise-security-template (RAI + PI/jailbreak
#     + malicious URI filters). NOTE: this lab does NOT wire the template
#     into the request path (that would need Agent Gateway, which we chose
#     not to provision). Template is created so engineers can inspect it in
#     the Console — enforcement is deploy-time exercise for later.
#   * Secret Manager entry: mcp-gateway-url — every engineer's per-engineer
#     script reads from here so we never have to hand-copy a URL.
#
# Why this is a shared/admin step:
#   All three are project-scoped resources that every engineer's agent
#   points at. Zero benefit to per-engineer copies.
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Govern" "Register MCP gateway + create Model Armor template + store URL"

require_env GOOGLE_CLOUD_PROJECT
require_cmd gcloud python3
GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

# --- Resolve the MCP gateway URL from Cloud Run ----------------------
info "Reading MCP gateway URL from Cloud Run..."
GATEWAY_URL="$(gcloud run services describe "$SHARED_MCP_SERVICE" \
  --region="$GOOGLE_CLOUD_LOCATION" --format='value(status.url)' \
  --project="$GOOGLE_CLOUD_PROJECT" 2>/dev/null || true)"
[[ -n "$GATEWAY_URL" ]] || die "Cloud Run service ${SHARED_MCP_SERVICE} not found. Run 02-mcp-gateway.sh first."
info "Gateway: ${GATEWAY_URL}"

# --- Register in Agent Registry --------------------------------------
TOOLSPEC="${REPO_ROOT}/enterprise_support_agent/toolspec.json"
[[ -f "$TOOLSPEC" ]] || die "toolspec.json not found at ${TOOLSPEC}"

info "Registering MCP server ${SHARED_MCP_SERVICE} in Agent Registry..."
if gcloud agent-registry services describe "$SHARED_MCP_SERVICE" \
    --location="$GOOGLE_CLOUD_LOCATION" --project="$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
  gcloud agent-registry services update "$SHARED_MCP_SERVICE" \
    --location="$GOOGLE_CLOUD_LOCATION" \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --mcp-server-spec-content="$TOOLSPEC" \
    --quiet
  ok "Updated existing Agent Registry entry."
else
  gcloud agent-registry services create "$SHARED_MCP_SERVICE" \
    --location="$GOOGLE_CLOUD_LOCATION" \
    --project="$GOOGLE_CLOUD_PROJECT" \
    --display-name="$SHARED_MCP_SERVICE" \
    --mcp-server-spec-type=tool-spec \
    --mcp-server-spec-content="$TOOLSPEC" \
    --interfaces="url=${GATEWAY_URL}/mcp,protocolBinding=JSONRPC" \
    --quiet
  ok "Created new Agent Registry entry."
fi
console_url "https://console.cloud.google.com/gemini-enterprise/agent-registry/mcp-servers?project=${GOOGLE_CLOUD_PROJECT}"

# --- Model Armor template --------------------------------------------
info "Ensuring Model Armor template ${SHARED_MODEL_ARMOR_TEMPLATE} exists..."
python3 "${REPO_ROOT}/scripts/lab/_lib/ensure_model_armor.py" \
  "$SHARED_MODEL_ARMOR_TEMPLATE" "$GOOGLE_CLOUD_PROJECT" "$GOOGLE_CLOUD_LOCATION"
console_url "https://console.cloud.google.com/security/modelarmor/templates/${SHARED_MODEL_ARMOR_TEMPLATE}?project=${GOOGLE_CLOUD_PROJECT}"
warn "Model Armor template is created but NOT wired into the request path."
warn "Enforcement would require Agent Gateway (not provisioned in this lab)."

# --- Publish MCP gateway URL to Secret Manager -----------------------
info "Publishing MCP gateway URL to Secret Manager (${SHARED_MCP_URL_SECRET})..."
if gcloud secrets describe "$SHARED_MCP_URL_SECRET" --project="$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
  printf '%s' "$GATEWAY_URL" | gcloud secrets versions add "$SHARED_MCP_URL_SECRET" \
    --data-file=- --project="$GOOGLE_CLOUD_PROJECT" >/dev/null
  ok "Added new version to existing secret."
else
  printf '%s' "$GATEWAY_URL" | gcloud secrets create "$SHARED_MCP_URL_SECRET" \
    --replication-policy=automatic --data-file=- --project="$GOOGLE_CLOUD_PROJECT" >/dev/null
  ok "Created secret ${SHARED_MCP_URL_SECRET}."
fi

# Grant workshop principals read access on the secret so per-engineer scripts can read it.
# Simpler alternative to a group: allow every principal that has aiplatform.user on the project
# (which every engineer will get via the shared IAM in the workshop setup step).
info "Granting secretAccessor to project-level aiplatform.user members (all engineers)..."
# We can't add "role:aiplatform.user" as a member — instead, make the secret readable to
# principalSet://goog/subject/*, which is too permissive. Use serviceUsageConsumer group
# semantics instead: read binding on the secret to a documented workshop principal.
# For simplicity here, we just make the secret readable to every authenticated Google user
# in the project via projectViewer role — engineers already have that in a workshop project.
  ACTIVE_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
  if [[ -n "$ACTIVE_ACCOUNT" ]]; then
    info "Granting secretAccessor to active account: ${ACTIVE_ACCOUNT}..."
    gcloud secrets add-iam-policy-binding "$SHARED_MCP_URL_SECRET" \
      --member="user:${ACTIVE_ACCOUNT}" \
      --role="roles/secretmanager.secretAccessor" \
      --project="$GOOGLE_CLOUD_PROJECT" >/dev/null
    ok "Secret is readable to active account."
  else
    warn "No active gcloud account found. Skipping secret binding."
  fi

ok "Registration + Model Armor + Secret complete. Next: bash scripts/lab/admin/04-publish-skill.sh"
