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
    """The location used for Gemini inference. Can be `global` to reach 3.5+ models."""
    return _from_env("GOOGLE_CLOUD_LOCATION", default="us-central1")


def agent_engine_location() -> str:
    """Region that HOSTS the Agent Engine (reasoningEngine) resource itself —
    i.e. the `location=` passed to `vertexai.Client(...)` at deploy time.

    Deliberately separate from location(): Agent Engine hosting must be a
    real supported region, but location() may be set to `global` in projects
    where a Gemini model isn't regionally allowlisted (same reasoning as
    model_armor_location() below, which stays regional for the same
    structural reason). Defaults to location() so behavior is unchanged
    unless a deploy explicitly needs to decouple them.
    """
    return _from_env("AGENT_ENGINE_LOCATION", default=location())


def model_armor_location() -> str:
    """Model Armor is a regional service. Keep this pinned to a real region even
    when GOOGLE_CLOUD_LOCATION is `global`."""
    return _from_env("MODEL_ARMOR_LOCATION", default="us-central1")


def model_name() -> str:
    return _from_env("AGENT_MODEL", default="gemini-3.5-flash")


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

    Defaults to False because the existing gateway is public. Flip to True after
    redeploying with --no-allow-unauthenticated and binding roles/run.invoker.
    """
    return _from_env("MCP_GATEWAY_REQUIRES_AUTH", default="false").lower() in {"1", "true", "yes"}


def agent_gateway_url() -> str:
    """Egress Agent Gateway endpoint fronting the MCP Cloud Run service, once
    provisioned per docs/agent-gateway-setup.md. Empty until then.

    When set, `agent.py` routes MCP traffic through here instead of straight to
    the Cloud Run URL, so Model Armor inspection also happens at the network
    layer (Agent Gateway), not just the app-layer callbacks in callbacks.py.
    """
    return _from_env("AGENT_GATEWAY_URL", default="")


def mcp_gateway_routes_through_agent_gateway() -> bool:
    return bool(agent_gateway_url())


def skill_registry_skill_name() -> str:
    return _from_env("SKILL_REGISTRY_INCIDENT_SKILL", default=_suffixed("incident-escalator"))


def staging_bucket() -> str:
    return _from_env("AGENT_STAGING_BUCKET", default="gs://agent-engine-09292025")
