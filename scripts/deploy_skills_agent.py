"""Deploy the enterprise support agent to Gemini Enterprise Agent Platform Agent Runtime.

This script:
  * Imports the production agent definition (coordinator + sub-agents).
  * Wraps it in AdkApp. Sessions and Memory Bank are wired automatically by
    Agent Runtime once deployed — there is no env var or extra plumbing for
    this (see agent.py's PreloadMemoryTool / generate_memories_callback for
    how the agent actually *uses* them, which is the part that does need
    code).
  * Deploys with identity_type=AGENT_IDENTITY so the agent gets its own
    SPIFFE identity + auto-rotated cert instead of the shared Reasoning
    Engine service agent — see auth_provider.py for what this changes.
  * Writes the resulting resource name to .agent_engine_id and the agent's
    identity principal to .agent_identity so the Makefile (`make
    bind-agent-identity`), smoke_test.py, and `adk web --agent-engine` can
    find them without prompting.

Reference: https://docs.cloud.google.com/gemini-enterprise-agent-platform/scale/runtime/agent-identity
"""
from __future__ import annotations

import logging
import os
import pathlib
import sys

import vertexai
from vertexai import types
from vertexai.preview.reasoning_engines import AdkApp

from enterprise_support_agent import config
from enterprise_support_agent.agent import root_agent
from enterprise_support_agent.logging_setup import init_logging

logger = init_logging()
logging.getLogger().setLevel(logging.INFO)


def deploy() -> str:
    project = config.project_id()
    location = config.location()
    bucket = config.staging_bucket()
    lab_user_id = config.lab_user_id()

    logger.info(
        "vertex_ai_init",
        extra={"json_fields": {"project": project, "location": location, "lab_user_id": lab_user_id}},
    )
    # v1beta1 is required for identity_type=AGENT_IDENTITY (Preview).
    client = vertexai.Client(
        project=project,
        location=location,
        http_options=dict(api_version="v1beta1"),
    )

    app = AdkApp(
        agent=root_agent,
        enable_tracing=True,
        env_vars={
            "GOOGLE_CLOUD_PROJECT": project,
            "GOOGLE_CLOUD_LOCATION": location,
            "AGENT_MODEL": config.model_name(),
            "MODEL_ARMOR_TEMPLATE": config.model_armor_template(),
            "MCP_GATEWAY_URL": os.environ.get("MCP_GATEWAY_URL", ""),
            "AGENT_GATEWAY_URL": os.environ.get("AGENT_GATEWAY_URL", ""),
            "LAB_USER_ID": lab_user_id,
        },
    )

    logger.info("agent_runtime_deploy_starting")
    remote = client.agent_engines.create(
        agent=app,
        config={
            "display_name": config.agent_display_name(),
            "identity_type": types.IdentityType.AGENT_IDENTITY,
            "staging_bucket": bucket,
            "requirements": [
                "google-cloud-aiplatform[adk,agent-engines]>=1.145.0,<2.0.0",
                # GCPSkillRegistry (google.adk.integrations.skill_registry) only
                # exists from 1.34.0 onward — confirmed by inspecting the
                # 1.28-1.33 wheels, which don't ship the module at all. Pinning
                # below that silently falls back to the on-disk SKILL.md with
                # no error, which is the bug this range fixes.
                "google-adk>=1.34.3,<2.0.0",
                "google-cloud-modelarmor",
                "google-cloud-logging",
                "google-cloud-secret-manager",
                "google-auth",
                "opentelemetry-api",
                "requests",
            ],
        },
    )

    resource_name = remote.api_resource.name
    identity = getattr(remote.api_resource.spec, "effective_identity", None)
    logger.info(
        "agent_runtime_deploy_success",
        extra={"json_fields": {"resource": resource_name, "identity": identity}},
    )
    pathlib.Path(".agent_engine_id").write_text(resource_name + "\n")
    if identity:
        pathlib.Path(".agent_identity").write_text(identity + "\n")
        print(f"[AGENT_IDENTITY] {identity}")
    else:
        logger.warning(
            "agent_identity_missing",
            extra={"json_fields": {"hint": "identity_type=AGENT_IDENTITY may not be supported on this API "
                                            "version/region yet; falling back to the shared service agent. "
                                            "`make bind-agent-identity` will skip IAM rebinding."}},
        )
    print(f"\n[DEPLOYS_RESULT] {resource_name}")
    return resource_name


if __name__ == "__main__":
    try:
        deploy()
    except Exception as exc:
        logger.exception("agent_runtime_deploy_failed")
        print(f"DEPLOYMENT FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
