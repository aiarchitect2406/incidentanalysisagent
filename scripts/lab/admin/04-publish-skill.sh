#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# STEP 04 — Publish the incident-escalator skill to Skill Registry.
#
# GEAP pillar: Build (runbook = data, decoupled from agent code)
# What it creates:
#   * Skill Registry entry: incident-escalator (holds SKILL.md contents).
#     The deployed agent's remediation_agent calls load_skill('incident-escalator')
#     at runtime to fetch the current version — so we can edit the runbook
#     and re-publish here without redeploying any agent.
#
# Why this is a shared/admin step:
#   The skill is the same for every engineer. One published version means
#   everyone sees the same runbook (and if the instructor edits it live
#   during the workshop, everyone picks it up on their next agent run).
# ─────────────────────────────────────────────────────────────────────
source "$(dirname "${BASH_SOURCE[0]}")/../_lib/_common.sh"

banner "Build" "Publish incident-escalator runbook to Skill Registry"

require_env GOOGLE_CLOUD_PROJECT
require_cmd python3

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
[[ -f "${REPO_ROOT}/enterprise_support_agent/skills/incident-escalator/SKILL.md" ]] \
  || die "SKILL.md not found at ${REPO_ROOT}/enterprise_support_agent/skills/incident-escalator/SKILL.md"

info "Publishing SKILL.md from ${REPO_ROOT}/enterprise_support_agent/skills/incident-escalator ..."
# The Python publisher already reads config.skill_registry_skill_name(), which
# suffixes with LAB_USER_ID. For the SHARED workshop skill we want the unsuffixed
# name, so we clear LAB_USER_ID for this one call.
PYTHONPATH="$REPO_ROOT" LAB_USER_ID="" python3 "${REPO_ROOT}/scripts/lab/_lib/publish_skill.py"

console_url "https://console.cloud.google.com/gemini-enterprise/skill-registry?project=${GOOGLE_CLOUD_PROJECT}"
ok "Skill published as '${SHARED_SKILL_ID}'."
ok "Shared setup complete. Engineers can now run scripts/lab/engineer/05-deploy-agent.sh"
