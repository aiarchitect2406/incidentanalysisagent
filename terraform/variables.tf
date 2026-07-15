variable "project_id" {
  description = "GCP project ID to provision the lab infra in."
  type        = string
}

variable "region" {
  description = "Region for regional resources (Cloud Run, Model Armor, Agent Registry, staging bucket, and the reasoningEngine/Agent Engine resource itself). Must match enterprise_support_agent/config.py's model_armor_location() / agent_engine_location() for the deployed agent to find them."
  type        = string
  default     = "us-central1"
}

variable "lab_user_id" {
  description = <<-EOT
    Unique per-engineer suffix so concurrent enablement-lab runs in one shared
    project don't collide on resource names (Cloud Run service, Model Armor
    template, Secret Manager secret, GCS staging bucket). Leave empty for an
    auto-generated random suffix — the right default for a workshop where
    engineers shouldn't have to coordinate names with each other.

    Must match the LAB_USER_ID env var / Makefile variable used for the rest
    of the deploy (scripts/publish_skills_to_registry.py,
    scripts/deploy_skills_agent.py, scripts/register_mcp_in_agent_registry.sh
    all read it via enterprise_support_agent/config.py's lab_user_id()).
    `make tf-apply` threads this through automatically.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.lab_user_id == "" || can(regex("^[a-z][a-z0-9-]{0,16}$", var.lab_user_id))
    error_message = "lab_user_id must be lowercase alphanumeric/hyphen, start with a letter, and be <=17 characters (leaves headroom under GCP naming limits once prefixed/suffixed, e.g. Cloud Run service names)."
  }
}

variable "manage_shared_infra" {
  description = <<-EOT
    Whether this apply should manage PROJECT-WIDE, shared resources: API
    enablement and the IAM bindings on the shared Reasoning Engine service
    agent. These are NOT per-lab_user_id — they're shared across every
    engineer in the project.

    Default true is correct for the FIRST apply in a project (solo run, or
    the first engineer / an admin setting up a shared project for a team).
    Every SUBSEQUENT engineer joining that same already-set-up project should
    pass `-var="manage_shared_infra=false"` (or `make tf-apply
    LAB_USER_ID=bob MANAGE_SHARED_INFRA=false`) so their own `terraform
    destroy` later can't accidentally rip out IAM bindings/API enablement
    that someone else's lab still depends on — see terraform/README.md.
  EOT
  type        = bool
  default     = true
}

variable "repo_root" {
  description = "Path to the repository root (containing enterprise_support_agent/), used by the scripted (non-Terraform-native) steps to find the agent source and deploy scripts."
  type        = string
  default     = ".."
}
