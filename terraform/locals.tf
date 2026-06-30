data "google_project" "this" {
  project_id = var.project_id
}

resource "random_id" "lab" {
  count       = var.lab_user_id == "" ? 1 : 0
  byte_length = 3
}

locals {
  # Mirrors enterprise_support_agent/config.py's _suffixed() — keep both in
  # sync if either changes. Empty lab_user_id -> auto-random hex suffix
  # (random_id.lab), explicit lab_user_id -> use it verbatim.
  suffix = var.lab_user_id != "" ? var.lab_user_id : random_id.lab[0].hex

  mcp_service_name   = "sre-mcp-gateway-${local.suffix}"
  model_armor_name   = "enterprise-security-template-${local.suffix}"
  secret_name        = "mcp-gateway-url-${local.suffix}"
  agent_display_name = "enterprise_skills_support_agent-${local.suffix}"
  skill_id           = "incident-escalator-${local.suffix}"
  artifact_repo_id   = "enterprise-support-agent-${local.suffix}"
  # GCS bucket names are globally unique across ALL of GCP, not just this
  # project — the project number makes this safe even if two different
  # projects pick the same lab_user_id.
  staging_bucket_name = "agent-engine-staging-${data.google_project.this.number}-${local.suffix}"

  image_uri = "${var.region}-docker.pkg.dev/${var.project_id}/${local.artifact_repo_id}/sre-mcp-gateway:latest"
}
