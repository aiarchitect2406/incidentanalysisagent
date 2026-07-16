#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# STEP 02 — MCP Gateway: build image + deploy to Cloud Run (IAM-gated).
#
# GEAP pillar: Build (tools live behind an MCP server)
# What it creates:
#   * Artifact Registry repo: enterprise-support-agent
#   * Docker image built via Cloud Build (buildpacks — no Dockerfile needed)
#   * Cloud Run v2 service: sre-mcp-gateway (private, --no-allow-unauthenticated)
#   * Grants roles/run.invoker to the workshop-participants group so every
#     engineer's Agent Engine identity can call the gateway.
#
# Why this is a shared/admin step:
#   The MCP server is stateless mocked backends — 1 gateway serves everyone.
#   Splitting per-engineer would mean 15 concurrent Cloud Build jobs building
#   byte-identical images. Wasteful and slow.
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Build" "Deploy the shared MCP gateway to Cloud Run"

require_env GOOGLE_CLOUD_PROJECT
require_cmd gcloud
GOOGLE_CLOUD_LOCATION="${GOOGLE_CLOUD_LOCATION:-us-central1}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
IMAGE_URI="${GOOGLE_CLOUD_LOCATION}-docker.pkg.dev/${GOOGLE_CLOUD_PROJECT}/${SHARED_ARTIFACT_REPO}/sre-mcp-gateway:latest"

info "Project:  ${GOOGLE_CLOUD_PROJECT}"
info "Region:   ${GOOGLE_CLOUD_LOCATION}"
info "Service:  ${SHARED_MCP_SERVICE}"
info "Image:    ${IMAGE_URI}"

# --- Artifact Registry repo ------------------------------------------
if gcloud artifacts repositories describe "$SHARED_ARTIFACT_REPO" \
     --location="$GOOGLE_CLOUD_LOCATION" --project="$GOOGLE_CLOUD_PROJECT" >/dev/null 2>&1; then
  ok "Artifact Registry repo already exists: ${SHARED_ARTIFACT_REPO}"
else
  info "Creating Artifact Registry repo ${SHARED_ARTIFACT_REPO}..."
  gcloud artifacts repositories create "$SHARED_ARTIFACT_REPO" \
    --repository-format=docker \
    --location="$GOOGLE_CLOUD_LOCATION" \
    --description="MCP gateway container images for the enterprise support agent lab" \
    --project="$GOOGLE_CLOUD_PROJECT"
  ok "Artifact Registry repo created."
fi

# --- Build the image via Cloud Build (buildpacks — Procfile-based) ---
info "Building container image via Cloud Build (buildpacks) — this typically takes 2-4 minutes..."
gcloud builds submit "${REPO_ROOT}/enterprise_support_agent" \
  --pack "image=${IMAGE_URI}" \
  --project="$GOOGLE_CLOUD_PROJECT"
ok "Image built and pushed: ${IMAGE_URI}"

# --- Deploy to Cloud Run (IAM-gated by default) ----------------------
info "Deploying Cloud Run service ${SHARED_MCP_SERVICE}..."
gcloud run deploy "$SHARED_MCP_SERVICE" \
  --image="$IMAGE_URI" \
  --region="$GOOGLE_CLOUD_LOCATION" \
  --project="$GOOGLE_CLOUD_PROJECT" \
  --no-allow-unauthenticated \
  --set-env-vars="GOOGLE_CLOUD_PROJECT=${GOOGLE_CLOUD_PROJECT},GOOGLE_CLOUD_LOCATION=${GOOGLE_CLOUD_LOCATION}" \
  --quiet

GATEWAY_URL="$(gcloud run services describe "$SHARED_MCP_SERVICE" \
  --region="$GOOGLE_CLOUD_LOCATION" --format='value(status.url)' --project="$GOOGLE_CLOUD_PROJECT")"
ok "MCP gateway deployed: ${GATEWAY_URL}"

# --- IAM: let every engineer's Agent Engine reach this service -------
# The shared Reasoning Engine service agent (used when identity_type != AGENT_IDENTITY)
# needs roles/run.invoker on the Cloud Run service. This is per-project, not
# per-engineer, so we grant it here once.
PROJECT_NUMBER="$(project_number)"
RUNTIME_SA="service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"

info "Granting roles/run.invoker to Reasoning Engine service agent (${RUNTIME_SA})..."
gcloud run services add-iam-policy-binding "$SHARED_MCP_SERVICE" \
  --region="$GOOGLE_CLOUD_LOCATION" \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/run.invoker" \
  --project="$GOOGLE_CLOUD_PROJECT" \
  --quiet >/dev/null
ok "run.invoker granted."

console_url "https://console.cloud.google.com/run/detail/${GOOGLE_CLOUD_LOCATION}/${SHARED_MCP_SERVICE}?project=${GOOGLE_CLOUD_PROJECT}"
ok "MCP gateway is ready. Next: bash scripts/lab/admin/03-register-mcp.sh"
