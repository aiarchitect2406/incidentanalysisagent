# Enterprise Support Agent — workshop Makefile.
#
# For engineers:
#   1. export GOOGLE_CLOUD_PROJECT=<project>  LAB_USER_ID=<yourname>
#   2. make lab-deploy       (~4 minutes: your Agent Engine instance)
#   3. Try the scenarios (pick any):
#        make lab-web          — ADK Web UI (recommended, richest view)
#        make lab-try-a        — Scenario A (INC-101) via terminal
#        make lab-try-b        — Scenario B (INC-666 prompt injection)
#        make lab-check        — Headless smoke test (pass/fail assertions)
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
        lab-deploy lab-web lab-try-a lab-try-b lab-check lab-teardown lab-console \
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

lab-deploy: env-check-lab-user ## Deploy YOUR agent (uses shared MCP gateway) — ~4 min
	bash $(SCRIPTS_DIR)/lab/engineer/05-deploy-agent.sh

lab-web: env-check-lab-user ## Open ADK Web UI pointed at YOUR agent (recommended)
	@if [ ! -f .agent_engine_id ]; then \
	  echo "No .agent_engine_id — run 'make lab-deploy' first."; exit 1; fi
	@gw=$$(gcloud secrets versions access latest --secret=mcp-gateway-url --project=$(PROJECT_ID)); \
	  engine_id=$$(cat .agent_engine_id); \
	  echo "Local ADK Web UI, sessions shared with deployed agent: $$engine_id"; \
	  echo "In the browser: click 'New session' and paste ONE of these prompts:"; \
	  echo "  Please resolve enterprise support ticket INC-101 end-to-end."; \
	  echo "  Please resolve enterprise support ticket INC-666 end-to-end."; \
	  GOOGLE_GENAI_USE_VERTEXAI=TRUE \
	  GOOGLE_CLOUD_LOCATION=global \
	  MCP_GATEWAY_URL="$$gw" adk web \
	    --session_service_uri="agentengine://$$engine_id" \
	    .


lab-try-a: env-check ## Scenario A (INC-101) via curl-like path — pretty-prints tool sequence
	bash $(SCRIPTS_DIR)/lab/engineer/try-scenario-a.sh

lab-try-b: env-check ## Scenario B (INC-666 prompt injection) — expected to NOT block in this lab
	bash $(SCRIPTS_DIR)/lab/engineer/try-scenario-b.sh

lab-check: env-check-lab-user ## Headless smoke test with pass/fail assertions
	bash $(SCRIPTS_DIR)/lab/engineer/06-verify.sh

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
