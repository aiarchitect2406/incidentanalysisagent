output "lab_suffix" {
  description = "The resolved suffix used for every named resource in this apply (explicit lab_user_id, or the auto-generated random one)."
  value       = local.suffix
}

output "mcp_gateway_url" {
  description = "Cloud Run URL of the MCP gateway."
  value       = google_cloud_run_v2_service.mcp_gateway.uri
}

output "mcp_service_name" {
  value = local.mcp_service_name
}

output "model_armor_template" {
  value = local.model_armor_name
}

output "secret_name" {
  value = local.secret_name
}

output "staging_bucket" {
  value = "gs://${google_storage_bucket.staging.name}"
}

output "skill_id" {
  value = local.skill_id
}

output "next_steps" {
  value = <<-EOT
    Infra + agent deploy complete for lab_suffix=${local.suffix}.

    Run the smoke test (not part of `terraform apply` on purpose — see README):
      LAB_USER_ID=${local.suffix} make -C ${var.repo_root} smoke-test

    Open the Console (Agent Registry -> Agents tab) and look for an agent
    display-named enterprise_skills_support_agent-${local.suffix}.
  EOT
}
