#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# Scenario B — INC-666 (prompt-injection ticket).
#
# WARNING: this scenario does NOT block in this lab. Model Armor is
# provisioned (see the template in the Console) but not wired into
# the request path — that would need Agent Gateway, which we chose
# not to provision. You'll watch the agent obey the injection and do
# the wrong thing. That IS the teaching point: in-process defense
# isn't enough; the platform (Agent Gateway) is what does the block.
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Try" "Scenario B — INC-666 prompt injection"
warn "Expected outcome: the agent OBEYS the injection. This is intentional."
warn "See README.md 'Two scenarios' for the full explanation."
echo

require_env GOOGLE_CLOUD_PROJECT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[[ -f "${REPO_ROOT}/.agent_engine_id" ]] \
  || die "No .agent_engine_id — run 'make lab-deploy' first."

export PYTHONPATH="$REPO_ROOT"
cd "$REPO_ROOT"
python3 "${REPO_ROOT}/scripts/lab/_lib/try_scenario.py" b
