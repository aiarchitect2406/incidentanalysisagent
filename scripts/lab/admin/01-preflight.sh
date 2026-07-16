#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# STEP 01 — Preflight: enable APIs, verify credentials, print sanity check.
#
# GEAP pillar: (foundation — not itself a pillar)
# What it creates in the project:
#   * Enables the ~10 APIs the lab depends on (aiplatform, run,
#     modelarmor, agentregistry, artifactregistry, cloudbuild, secretmanager,
#     logging, cloudtrace, iam).
#   * Nothing else — this script is intentionally read-and-enable only.
#
# Why this is a shared/admin step:
#   API enablement is project-wide. Doing it once up front means every engineer's
#   later step just works. Doing it per-engineer serialises 15 people through the
#   same slow gcloud call.
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Preflight" "Enable APIs and verify admin credentials"

require_env GOOGLE_CLOUD_PROJECT
require_cmd gcloud python3

info "Project: ${BOLD}${GOOGLE_CLOUD_PROJECT}${RESET}"
info "Verifying gcloud credentials..."
gcloud auth print-access-token >/dev/null 2>&1 \
  || die "gcloud is not authenticated. Run: gcloud auth login && gcloud auth application-default login"

# Confirm project is set to what we expect
current="$(gcloud config get-value project 2>/dev/null || true)"
if [[ "$current" != "$GOOGLE_CLOUD_PROJECT" ]]; then
  info "Setting active gcloud project to ${GOOGLE_CLOUD_PROJECT} (was: ${current:-unset})"
  gcloud config set project "$GOOGLE_CLOUD_PROJECT" >/dev/null
fi

APIS=(
  aiplatform.googleapis.com        # Scale: Agent Runtime (Vertex AI Agent Engine)
  run.googleapis.com               # Build: MCP gateway Cloud Run service
  modelarmor.googleapis.com        # Govern: prompt-injection / jailbreak screening
  agentregistry.googleapis.com     # Govern: MCP servers + agents registry
  artifactregistry.googleapis.com  # Build: MCP gateway container image
  cloudbuild.googleapis.com        # Build: buildpack image builds
  secretmanager.googleapis.com     # Govern: shared URLs handed to engineers
  logging.googleapis.com           # Optimize: structured tool-call logs
  cloudtrace.googleapis.com        # Optimize: OTel spans
  iam.googleapis.com               # Govern: identity + IAM bindings
)

info "Enabling APIs (this may take a minute if any are new)..."
gcloud services enable "${APIS[@]}" --project="$GOOGLE_CLOUD_PROJECT"
ok "APIs enabled."

info "Verifying enabled state..."
for api in "${APIS[@]}"; do
  if gcloud services list --enabled --project="$GOOGLE_CLOUD_PROJECT" \
       --filter="config.name=${api}" --format='value(config.name)' | grep -q "^${api}$"; then
    ok "  ${api}"
  else
    warn "  ${api} — reported not enabled (may still be propagating)"
  fi
done

ok "Preflight complete. Next: bash scripts/lab/admin/02-mcp-gateway.sh"
