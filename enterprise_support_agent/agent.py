"""Enterprise Support Agent — production-ready on Gemini Enterprise Agent Platform.

Architecture (matches https://docs.cloud.google.com/architecture/multiagent-ai-system):

  triage_agent  (coordinator, routes to remediation_agent)
      ├── remediation_agent   (loads incident-escalator skill, owns read +
      │                        remediation MCP tools)
      └── notification_agent  (sole owner of zendesk_update_ticket — least
                               privilege at the sub-agent boundary)

Cross-cutting controls, and exactly which GEAP product implements each one:
  * Agent Identity (not a bespoke service-account dance) — scripts/lab/_lib/deploy_agent.py
    creates the Agent Runtime instance with identity_type=AGENT_IDENTITY, so
    auth_provider.py's `fetch_id_token` calls mint tokens bound to this
    agent's own SPIFFE identity/cert rather than a shared Reasoning Engine
    service agent. Falls back to ADC user credentials for local `adk web`.
  * MCP gateway reached via ADK McpToolset directly (Cloud Run +
    minted ID token) — see _build_connection_params below.
  * Skills loaded dynamically from GEAP Skill Registry (google-adk>=1.34.0
    ships GCPSkillRegistry); falls back to on-disk SKILL.md if unreachable
    or the installed ADK release predates 1.34.
"""
from __future__ import annotations

import copy
import pathlib
import sys

from google.adk.agents import Agent
from google.adk.skills import load_skill_from_dir
from google.adk.tools.mcp_tool import McpToolset
from google.adk.tools.mcp_tool.mcp_session_manager import (
    SseConnectionParams,
    StreamableHTTPConnectionParams,
)
from google.adk.tools.skill_toolset import SkillToolset

from . import config
from .auth_provider import id_token_headers_for

# Hardcoded: confirmed live that gemini-3.5-flash only resolves via Vertex's
# "global" location, not regional ones like us-central1 — set
# GOOGLE_GENAI_USE_VERTEXAI=TRUE and GOOGLE_CLOUD_LOCATION=global in the
# process environment (see config.location(), scripts/local/run.sh,
# scripts/lab/_lib/deploy_agent.py) rather than overriding the model client in code.
MODEL = "gemini-3.5-flash"


class _PickleSafeMcpToolset(McpToolset):
    """Excludes unpickleable streams from deepcopy so the toolset survives
    serialization into the Agent Runtime container."""

    def __deepcopy__(self, memo):
        cls = self.__class__
        result = cls.__new__(cls)
        memo[id(self)] = result
        for k, v in self.__dict__.items():
            if k in ("_errlog", "_mcp_session_manager") or isinstance(v, (type(sys.stderr),)):
                setattr(result, k, None)
            else:
                setattr(result, k, copy.deepcopy(v, memo))
        return result

    def __getstate__(self):
        state = self.__dict__.copy()
        state["_errlog"] = None
        state["_mcp_session_manager"] = None
        return state

    def __setstate__(self, state):
        self.__dict__.update(state)
        # Dynamically rebuild connection parameters during deserialization in-cloud.
        # This resolves a critical circular block:
        #   1. Local deployment requires MCP_GATEWAY_REQUIRES_AUTH=false to avoid crashing on local user credentials.
        #   2. But if we pickle that "false" state, the deployed cloud agent has no Auth headers and gets a 403 Forbidden.
        # Re-evaluating _build_connection_params here allows the deployed cloud container to dynamically mint
        # the secure Google ID token using its GCP Metadata Server identity.
        self._connection_params = _build_connection_params(config.mcp_gateway_url())

        from google.adk.tools.mcp_tool.mcp_session_manager import MCPSessionManager
        self._errlog = sys.stderr
        self._mcp_session_manager = MCPSessionManager(
            connection_params=self._connection_params,
            errlog=self._errlog,
            sampling_callback=self._sampling_callback,
            sampling_capabilities=self._sampling_capabilities,
        )


def _build_connection_params(audience: str):
    """Build MCP connection params. Auth: this process mints a Google ID
    token (auth_provider.id_token_headers_for) to satisfy Cloud Run's
    roles/run.invoker check on the private gateway, unless
    MCP_GATEWAY_REQUIRES_AUTH=false (local dev)."""
    transport = config.mcp_gateway_transport()
    needs_manual_auth = config.mcp_gateway_requires_auth()
    if transport == "streamable-http":
        if needs_manual_auth:
            # Headers on StreamableHTTPConnectionParams / SseConnectionParams
            # are plain dicts, not callables — confirmed live via pydantic
            # ValidationError. Minting once means the token (~1hr TTL) isn't
            # refreshed for a very long-lived session, but that's the best
            # fit for what these connection params accept.
            return StreamableHTTPConnectionParams(
                url=f"{audience.rstrip('/')}/mcp",
                headers=id_token_headers_for(audience)(),
            )
        return StreamableHTTPConnectionParams(url=f"{audience.rstrip('/')}/mcp")
    # SSE (legacy).
    if needs_manual_auth:
        return SseConnectionParams(
            url=f"{audience.rstrip('/')}/sse",
            headers=id_token_headers_for(audience)(),
        )
    return SseConnectionParams(
        url=f"{audience.rstrip('/')}/sse",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )


def _build_mcp_gateway() -> _PickleSafeMcpToolset:
    return _PickleSafeMcpToolset(
        connection_params=_build_connection_params(config.mcp_gateway_url())
    )


