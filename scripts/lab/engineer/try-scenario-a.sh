#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Scenario A — INC-101 autonomous remediation, run via curl-like path
# against your deployed Agent Engine. No pass/fail assertions — just
# fires the prompt and prints the tool sequence + final answer.
#
# Use this if you don't want to open the ADK Web UI. For the richer
# interactive experience with the event stream / graph / trace tabs,
# use `make lab-web` instead.
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Try" "Scenario A — INC-101 autonomous remediation"

require_env GOOGLE_CLOUD_PROJECT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[[ -f "${REPO_ROOT}/.agent_engine_id" ]] \
  || die "No .agent_engine_id — run 'make lab-deploy' first."

export PYTHONPATH="$REPO_ROOT"
cd "$REPO_ROOT"
python3 "${REPO_ROOT}/scripts/lab/_lib/try_scenario.py" a
