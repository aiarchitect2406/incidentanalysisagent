# Agent Engine staging bucket — required by `vertexai.Client(...).agent_engines.create()`
# in ../scripts/deploy_skills_agent.py. One per lab_user_id since names must be
# globally unique across all of GCP.
resource "google_storage_bucket" "staging" {
  name                        = local.staging_bucket_name
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true # workshop infra — fine to delete with contents

  depends_on = [google_project_service.apis]
}