def _build_skill_toolset() -> SkillToolset:
    """Load the incident-escalator skill.

    Defaults to the on-disk SKILL.md — no GCP dependency, works the same
    locally and deployed. Only attempts GEAP Skill Registry when explicitly
    opted into via config.skill_registry_enabled() (set SKILL_REGISTRY_ENABLED=true
    once the skill has actually been published there — see
    scripts/lab/_lib/publish_skill.py).
    """
    if not config.skill_registry_enabled():
        skills_dir = pathlib.Path(__file__).parent / "skills"
        incident_skill = load_skill_from_dir(skills_dir / "incident-escalator")
        return SkillToolset(skills=[incident_skill])

    try:
        # ADK 1.34+ ships the integration at this path. Earlier 1.x releases
        # didn't ship it at all; either way, ImportError lands us in fallback.
        from google.adk.integrations.skill_registry.gcp_skill_registry import (  # type: ignore
            GCPSkillRegistry,
        )

        class _PickleSafeGCPSkillRegistry(GCPSkillRegistry):
            """GCPSkillRegistry holds a live vertexai.Client (`_client`) whose
            gRPC channel contains an unpicklable `_thread.lock` — confirmed by
            reproducing `cloudpickle.dumps(registry)` locally, which is exactly
            what Agent Engine deploy does to the whole agent tree. Same
            problem, same fix pattern as _PickleSafeMcpToolset above: drop the
            live client before serialization, rebuild it identically to
            GCPSkillRegistry.__init__ on the other side.
            """

            def __deepcopy__(self, memo):
                cls = self.__class__
                result = cls.__new__(cls)
                memo[id(self)] = result
                for k, v in self.__dict__.items():
                    if k == "_client":
                        setattr(result, k, None)
                    else:
                        setattr(result, k, copy.deepcopy(v, memo))
                return result

            def __getstate__(self):
                state = self.__dict__.copy()
                state["_client"] = None
                return state

            def __setstate__(self, state):
                self.__dict__.update(state)
                import vertexai as _vertexai
                self._client = _vertexai.Client(
                    project=self.project_id,
                    location=self.location,
                    http_options={"api_version": "v1beta1"},
                ).aio

        # Skill Registry is a regional service; keep it on us-central1 even if
        # GOOGLE_CLOUD_LOCATION is `global` for the model.
        registry = _PickleSafeGCPSkillRegistry(
            project_id=config.project_id(),
            location="us-central1",
        )
        return SkillToolset(skills=[], registry=registry)
    except Exception as exc:
        import logging
        logging.getLogger(__name__).warning(
            "GCPSkillRegistry unavailable (%s); falling back to local SKILL.md",
            type(exc).__name__,
        )
        skills_dir = pathlib.Path(__file__).parent / "skills"
        incident_skill = load_skill_from_dir(skills_dir / "incident-escalator")
        return SkillToolset(skills=[incident_skill])


# ---- MCP toolset partitioned across sub-agents (least privilege) ------------
_READ_AND_REMEDIATE_TOOLS = {
    "zendesk_get_ticket",
    "zendesk_list_open_tickets",
    "salesforce_get_customer_context",
    "postgres_get_sync_telemetry",
    "workday_get_oncall_engineer",
    "jira_create_bug_ticket",
    "postgres_update_connector_memory",
    "enterprise_trigger_connector_sync",
}
_NOTIFICATION_TOOLS = {"zendesk_update_ticket"}

_remediation_gateway = _build_mcp_gateway()
_remediation_gateway.tool_filter = lambda tool, ctx=None: tool.name in _READ_AND_REMEDIATE_TOOLS

_notification_gateway = _build_mcp_gateway()
_notification_gateway.tool_filter = lambda tool, ctx=None: tool.name in _NOTIFICATION_TOOLS

_skills = _build_skill_toolset()

# ---- Sub-agents -------------------------------------------------------------
notification_agent = Agent(
    name="notification_agent",
    model=MODEL,
    description="Writes customer-facing resolution updates to Zendesk. Sole owner of zendesk_update_ticket.",
    instruction=(
        "You are the customer notification specialist. The remediation agent will hand you "
        "a resolution summary including the ticket_id, the connector ID, the remediation "
        "actions taken, and the verification outcome. Compose a clear customer-facing "
        "message and call `zendesk_update_ticket` with the provided ticket_id, your message "
        "as `comment`, and `status='Resolved'`. Return the tool response verbatim."
    ),
    tools=[_notification_gateway],
)

remediation_agent = Agent(
    name="remediation_agent",
    model=MODEL,
    description="Executes the incident-escalator runbook: triage, escalate, auto-remediate JVM OOM crashes.",
    instruction=(
        "You execute the incident-escalator runbook. First call `load_skill` with "
        "`name='incident-escalator'` to load the procedure. Follow every step in order "
        "using the MCP tools available to you. Each MCP tool takes at most one call per "
        "phase — do not repeat the same tool with the same arguments. After step 7 "
        "(sync retry verification), transfer control to the `notification_agent` "
        "sub-agent with the resolution summary so it can update Zendesk, then produce "
        "a final summary for the human operator."
    ),
    tools=[_remediation_gateway, _skills],
    sub_agents=[notification_agent],
)

# ---- Coordinator ------------------------------------------------------------
triage_agent = Agent(
    name="triage_agent",
    model=MODEL,
    description="Coordinator that routes incoming support requests to the right specialist sub-agent.",
    instruction=(
        "You are the enterprise support coordinator. When the user asks to triage, "
        "investigate, escalate, or resolve any support ticket (e.g. INC-101 or INC-666), "
        "transfer control to the `remediation_agent` sub-agent — it owns the runbook "
        "execution. Do not call MCP tools yourself."
    ),
    sub_agents=[remediation_agent],
)

enterprise_support_agent = triage_agent
root_agent = triage_agent
