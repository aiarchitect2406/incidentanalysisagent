# L400 Enterprise Support Agent — operations Makefile.
#
# Required env:
#   GOOGLE_CLOUD_PROJECT
#   GOOGLE_CLOUD_LOCATION (default us-central1)
#   LAB_USER_ID           (optional — set this to run a side-by-side copy of
#                          the whole lab in a shared project, e.g. for a team
#                          enablement session. Empty = today's unsuffixed
#                          solo-dev names, unchanged. See terraform/README.md.)
#
# Typical demo prep, end to end:   make demo-ready
# Launch the demo UI:              make web
# Provision infra via Terraform:   make tf-apply LAB_USER_ID=alice

SHELL := /bin/bash

PROJECT_ID            ?= $(GOOGLE_CLOUD_PROJECT)
LOCATION              ?= $(or $(GOOGLE_CLOUD_LOCATION),us-central1)
LAB_USER_ID           ?=
STAGING_BUCKET        ?= gs://agent-engine-09292025
PYTHON                ?= python3
TF_DIR                ?= terraform
SCRIPTS_DIR           ?= scripts
TESTS_DIR             ?= tests

# Same per-engineer suffixing rule as enterprise_support_agent/config.py's
# _suffixed() — keep these two in sync if either changes.
ifneq ($(strip $(LAB_USER_ID)),)
MCP_SERVICE_NAME      ?= sre-mcp-gateway-$(LAB_USER_ID)
MODEL_ARMOR_TEMPLATE  ?= enterprise-security-template-$(LAB_USER_ID)
MCP_GATEWAY_SECRET    ?= mcp-gateway-url-$(LAB_USER_ID)
else
MCP_SERVICE_NAME      ?= sre-mcp-gateway
MODEL_ARMOR_TEMPLATE  ?= enterprise-security-template
MCP_GATEWAY_SECRET    ?= mcp-gateway-url
endif

export GOOGLE_CLOUD_PROJECT  := $(PROJECT_ID)
export GOOGLE_CLOUD_LOCATION := $(LOCATION)
export LAB_USER_ID
export MCP_SERVICE_NAME
export MODEL_ARMOR_TEMPLATE
export AGENT_STAGING_BUCKET  := $(STAGING_BUCKET)
# scripts/ and tests/ scripts do `from enterprise_support_agent import config`,
# which only resolves if the repo root is on sys.path — Python otherwise only
# puts the SCRIPT's own directory there. This makes `python3 scripts/foo.py`
# work the same as the old `python3 foo.py` did when these lived at root.
export PYTHONPATH            := .

PROJECT_NUMBER = $(shell gcloud projects describe $(PROJECT_ID) --format='value(projectNumber)')
RUNTIME_SA     = service-$(PROJECT_NUMBER)@gcp-sa-aiplatform-re.iam.gserviceaccount.com

.PHONY: help setup publish-skill deploy-gateway register-mcp deploy-agent bind-agent-identity \
        eval smoke-test web run-agent demo-ready tear-down env-check tf-apply tf-output tf-destroy

help:
	@echo "Targets:"
	@awk -F':|##' '/^[a-zA-Z_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$3}' $(MAKEFILE_LIST)

env-check: ## Verify required env vars are set
	@: $${GOOGLE_CLOUD_PROJECT:?Need to set GOOGLE_CLOUD_PROJECT}
	@echo "✓ Project: $(PROJECT_ID)  Region: $(LOCATION)  Lab user: $(or $(LAB_USER_ID),<none (unsuffixed)>)"

setup: env-check ## One-time: enable APIs + create runtime service account bindings
	gcloud services enable \
	  aiplatform.googleapis.com \
	  modelarmor.googleapis.com \
	  run.googleapis.com \
	  cloudtrace.googleapis.com \
	  logging.googleapis.com \
	  secretmanager.googleapis.com \
	  agentregistry.googleapis.com \
	  --project=$(PROJECT_ID)
	gcloud projects add-iam-policy-binding $(PROJECT_ID) \
	  --member="serviceAccount:$(RUNTIME_SA)" \
	  --role="roles/aiplatform.user" || true
	gcloud projects add-iam-policy-binding $(PROJECT_ID) \
	  --member="serviceAccount:$(RUNTIME_SA)" \
	  --role="roles/modelarmor.user" || true
	gcloud projects add-iam-policy-binding $(PROJECT_ID) \
	  --member="serviceAccount:$(RUNTIME_SA)" \
	  --role="roles/logging.logWriter" || true

