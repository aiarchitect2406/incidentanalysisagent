"""Central configuration for the enterprise support agent.

Reads from environment variables with optional Secret Manager fallback so
the same code runs unchanged in local dev, CI, and Agent Runtime.
"""
import os
from functools import lru_cache


def _from_env(key: str, default: str | None = None, required: bool = False) -> str:
    val = os.environ.get(key, default)
    if required and not val:
        raise RuntimeError(
            f"Required configuration {key!r} is missing. Set the env var or "
            f"populate it from Secret Manager before starting the agent."
        )
    return val or ""


@lru_cache(maxsize=1)
def _secret(secret_id: str) -> str | None:
    """Fetch a single secret payload from Secret Manager. Returns None on any failure."""
    try:
        from google.cloud import secretmanager
        client = secretmanager.SecretManagerServiceClient()
        name = f"projects/{project_id()}/secrets/{secret_id}/versions/latest"
        return client.access_secret_version(name=name).payload.data.decode("utf-8").strip()
    except Exception:
        return None


def project_id() -> str:
    return _from_env("GOOGLE_CLOUD_PROJECT", required=True)


def lab_user_id() -> str:
    """Per-engineer suffix so concurrent enablement-lab runs in one shared GCP
    project don't collide on resource names (Cloud Run service, Model Armor
    template, Skill Registry skill ID, Agent Engine display name, ...).

    Must match the `lab_user_id` Terraform variable used for the same run —
    see terraform/variables.tf. Empty string means "solo/dev run, no suffix".
    """
    return _from_env("LAB_USER_ID", default="")


def _suffixed(base: str) -> str:
    suffix = lab_user_id()
    return f"{base}-{suffix}" if suffix else base


def agent_display_name() -> str:
    return _suffixed("enterprise_skills_support_agent")


def location() -> str:
    """The location used for Gemini inference. Defaults to `global` — confirmed
    live that gemini-3.5-flash only resolves from there, not regional
    locations like us-central1."""
    return _from_env("GOOGLE_CLOUD_LOCATION", default="global")


def agent_engine_location() -> str:
    """Region that HOSTS the Agent Engine (reasoningEngine) resource itself —
    i.e. the `location=` passed to `vertexai.Client(...)` at deploy time.

    Deliberately separate from location(): Agent Engine hosting must be a
    real supported region (unlike location(), which defaults to `global` for
    the model). Defaults to the literal "us-central1", NOT location() —
    inheriting location()'s default would silently make this "global" too,
    which is not a valid Agent Engine hosting region.
    """
    return _from_env("AGENT_ENGINE_LOCATION", default="us-central1")


def skill_registry_enabled() -> bool:
    """Whether to load the incident-escalator skill from GEAP Skill Registry.

    Defaults to False: on-disk SKILL.md works identically locally and
    deployed with no GCP dependency. Flip to true only once the skill has
    actually been published (scripts/lab/_lib/publish_skill.py) and you
    want live "edit the runbook without redeploying" behavior.
    """
    return _from_env("SKILL_REGISTRY_ENABLED", default="false").lower() in {"1", "true", "yes"}


def model_armor_location() -> str:
    """Model Armor is a regional service. Keep this pinned to a real region even
    when GOOGLE_CLOUD_LOCATION is `global`."""
    return _from_env("MODEL_ARMOR_LOCATION", default="us-central1")


def model_armor_template() -> str:
    return _from_env("MODEL_ARMOR_TEMPLATE", default=_suffixed("enterprise-security-template"))


def model_armor_endpoint() -> str:
    return f"modelarmor.{model_armor_location()}.rep.googleapis.com"


def model_armor_template_path() -> str:
    return (
        f"projects/{project_id()}/locations/{model_armor_location()}/templates/{model_armor_template()}"
    )


_DEFAULT_MCP_GATEWAY_URL = "https://sre-mcp-gateway-xwvzaazqoa-uc.a.run.app"


def mcp_gateway_url() -> str:
    """Resolution order: env var → Secret Manager secret `mcp-gateway-url[-suffix]` → live default."""
    direct = os.environ.get("MCP_GATEWAY_URL")
    if direct:
        return direct
    from_secret = _secret(_suffixed("mcp-gateway-url"))
    if from_secret:
        return from_secret
    return _DEFAULT_MCP_GATEWAY_URL


def mcp_gateway_transport() -> str:
    """`streamable-http` (current mcp_server.py, mounted at `/mcp`) or `sse` (legacy `/sse`).

    Defaults to `streamable-http` — confirmed live against a fresh deploy that
    mcp_server.py's `mcp.run(transport="streamable-http")` only serves `/mcp`;
    the old `sse` default caused every MCP tool call to silently 404 and the
    agent fell back to inventing tool results. Set MCP_GATEWAY_TRANSPORT=sse
    only if pointed at an old gateway still running the legacy transport.
    """
    return _from_env("MCP_GATEWAY_TRANSPORT", default="streamable-http").lower()


def mcp_gateway_requires_auth() -> bool:
    """Whether to attach a Google ID token to MCP requests.

    Defaults to True: the Terraform-provisioned Cloud Run gateway never sets
    --allow-unauthenticated (see terraform/cloud_run.tf) — confirmed live with
    a bare curl returning 403 — so it's always private. This can't be
    controlled via env var at deploy time the way other settings are: this
    function is called from agent.py's module-level `_build_mcp_gateway()`,
    which runs at IMPORT time on the DEPLOYING machine (when
    scripts/lab/_lib/deploy_agent.py does `from enterprise_support_agent.agent import
    root_agent`), not inside the deployed container — so an env var set only
    in AdkApp's env_vars (which only takes effect once the container starts)
    arrives too late; the connection params (with or without an auth header)
    are already frozen and pickled by then. Confirmed live: this exact gap
    caused every deployed-agent MCP call to 403 with no Authorization header
    at all, even after MCP_GATEWAY_REQUIRES_AUTH=true was added to env_vars.
    """
    return _from_env("MCP_GATEWAY_REQUIRES_AUTH", default="true").lower() in {"1", "true", "yes"}


def skill_registry_skill_name() -> str:
    return _from_env("SKILL_REGISTRY_INCIDENT_SKILL", default=_suffixed("incident-escalator"))


def staging_bucket() -> str:
    return _from_env("AGENT_STAGING_BUCKET", default="gs://agent-engine-09292025")
