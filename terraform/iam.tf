# Shared Reasoning Engine service agent bindings — fallback path used when an
# agent is deployed WITHOUT identity_type=AGENT_IDENTITY (or before that's
# confirmed working in this project/region — it's a Preview feature). Once
# `make deploy-agent` succeeds with Agent Identity, `make bind-agent-identity`
# additionally (not instead) grants the agent's own SPIFFE principal
# roles/run.invoker on the MCP gateway — see ../docs/agent-gateway-setup.md
# and auth_provider.py for what that changes.
#
# Project-wide and shared across every lab_user_id — see manage_shared_infra.

resource "google_project_iam_member" "runtime_sa_aiplatform_user" {
  count   = var.manage_shared_infra ? 1 : 0
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "runtime_sa_modelarmor_user" {
  count   = var.manage_shared_infra ? 1 : 0
  project = var.project_id
  role    = "roles/modelarmor.user"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "runtime_sa_logging" {
  count   = var.manage_shared_infra ? 1 : 0
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
}

# Per-lab IAM: this engineer's own Cloud Run gateway invoker grant for the
# shared service agent fallback path. Safe to manage per-lab_user_id because
# it's scoped to THIS engineer's own Cloud Run service (cloud_run.tf), not a
# project-level binding.
resource "google_cloud_run_v2_service_iam_member" "runtime_sa_invoker" {
  project  = google_cloud_run_v2_service.mcp_gateway.project
  location = google_cloud_run_v2_service.mcp_gateway.location
  name     = google_cloud_run_v2_service.mcp_gateway.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"
}
