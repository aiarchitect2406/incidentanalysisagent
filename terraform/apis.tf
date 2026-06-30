# Project-wide API enablement — shared across every lab_user_id in this
# project. See variable "manage_shared_infra" for why this is gated.
locals {
  required_apis = [
    "aiplatform.googleapis.com",       # Agent Runtime / Vertex AI Agent Engine
    "run.googleapis.com",              # MCP gateway Cloud Run service
    "modelarmor.googleapis.com",       # Model Armor (app- and network-layer)
    "cloudtrace.googleapis.com",       # Optimize pillar
    "logging.googleapis.com",          # Optimize pillar
    "secretmanager.googleapis.com",    # mcp-gateway-url[-suffix] secret
    "agentregistry.googleapis.com",    # Govern pillar — Agent Registry (NOT discoveryengine.googleapis.com)
    "artifactregistry.googleapis.com", # MCP gateway container image
    "cloudbuild.googleapis.com",       # Builds the MCP gateway container image
    "iam.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = var.manage_shared_infra ? toset(local.required_apis) : toset([])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