publish-skill: env-check ## Publish incident-escalator SKILL.md to GEAP Skill Registry
	$(PYTHON) $(SCRIPTS_DIR)/publish_skills_to_registry.py

deploy-gateway: env-check ## Build and deploy the MCP gateway to Cloud Run with IAM-only auth
	gcloud run deploy $(MCP_SERVICE_NAME) \
	  --source enterprise_support_agent \
	  --region $(LOCATION) \
	  --no-allow-unauthenticated \
	  --set-env-vars=GOOGLE_CLOUD_PROJECT=$(PROJECT_ID),GOOGLE_CLOUD_LOCATION=$(LOCATION),MODEL_ARMOR_TEMPLATE=$(MODEL_ARMOR_TEMPLATE) \
	  --project=$(PROJECT_ID)
	gcloud run services add-iam-policy-binding $(MCP_SERVICE_NAME) \
	  --region=$(LOCATION) \
	  --member="serviceAccount:$(RUNTIME_SA)" \
	  --role="roles/run.invoker" \
	  --project=$(PROJECT_ID)
	@gw=$$(gcloud run services describe $(MCP_SERVICE_NAME) --region=$(LOCATION) --format='value(status.url)' --project=$(PROJECT_ID)); \
	  printf "%s" "$$gw" | gcloud secrets create $(MCP_GATEWAY_SECRET) --replication-policy=automatic --data-file=- --project=$(PROJECT_ID) 2>/dev/null \
	  || printf "%s" "$$gw" | gcloud secrets versions add $(MCP_GATEWAY_SECRET) --data-file=- --project=$(PROJECT_ID); \
	  echo "MCP gateway URL stored in Secret Manager ($(MCP_GATEWAY_SECRET)): $$gw"

register-mcp: env-check ## Register the MCP gateway in GEAP Agent Registry (Topology view)
	bash $(SCRIPTS_DIR)/register_mcp_in_agent_registry.sh

deploy-agent: env-check ## Deploy the agent to Agent Runtime; writes .agent_engine_id + .agent_identity
	@gw=$$(gcloud secrets versions access latest --secret=$(MCP_GATEWAY_SECRET) --project=$(PROJECT_ID)); \
	  echo "Using MCP gateway: $$gw"; \
	  MCP_GATEWAY_URL="$$gw" $(PYTHON) $(SCRIPTS_DIR)/deploy_skills_agent.py

bind-agent-identity: env-check ## Grant the deployed agent's OWN identity (not the shared SA) invoker on the MCP gateway
	@if [ ! -f .agent_identity ]; then \
	  echo "No .agent_identity file — deploy-agent ran without AGENT_IDENTITY_ENABLED=true (the"; \
	  echo "default), or identity_type=AGENT_IDENTITY wasn't accepted (Preview feature). Either way"; \
	  echo "the shared $(RUNTIME_SA) binding from 'make deploy-gateway' is already in effect via"; \
	  echo "Terraform-managed IAM. Nothing to (re)bind — skipping."; \
	else \
	  identity=$$(cat .agent_identity); \
	  case "$$identity" in \
	    principal://*) member="$$identity" ;; \
	    *) member="principal://$$identity" ;; \
	  esac; \
	  echo "Binding roles/run.invoker on $(MCP_SERVICE_NAME) to agent identity:"; \
	  echo "  $$member"; \
	  echo "(Preview API — if gcloud rejects this --member format, check the current"; \
	  echo "syntax at https://docs.cloud.google.com/iam/docs/principal-identifiers)"; \
	  gcloud run services add-iam-policy-binding $(MCP_SERVICE_NAME) \
	    --region=$(LOCATION) \
	    --member="$$member" \
	    --role="roles/run.invoker" \
	    --project=$(PROJECT_ID); \
	fi

