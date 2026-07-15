# Steps that are fundamentally software-deploys or preview-API calls rather
# than declarative infra — see terraform/README.md's native-vs-scripted
# table for why these are null_resource + local-exec instead of first-class
# Terraform resources. Each one shells out to the SAME Makefile target an
# operator would run by hand, passing the SAME LAB_USER_ID-derived suffix
# Terraform computed in locals.tf (local.suffix — always resolved, never the
# possibly-empty var.lab_user_id, so a random auto-suffix here can never
# diverge from what these scripts create).

# ---- Model Armor template -----------------------------------------------
# Uses the Python SDK (scripts/ensure_model_armor_template.py) rather than
# `gcloud model-armor`, which was observed to fail with a PERMISSION_DENIED
# / "authenticated as None" error under ADC-override credential resolution
# in at least one real environment — even for an account with roles/owner
# that worked fine for every other gcloud command. The SDK resolves ADC the
# same way the rest of this repo's Python does, sidestepping that class of
# credential-resolution bug entirely. See that script's docstring for detail.
resource "null_resource" "model_armor_template" {
  triggers = {
    template_name = local.model_armor_name
  }

  provisioner "local-exec" {
    command = "python3 ${var.repo_root}/scripts/ensure_model_armor_template.py ${local.model_armor_name} ${var.project_id} ${var.region}"
  }

  depends_on = [google_project_service.apis]
}

# ---- Publish the incident-escalator skill to Skill Registry -------------
resource "null_resource" "publish_skill" {
  triggers = {
    skill_md_hash = filesha256("${var.repo_root}/enterprise_support_agent/skills/incident-escalator/SKILL.md")
    skill_id      = local.skill_id
  }

  provisioner "local-exec" {
    command = "GOOGLE_CLOUD_PROJECT=${var.project_id} GOOGLE_CLOUD_LOCATION=${var.region} make -C ${var.repo_root} publish-skill LAB_USER_ID=${local.suffix}"
  }

  depends_on = [google_project_service.apis]
}

# ---- Register the MCP gateway in Agent Registry --------------------------
resource "null_resource" "register_mcp" {
  triggers = {
    toolspec_hash = filesha256("${var.repo_root}/enterprise_support_agent/toolspec.json")
    service_name  = local.mcp_service_name
  }

  provisioner "local-exec" {
    command = "GOOGLE_CLOUD_PROJECT=${var.project_id} GOOGLE_CLOUD_LOCATION=${var.region} make -C ${var.repo_root} register-mcp LAB_USER_ID=${local.suffix}"
  }

  depends_on = [google_cloud_run_v2_service.mcp_gateway]
}

# ---- Deploy the agent to Agent Runtime (Agent Identity + Skill Registry +
#      Sessions/Memory Bank — see ../scripts/deploy_skills_agent.py) ------
resource "null_resource" "deploy_agent" {
  triggers = {
    agent_source_hash  = filesha256("${var.repo_root}/enterprise_support_agent/agent.py")
    deploy_script_hash = filesha256("${var.repo_root}/scripts/deploy_skills_agent.py")
  }

  provisioner "local-exec" {
    command = <<-EOT
      GOOGLE_CLOUD_PROJECT=${var.project_id} \
      GOOGLE_CLOUD_LOCATION=${var.region} \
      AGENT_STAGING_BUCKET=gs://${google_storage_bucket.staging.name} \
      make -C ${var.repo_root} deploy-agent LAB_USER_ID=${local.suffix}
    EOT
  }

  depends_on = [
    null_resource.model_armor_template,
    null_resource.register_mcp,
    google_secret_manager_secret_version.mcp_gateway_url,
    google_storage_bucket.staging,
  ]
}

# ---- Bind the deployed agent's own Agent Identity (not the shared SA) on
#      the MCP gateway — see ../docs/agent-gateway-setup.md ---------------
resource "null_resource" "bind_agent_identity" {
  triggers = {
    deploy_agent_id = null_resource.deploy_agent.id
  }

  provisioner "local-exec" {
    command = "GOOGLE_CLOUD_PROJECT=${var.project_id} GOOGLE_CLOUD_LOCATION=${var.region} make -C ${var.repo_root} bind-agent-identity LAB_USER_ID=${local.suffix}"
  }

  depends_on = [null_resource.deploy_agent]
}
