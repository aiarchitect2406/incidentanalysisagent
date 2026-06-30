# The MCP gateway (enterprise_support_agent/mcp_server.py) packaged as a
# container and deployed as a private (IAM-gated) Cloud Run v2 service.
# Terraform owns this end to end — see terraform/README.md's native-vs-
# scripted table for why this one's different from the Agent Engine /
# Skill Registry / Agent Registry steps in scripted_steps.tf.

resource "google_artifact_registry_repository" "containers" {
  project       = var.project_id
  location      = var.region
  repository_id = local.artifact_repo_id
  format        = "DOCKER"
  description   = "MCP gateway container images for the enterprise support agent lab (${local.suffix})."

  depends_on = [google_project_service.apis]
}

# Terraform doesn't build containers itself — this shells out to Cloud Build,
# the same way `gcloud run deploy --source` does under the hood, but as an
# explicit step so the resulting image URI is a normal Terraform value
# (local.image_uri) that google_cloud_run_v2_service can reference directly.
resource "null_resource" "build_gateway_image" {
  triggers = {
    source_hash = filesha256("${var.repo_root}/enterprise_support_agent/mcp_server.py")
    image_uri   = local.image_uri
  }

  provisioner "local-exec" {
    # --pack (not --tag) is required: this source tree has a Procfile, not a
    # Dockerfile, so it needs Cloud Native Buildpacks, the same mechanism
    # `gcloud run deploy --source` uses under the hood. Verified against
    # https://docs.cloud.google.com/docs/buildpacks/build-application#remote_builds
    command = "gcloud builds submit '${var.repo_root}/enterprise_support_agent' --pack image='${local.image_uri}' --project='${var.project_id}'"
  }

  depends_on = [google_artifact_registry_repository.containers]
}

resource "google_cloud_run_v2_service" "mcp_gateway" {
  name                = local.mcp_service_name
  project             = var.project_id
  location            = var.region
  deletion_protection = false
  # No google_cloud_run_v2_service_iam_member granting allUsers anywhere in
  # this module -> IAM-gated by default, equivalent to `--no-allow-unauthenticated`.
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    containers {
      image = local.image_uri

      env {
        name  = "GOOGLE_CLOUD_PROJECT"
        value = var.project_id
      }
      env {
        name  = "GOOGLE_CLOUD_LOCATION"
        value = var.region
      }
      env {
        name  = "MODEL_ARMOR_TEMPLATE"
        value = local.model_armor_name
      }
    }
  }

  depends_on = [null_resource.build_gateway_image]
}
