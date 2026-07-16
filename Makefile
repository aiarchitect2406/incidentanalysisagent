# Enterprise Support Agent — workshop Makefile.
#
# For engineers:
#   1. export GOOGLE_CLOUD_PROJECT=<project>  LAB_USER_ID=<yourname>
#   2. make lab-deploy       (~4 minutes: your Agent Engine instance)
#   3. make lab-web          (opens ADK Web UI)
#   4. make lab-teardown     (when done: deletes only YOUR agent)
#
# For workshop admins (once, before engineers arrive):
#   1. export GOOGLE_CLOUD_PROJECT=<project>
#   2. make lab-admin-setup     (~10 minutes: shared MCP gateway + registrations)
#   3. make lab-admin-teardown  (after workshop: removes shared infra)
#
# For solo local development (no GCP deploy):
#   make local                  (starts MCP + adk api_server on localhost)

SHELL := /bin/bash

PROJECT_ID     ?= $(GOOGLE_CLOUD_PROJECT)
LOCATION       ?= $(or $(GOOGLE_CLOUD_LOCATION),us-central1)
LAB_USER_ID    ?=
PYTHON         ?= python3
SCRIPTS_DIR    ?= scripts
TESTS_DIR      ?= tests

export GOOGLE_CLOUD_PROJECT  := $(PROJECT_ID)
export GOOGLE_CLOUD_LOCATION := $(LOCATION)
export LAB_USER_ID
# scripts/ and tests/ scripts do `from enterprise_support_agent import config`,
# which needs the repo root on sys.path.
export PYTHONPATH            := .

.PHONY: help env-check env-check-lab-user \
        lab-admin-setup lab-admin-teardown \
        lab-deploy lab-verify lab-web lab-teardown lab-console \
        local smoke-test eval

help:
	@echo "Targets:"
	@awk -F':|##' '/^[a-zA-Z_-]+:.*##/ {printf "  %-22s %s\n", $$1, $$3}' $(MAKEFILE_LIST)

env-check:
	@: $${GOOGLE_CLOUD_PROJECT:?Need to set GOOGLE_CLOUD_PROJECT}
	@echo "✓ Project: $(PROJECT_ID)  Region: $(LOCATION)"

env-check-lab-user: env-check
	@: $${LAB_USER_ID:?Need to set LAB_USER_ID (your first name, lowercase, no spaces)}
	@echo "✓ Lab user: $(LAB_USER_ID)"

# ================ ADMIN =================

lab-admin-setup: env-check ## ADMIN ONLY: provision shared workshop infra (~10 min)
	bash $(SCRIPTS_DIR)/lab/admin/01-preflight.sh
	bash $(SCRIPTS_DIR)/lab/admin/02-mcp-gateway.sh
	bash $(SCRIPTS_DIR)/lab/admin/03-register-mcp.sh
	bash $(SCRIPTS_DIR)/lab/admin/04-publish-skill.sh
	@echo ""
	@echo "==============================================="
	@echo "  ✅  Shared workshop infra is READY."
	@echo "  Engineers can now run: make lab-deploy LAB_USER_ID=<yourname>"
	@echo "==============================================="

lab-admin-teardown: env-check ## ADMIN ONLY: tear down shared workshop infra
	bash $(SCRIPTS_DIR)/lab/admin/99-teardown.sh

# ================ ENGINEER ==============

lab-deploy: env-check-lab-user ## Deploy YOUR agent (uses shared MCP gateway)
	bash $(SCRIPTS_DIR)/lab/engineer/05-deploy-agent.sh
	bash $(SCRIPTS_DIR)/lab/engineer/06-verify.sh
	@echo ""
	@echo "==============================================="
	@echo "  ✅  Your agent is deployed and verified."
	@echo "  To try it in a browser: make lab-web"
	@echo "==============================================="

lab-verify: env-check-lab-user ## Re-run the smoke test against YOUR deployed agent
	bash $(SCRIPTS_DIR)/lab/engineer/06-verify.sh

lab-web: env-check-lab-user ## Open ADK Web UI pointed at YOUR agent
	@if [ ! -f .agent_engine_id ]; then \
	  echo "No .agent_engine_id — run 'make lab-deploy' first."; exit 1; fi
	@gw=$$(gcloud secrets versions access latest --secret=mcp-gateway-url --project=$(PROJECT_ID)); \
	  engine_id=$$(cat .agent_engine_id); \
	  echo "Local ADK Web UI, sessions shared with deployed agent: $$engine_id"; \
	  MCP_GATEWAY_URL="$$gw" adk web \
	    --session_service_uri="agentengine://$$engine_id" \
	    .

lab-console: env-check-lab-user ## Print Cloud Console URLs for YOUR agent + shared infra
	@bash $(SCRIPTS_DIR)/console-urls.sh

lab-teardown: env-check-lab-user ## Delete YOUR agent + staging bucket (leaves shared infra)
	bash $(SCRIPTS_DIR)/lab/engineer/99-teardown.sh

# ================ LOCAL DEV =============

local: env-check ## Run everything on localhost — no GCP deploy needed
	bash $(SCRIPTS_DIR)/local/run.sh

# ================ SMOKE / EVAL (advanced) ==================

smoke-test: env-check-lab-user ## Headless smoke test against YOUR deployed agent
	$(PYTHON) $(TESTS_DIR)/smoke_test.py

eval: env-check-lab-user ## Run the eval set against YOUR deployed agent
	$(PYTHON) $(TESTS_DIR)/eval_run.py
