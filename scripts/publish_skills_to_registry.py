"""Publish the on-disk `incident-escalator` skill to GEAP Skill Registry.

Run this once after editing SKILL.md. In production the agent loads skills
at runtime via GCPSkillRegistry — it never reads the local filesystem.

The agent's `load_skill` call (see remediation_agent's instruction in
agent.py) looks the skill up by the `name:` field in SKILL.md's frontmatter
("incident-escalator"), which we never rename. What we DO suffix per
LAB_USER_ID is the registry *resource ID* (SKILL_ID below) — without that,
two engineers publishing concurrently in the same project would each
`delete()`-then-`create()` the exact same resource, clobbering each other
mid-lab.

Reference: https://docs.cloud.google.com/gemini-enterprise-agent-platform/build/skill-registry/create-manage
"""
from __future__ import annotations

import pathlib
import sys

import vertexai

from enterprise_support_agent import config

SKILL_DIR = pathlib.Path(__file__).resolve().parent.parent / "enterprise_support_agent" / "skills" / "incident-escalator"
SKILL_ID = config.skill_registry_skill_name()  # e.g. "incident-escalator-alice"; see config.lab_user_id()
DISPLAY_NAME = SKILL_ID
DESCRIPTION = "Enterprise support incident triage with parallel investigation, P0 escalation, and self-healing JVM heap remediation."


def publish() -> str:
    project = config.project_id()
    # Skill Registry is a regional service; pin to us-central1 even if the model
    # runs on the global endpoint.
    location = "us-central1"
    if not (SKILL_DIR / "SKILL.md").is_file():
        raise FileNotFoundError(f"SKILL.md missing under {SKILL_DIR}")

    client = vertexai.Client(
        project=project,
        location=location,
        http_options={"api_version": "v1beta1"},
    )

    print(f"[publish] Project: {project}  Location: {location}")
    print(f"[publish] Source:  {SKILL_DIR}")
    print(f"[publish] Skill ID: {SKILL_ID}")

    # Delete any previous skill with this ID so the create call is idempotent.
    full_name = f"projects/{project}/locations/{location}/skills/{SKILL_ID}"
    try:
        client.skills.delete(name=full_name)
        print(f"[publish] Deleted previous skill: {full_name}")
    except Exception as exc:
        if "not found" not in str(exc).lower() and "404" not in str(exc):
            print(f"[publish] (delete skipped: {type(exc).__name__})")

    result = client.skills.create(
        display_name=DISPLAY_NAME,
        description=DESCRIPTION,
        config={
            "skill_id": SKILL_ID,
            "local_path": str(SKILL_DIR),
            "wait_for_completion": True,
        },
    )

    name = getattr(result, "name", None) or str(result)
    print(f"[publish] Created skill: {name}")
    return name


if __name__ == "__main__":
    try:
        name = publish()
    except Exception as exc:
        print(f"[publish] FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
    print(f"\n[DEPLOYS_RESULT] {name}")
