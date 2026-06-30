# Terraform already knows the Cloud Run URI as a resource attribute, so
# unlike the Makefile's deploy-gateway target (which shells out to `gcloud
# run services describe` after the fact), this just reads it directly — no
# script needed for this one.
resource "google_secret_manager_secret" "mcp_gateway_url" {
  project   = var.project_id
  secret_id = local.secret_name

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "mcp_gateway_url" {
  secret      = google_secret_manager_secret.mcp_gateway_url.id
  secret_data = google_cloud_run_v2_service.mcp_gateway.uri
}
