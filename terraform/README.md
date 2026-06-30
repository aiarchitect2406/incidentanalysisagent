# Terraform — enterprise_support_agent lab infra

`terraform apply` provisions the GCP-side infra for this lab and deploys the agent, so a team can
stand the whole thing up in their own project with one command instead of following
`docs/L400-playbook.md` step by step by hand.

## What's actually Terraform-native vs. scripted

Several GEAP pieces used here are Preview products without confirmed first-class Terraform resources
at the time this module was written. Rather than pretend otherwise (the exact mistake found and fixed
elsewhere in this repo — a `GEAP_ENABLE_MEMORY_BANK` env var that didn't correspond to anything real),
this module is explicit about the split:

| Resource | How it's managed | Why |
|---|---|---|
| API enablement | Terraform-native (`google_project_service`, `apis.tf`) | Standard, stable |
| Staging GCS bucket | Terraform-native (`google_storage_bucket`, `storage.tf`) | Standard |
| Artifact Registry repo | Terraform-native (`google_artifact_registry_repository`, `cloud_run.tf`) | Standard |
| MCP gateway container image | `null_resource` + `gcloud builds submit` (`cloud_run.tf`) | Terraform doesn't build containers itself; this is the same thing `gcloud run deploy --source` does under the hood |
| MCP gateway Cloud Run service | Terraform-native (`google_cloud_run_v2_service`, `cloud_run.tf`) | Confirmed resource |
| Cloud Run IAM invoker bindings | Terraform-native (`google_cloud_run_v2_service_iam_member`, `iam.tf`) | Confirmed resource |
| `mcp-gateway-url[-suffix]` secret | Terraform-native (`google_secret_manager_secret[_version]`, `secrets.tf`) | Standard — and simpler than the Makefile's version, since Terraform already knows the Cloud Run URI as a resource attribute |
| Model Armor template | `null_resource` + `gcloud model-armor templates create` (`scripted_steps.tf`) | Verified `gcloud` command, but no `google_model_armor_template` Terraform resource confirmed for this provider version — check `terraform providers schema -json \| grep -i modelarmor` against your pinned `google`/`google-beta` provider version before assuming otherwise |
| Skill Registry publish | `null_resource` calling `make publish-skill` (`scripted_steps.tf`) | Agent Skill Registry publish is a content upload via the Vertex AI SDK, not a declarative resource |
| Agent Registry MCP server registration | `null_resource` calling `make register-mcp` (`scripted_steps.tf`) | Same reasoning — also keeps this module from duplicating `scripts/register_mcp_in_agent_registry.sh`'s logic |
| Vertex AI Agent Engine deploy (agent + Agent Identity) | `null_resource` calling `make deploy-agent` (`scripted_steps.tf`) | Agent Engine deployment ships application code — a software deploy, not infra. Google's own docs deploy this via SDK/CLI, never Terraform |
| Agent's own Agent Identity → MCP gateway IAM binding | `null_resource` calling `make bind-agent-identity` (`scripted_steps.tf`) | Depends on a value (`.agent_identity`) only known after the software-deploy step above runs |
| Agent Gateway resource itself | **Not in this module at all** — see `../docs/agent-gateway-setup.md` | Preview surface; I could not verify a stable `gcloud`/Terraform command for creating the gateway resource itself in time for this writeup. Don't trust a fabricated one — confirm against current docs first. |

Terraform owns the stable cloud plumbing and the Cloud Run deployment outright; for the rest, it
shells out (in dependency order, via `null_resource` `local-exec`) to the same `make` targets you'd
run by hand — so `terraform apply` and following the playbook manually produce identical results, just
one is one command.

**If you use `make tf-apply`, don't also run `make deploy-gateway`** — Terraform already built and
deployed the Cloud Run service declaratively; running the Makefile's imperative `gcloud run deploy`
on top of it works (Cloud Run deploys are idempotent) but creates configuration drift Terraform will
flag on the next `plan`. `make demo-ready` deliberately does NOT include `deploy-gateway` in its
target chain for this reason — run `make tf-apply` (or `make deploy-gateway`) once, then
`make demo-ready` for the rest.

## Multi-engineer usage (same project, no collisions)

Every named resource is suffixed with `local.suffix` (`locals.tf`), derived from `var.lab_user_id`:

```bash
# Solo / first run in a project — sets up shared APIs & IAM, gets a random suffix:
terraform apply

# Named, stable suffix instead of random:
terraform apply -var="lab_user_id=alice"

# A second engineer joining an ALREADY-set-up project:
terraform apply -var="lab_user_id=bob" -var="manage_shared_infra=false"
```

Or via the Makefile wrapper from the repo root: `make tf-apply LAB_USER_ID=alice`.

`manage_shared_infra` (default `true`) gates the project-WIDE, non-suffixed resources: API enablement
and the shared Reasoning Engine service agent's IAM bindings (`apis.tf`, the project-level grants in
`iam.tf`). These aren't per-engineer — granting the same role to the same shared service agent twice is
a harmless no-op, but **`terraform destroy` is not**: if every engineer's own Terraform state contains
those project-level bindings, the first engineer to run `terraform destroy` will remove them out from
under everyone else's still-running lab. Setting `manage_shared_infra=false` keeps those resources out
of that engineer's state entirely, so their `destroy` can only ever touch their own suffixed resources.

### State isolation

**Recommended: local state, one clone per engineer.** Since every resource name is suffixed and
disjoint, there's no need for a shared backend — each engineer's `terraform.tfstate` only ever
describes their own resources, and there's zero lock contention. This is the simplest setup for a
workshop and what `make tf-apply` assumes.

**Optional: a shared GCS backend**, if you want persistent/graded state instead of per-laptop local
state — give each engineer their own state path:

```hcl
# backend.tf (not included by default — add it if you want this)
terraform {
  backend "gcs" {
    bucket = "your-tfstate-bucket"
    # set at `terraform init` time, not here, so it can vary per engineer:
    # terraform init -backend-config="prefix=labs/state/${lab_user_id}"
  }
}
```

## Usage

```bash
cd terraform
terraform init
terraform apply -var="project_id=$GOOGLE_CLOUD_PROJECT" -var="lab_user_id=$LAB_USER_ID"
terraform output                     # gateway URL, staging bucket, resolved suffix, next steps
LAB_USER_ID=$LAB_USER_ID make -C .. smoke-test   # verify (not part of `apply` on purpose)
```

`terraform destroy` with the same `-var` flags tears down everything this module created for that
`lab_user_id` (the Cloud Run service, secret, staging bucket, Artifact Registry repo, and — via the
scripted steps' local-exec — re-running won't un-deploy the Agent Engine instance or Skill Registry
entry automatically; use `make tear-down LAB_USER_ID=...` from the repo root for those, since
`null_resource` has no native delete-time provisioner wired up here for them).

## Prerequisites

- `gcloud`, `terraform >= 1.5`, `python3` with this repo's dependencies installed (the scripted steps
  shell out to the same Python scripts the Makefile uses) on the machine running `terraform apply`.
- `gcloud auth application-default login` completed.
- Billing enabled on the target project.