eval: env-check ## Run the eval set against the deployed agent (populates Evaluation tab)
	$(PYTHON) $(TESTS_DIR)/eval_run.py

smoke-test: env-check ## Headless E2E: run Scenarios A, B, and C (memory recall); assert on trace + logs
	$(PYTHON) $(TESTS_DIR)/smoke_test.py

web: env-check ## Launch ADK Web UI locally, running the real agent code, sharing Sessions/Memory Bank with the deployed Agent Runtime resource
	@if [ ! -f .agent_engine_id ]; then echo "Run 'make deploy-agent' first."; exit 1; fi
	@gw=$$(gcloud secrets versions access latest --secret=$(MCP_GATEWAY_SECRET) --project=$(PROJECT_ID)); \
	  engine_id=$$(cat .agent_engine_id); \
	  echo "ADK Web UI: local agent code, gateway=$$gw"; \
	  echo "Sessions/Memory Bank shared with deployed resource: $$engine_id"; \
	  MCP_GATEWAY_URL="$$gw" adk web \
	    --session_service_uri="agentengine://$$engine_id" \
	    --memory_service_uri="agentengine://$$engine_id" \
	    .

run-agent: env-check ## Launch ADK terminal chat (no browser) locally, sharing Sessions/Memory Bank with the deployed Agent Runtime resource
	@if [ ! -f .agent_engine_id ]; then echo "Run 'make deploy-agent' first."; exit 1; fi
	@gw=$$(gcloud secrets versions access latest --secret=$(MCP_GATEWAY_SECRET) --project=$(PROJECT_ID)); \
	  engine_id=$$(cat .agent_engine_id); \
	  MCP_GATEWAY_URL="$$gw" adk run \
	    --session_service_uri="agentengine://$$engine_id" \
	    --memory_service_uri="agentengine://$$engine_id" \
	    .

console: env-check ## Print all Google Cloud Console URLs for the demo
	@bash $(SCRIPTS_DIR)/console_checklist.sh

demo-ready: publish-skill register-mcp deploy-agent bind-agent-identity eval smoke-test ## Full pre-demo chain (run `make deploy-gateway` OR `make tf-apply` first — not both, see terraform/README.md)
	@echo
	@echo "==============================================="
	@echo "  ✅  Demo is READY. Run 'make web' to launch."
	@echo "  (or open the Agent Registry console page — see docs/L400-playbook.md)"
	@echo "==============================================="

tear-down: env-check ## Delete the deployed agent revision and Cloud Run service (cost cleanup)
	@if [ -f .agent_engine_id ]; then \
	  res=$$(cat .agent_engine_id); \
	  $(PYTHON) -c "import vertexai; vertexai.init(project='$(PROJECT_ID)', location='$(LOCATION)'); \
	    from vertexai import agent_engines; agent_engines.get('$$res').delete()" && rm -f .agent_engine_id .agent_identity; \
	fi
	gcloud run services delete $(MCP_SERVICE_NAME) --region=$(LOCATION) --quiet --project=$(PROJECT_ID) || true

tf-apply: env-check ## Provision the Terraform-native infra (see terraform/README.md for what that covers)
	cd $(TF_DIR) && terraform init -input=false && terraform apply \
	  -var="project_id=$(PROJECT_ID)" \
	  -var="region=$(LOCATION)" \
	  -var="lab_user_id=$(LAB_USER_ID)"

tf-output: ## Print Terraform outputs (gateway URL, staging bucket, resolved lab suffix, ...)
	cd $(TF_DIR) && terraform output

tf-destroy: env-check ## Tear down this lab_user_id's Terraform-managed infra
	cd $(TF_DIR) && terraform destroy \
	  -var="project_id=$(PROJECT_ID)" \
	  -var="region=$(LOCATION)" \
	  -var="lab_user_id=$(LAB_USER_ID)"
