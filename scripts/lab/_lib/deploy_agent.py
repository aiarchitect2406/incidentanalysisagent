"""Deploy the enterprise support agent to Gemini Enterprise Agent Platform Agent Runtime.

This script:
  * Imports the production agent definition (coordinator + sub-agents).
  * Wraps it in AdkApp. Sessions are wired automatically by Agent Runtime
    once deployed — there is no env var or extra plumbing for this.
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

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger("deploy_agent")


# scripts/lab/_lib/deploy_agent.py -> repo root is four parents up.
_REPO_ROOT = pathlib.Path(__file__).resolve().parents[3]
_PACKAGE_DIR = _REPO_ROOT / "enterprise_support_agent"
# extra_packages must be relative to the CURRENT WORKING DIRECTORY, not
# absolute: the SDK tars each path with `tarfile.add(file)` and no `arcname`
# override, so an absolute path produces tar members nested under the full
# filesystem path (e.g. `home/user/.../enterprise_support_agent/...`) instead
# of a top-level `enterprise_support_agent/` package — confirmed by
# inspecting the resulting tarball locally. This script is always invoked via
# `make -C <repo_root> deploy-agent`, so os.getcwd() here IS the repo root.
_PACKAGE_ARG = os.path.relpath(_PACKAGE_DIR, pathlib.Path.cwd())


def _from_env_bool(key: str, *, default: bool) -> bool:
    return os.environ.get(key, str(default)).strip().lower() in ("1", "true", "yes")


def deploy() -> str:
    project = config.project_id()
    location = config.location()  # baked into the container for Gemini inference — may be "global"
    engine_location = config.agent_engine_location()  # hosts the reasoningEngine resource — must be a real region
    bucket = config.staging_bucket()
    lab_user_id = config.lab_user_id()

    logger.info(
        "vertex_ai_init",
        extra={"json_fields": {
            "project": project,
            "engine_location": engine_location,
            "inference_location": location,
            "lab_user_id": lab_user_id,
        }},
    )
    # v1beta1 is required for identity_type=AGENT_IDENTITY (Preview).
    client = vertexai.Client(
        project=project,
        location=engine_location,
        http_options=dict(api_version="v1beta1"),
    )

    # AdkApp reads project/location from the LEGACY google.cloud.aiplatform
    # initializer.global_config singleton at construction time (not from the
    # vertexai.Client instance above, which is a separate, newer client and
    # never touches that global) — confirmed by reading
    # vertexai/preview/reasoning_engines/templates/adk.py's AdkApp.__init__,
    # which does `self._tmpl_attrs["location"] = initializer.global_config
    # .location`. Skipping this call left that global at its untouched
    # default (constants.DEFAULT_REGION, "us-central1", UNLESS something else
    # already nudged it to "global" first — either way, uncontrolled), which
    # gets cloudpickled into `_tmpl_attrs` and baked into the deployed
    # container. At runtime the container's own AdkApp.set_up() constructs
    # its VertexAiSessionService straight from that baked-in location —
    # confirmed live via Cloud Logging: it did NOT match `engine_location`,
    # so every session lookup 404'd with "The ReasoningEngine does not
    # exist" even though the resource genuinely existed in `engine_location`.
    vertexai.init(project=project, location=engine_location, staging_bucket=bucket)

    app = AdkApp(
        agent=root_agent,
        enable_tracing=True,
        env_vars={
            "GOOGLE_CLOUD_PROJECT": project,
            "GOOGLE_CLOUD_LOCATION": "global",
            # agent.py hardcodes the model name itself; this only controls
            # which backend the google-genai client talks to. Set explicitly
            # rather than relying on Agent Engine to set it implicitly.
            "GOOGLE_GENAI_USE_VERTEXAI": "TRUE",
            "MODEL_ARMOR_TEMPLATE": config.model_armor_template(),
            "MCP_GATEWAY_URL": os.environ.get("MCP_GATEWAY_URL", ""),
            # Hardcoded true, not inherited from the deploy script's own env:
            # the shared MCP Cloud Run gateway is deployed with
            # --no-allow-unauthenticated (see scripts/lab/shared/02-mcp-gateway.sh),
            # so it's always private. Without this, the deployed container
            # connects with no ID token, every MCP call gets rejected, and
            # the agent silently has zero MCP tools.
            "MCP_GATEWAY_REQUIRES_AUTH": "true",
            "SKILL_REGISTRY_INCIDENT_SKILL": os.environ.get(
                "SKILL_REGISTRY_INCIDENT_SKILL", config.skill_registry_skill_name()
            ),
            "LAB_USER_ID": lab_user_id,
        },
    )

    # AGENT_IDENTITY is a Preview feature: the deployed container then calls
    # session/memory/model APIs AS the agent's own SPIFFE identity, which
    # needs its OWN IAM grants (not just the shared Reasoning Engine service
    # agent's project-level roles) — confirmed live: session creation failed
    # with a masked 404 ("ReasoningEngine does not exist") until we granted
    # roles/aiplatform.user to the agent's own principal, and that grant
    # alone still wasn't sufficient/hadn't propagated. Defaults OFF so a
    # fresh deploy works out of the box on the shared SA (which already has
    # every IAM grant it needs from terraform/iam.tf); opt in explicitly
    # once you've worked through the full IAM grant set for the identity.
    use_agent_identity = _from_env_bool("AGENT_IDENTITY_ENABLED", default=False)
    agent_engine_config = {
        "display_name": config.agent_display_name(),
        "staging_bucket": bucket,
    }
    if use_agent_identity:
        agent_engine_config["identity_type"] = types.IdentityType.AGENT_IDENTITY

    logger.info("agent_runtime_deploy_starting", extra={"json_fields": {"agent_identity": use_agent_identity}})
    remote = client.agent_engines.create(
        agent=app,
        config={
            **agent_engine_config,
            # Without this, only the pickled agent OBJECT gets uploaded — not
            # the `enterprise_support_agent` package its classes/functions are
            # defined in. cloudpickle serializes module-level objects (our
            # Agent instances, callbacks, the _PickleSafe* wrapper classes) by
            # reference (module path + qualname), not by value, so the
            # deployed container's unpickle step needs to `import
            # enterprise_support_agent` to reconstruct them — confirmed via a
            # real deploy that failed with `ModuleNotFoundError:
            # No module named 'enterprise_support_agent'` without this. Must
            # be a RELATIVE path (see _PACKAGE_ARG comment above) or the same
            # error recurs with a differently-broken tar layout.
            "extra_packages": [_PACKAGE_ARG],
            "requirements": [
                "google-cloud-aiplatform[adk,agent-engines]>=1.145.0,<2.0.0",
                # GCPSkillRegistry (google.adk.integrations.skill_registry) only
                # exists from 1.34.0 onward — confirmed by inspecting the
                # 1.28-1.33 wheels, which don't ship the module at all. Pinning
                # below that silently falls back to the on-disk SKILL.md with
                # no error, which is the bug this range fixes.
                "google-adk>=1.34.3,<2.0.0",
                "google-cloud-secret-manager",
                "google-auth",
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
    # `effective_identity` is populated EITHER WAY — with AGENT_IDENTITY_ENABLED
    # off it's just the shared Reasoning Engine service agent's plain email,
    # not a rebindable SPIFFE principal. Only write .agent_identity (which
    # `make bind-agent-identity` treats as "own identity, needs a fresh IAM
    # binding") when we actually asked for AGENT_IDENTITY — confirmed live:
    # passing the shared SA's email through the principal://-prefixing bind
    # step fails with "is of an unknown type" because it isn't a SPIFFE
    # principal. The shared SA's invoker binding is already Terraform-managed
    # (terraform/iam.tf), so there's nothing to (re)bind in that case.
    identity_file = pathlib.Path(".agent_identity")
    if use_agent_identity and identity:
        identity_file.write_text(identity + "\n")
        print(f"[AGENT_IDENTITY] {identity}")
    else:
        identity_file.unlink(missing_ok=True)
        logger.info(
            "agent_identity_not_used",
            extra={"json_fields": {"hint": "Running on the shared Reasoning Engine service agent "
                                            f"({identity}); its IAM bindings are Terraform-managed, so "
                                            "`make bind-agent-identity` will skip."}},
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
