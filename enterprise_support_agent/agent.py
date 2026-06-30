"""Enterprise Support Agent — production-ready on Gemini Enterprise Agent Platform.

Architecture (matches https://docs.cloud.google.com/architecture/multiagent-ai-system):

  triage_agent  (coordinator, owns long-term memory via PreloadMemoryTool)
      ├── remediation_agent   (loads incident-escalator skill, owns read +
      │                        remediation MCP tools)
      └── notification_agent  (sole owner of zendesk_update_ticket — least
                               privilege at the sub-agent boundary)

Cross-cutting controls, and exactly which GEAP product implements each one:
  * Model Armor — defense in depth, two layers:
      - App layer (this process): before_model_callback/before_tool_callback
        in callbacks.py, so a jailbroken agent cannot route around the check.
      - Network layer: once MCP traffic is routed through an Agent Gateway
        (config.AGENT_GATEWAY_URL — see docs/agent-gateway-setup.md), the
        same Model Armor template also inspects egress at the gateway,
        independent of whether the app-layer callback ran correctly.
  * Agent Identity (not a bespoke service-account dance) — deploy_skills_agent.py
    creates the Agent Runtime instance with identity_type=AGENT_IDENTITY, so
    auth_provider.py's `fetch_id_token` calls mint tokens bound to this
    agent's own SPIFFE identity/cert rather than a shared Reasoning Engine
    service agent. Falls back to ADC user credentials for local `adk web`.
  * MCP gateway reached via ADK McpToolset, either directly (Cloud Run +
    minted ID token) or via Agent Gateway egress (mTLS handled by the
    gateway using Agent Identity) — see _build_connection_params below.
  * Sessions (short-term) and Memory Bank (long-term) are NOT a custom env
    var — Agent Runtime wires both automatically once deployed. The agent
    has to actually use them: PreloadMemoryTool below retrieves relevant
    memories every turn, and generate_memories_callback persists each
    resolved incident so the next run on the same connector/customer can
    recall it (see Scenario C in smoke_test.py).
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
from google.adk.tools.preload_memory_tool import PreloadMemoryTool
from google.adk.tools.skill_toolset import SkillToolset

from . import config
from .auth_provider import id_token_headers_for
from .callbacks import model_armor_input_guard, model_armor_tool_guard
from .logging_setup import init_logging

init_logging()


async def generate_memories_callback(callback_context) -> None:
    """after_agent_callback on triage_agent: persist this conversation so
    future incidents on the same connector/customer can be recalled by
    PreloadMemoryTool. `adk web`/`adk run` always default to an
    InMemoryMemoryService (recall within the process, not across restarts);
    Agent Runtime defaults to real Memory Bank once deployed — see
    docs/L400-playbook.md Scenario C for how to observe the difference."""
    await callback_context.add_session_to_memory()


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
        from google.adk.tools.mcp_tool.mcp_session_manager import MCPSessionManager
        self._errlog = sys.stderr
        self._mcp_session_manager = MCPSessionManager(
            connection_params=self._connection_params,
            errlog=self._errlog,
            sampling_callback=self._sampling_callback,
            sampling_capabilities=self._sampling_capabilities,
        )


def _build_connection_params(audience: str, *, via_agent_gateway: bool):
    """Build connection params matching the currently deployed gateway transport.

    Two auth paths, picked by whether traffic goes through Agent Gateway:
      * Direct to Cloud Run (no AGENT_GATEWAY_URL configured): this process
        mints a Google ID token itself (auth_provider.id_token_headers_for)
        to satisfy Cloud Run's `roles/run.invoker` check.
      * Via Agent Gateway (see docs/agent-gateway-setup.md): the gateway
        terminates mTLS using the agent's own Agent Identity and forwards to
        the registered MCP server — no manual token minting needed here,
        because authn/authz is Agent Gateway's job, not the agent's.
    """
    transport = config.mcp_gateway_transport()
    needs_manual_auth = config.mcp_gateway_requires_auth() and not via_agent_gateway
    if transport == "streamable-http":
        if needs_manual_auth:
            return StreamableHTTPConnectionParams(
                url=f"{audience.rstrip('/')}/mcp",
                headers=id_token_headers_for(audience),
            )
        return StreamableHTTPConnectionParams(url=f"{audience.rstrip('/')}/mcp")
    # SSE (legacy / current deployed gateway).
    if needs_manual_auth:
        return SseConnectionParams(
            url=f"{audience.rstrip('/')}/sse",
            headers=id_token_headers_for(audience),
        )
    return SseConnectionParams(
        url=f"{audience.rstrip('/')}/sse",
        headers={
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        },
    )


def _build_mcp_gateway() -> _PickleSafeMcpToolset:
    via_agent_gateway = config.mcp_gateway_routes_through_agent_gateway()
    endpoint = config.agent_gateway_url() if via_agent_gateway else config.mcp_gateway_url()
    return _PickleSafeMcpToolset(
        connection_params=_build_connection_params(endpoint, via_agent_gateway=via_agent_gateway)
    )


def _build_skill_toolset() -> SkillToolset:
    """Load skills dynamically from GEAP Skill Registry.

    Falls back to on-disk SKILL.md if the registry is unreachable (no creds,
    skill not yet published, or running on an ADK release without the preview
    integration). The fallback keeps `adk web` runnable during local dev.
    """
    try:
        # ADK 1.34+ ships the integration at this path. Earlier 1.x releases
        # didn't ship it at all; either way, ImportError lands us in fallback.
        from google.adk.integrations.skill_registry.gcp_skill_registry import (  # type: ignore
            GCPSkillRegistry,
        )

        # Skill Registry is a regional service; keep it on us-central1 even if
        # GOOGLE_CLOUD_LOCATION is `global` for the model.
        registry = GCPSkillRegistry(
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
    model=config.model_name(),
    description="Writes customer-facing resolution updates to Zendesk. Sole owner of zendesk_update_ticket.",
    instruction=(
        "You are the customer notification specialist. The remediation agent will hand you "
        "a resolution summary including the ticket_id, the connector ID, the remediation "
        "actions taken, and the verification outcome. Compose a clear customer-facing "
        "message and call `zendesk_update_ticket` with the provided ticket_id, your message "
        "as `comment`, and `status='Resolved'`. Return the tool response verbatim."
    ),
    tools=[_notification_gateway],
    before_model_callback=model_armor_input_guard,
    before_tool_callback=model_armor_tool_guard,
)

remediation_agent = Agent(
    name="remediation_agent",
    model=config.model_name(),
    description="Executes the incident-escalator runbook: triage, escalate, auto-remediate JVM OOM crashes.",
    instruction=(
        "You execute the incident-escalator runbook. First call `load_skill` with "
        "`name='incident-escalator'` to load the procedure. Follow every step in order "
        "using the MCP tools available to you. After step 7 (sync retry verification), "
        "transfer control to the `notification_agent` sub-agent with the resolution "
        "summary so it can update Zendesk. Then produce a final summary for the human "
        "operator."
    ),
    tools=[_remediation_gateway, _skills],
    sub_agents=[notification_agent],
    before_model_callback=model_armor_input_guard,
    before_tool_callback=model_armor_tool_guard,
)

# ---- Coordinator ------------------------------------------------------------
triage_agent = Agent(
    name="triage_agent",
    model=config.model_name(),
    description="Coordinator that routes incoming support requests to the right specialist sub-agent.",
    instruction=(
        "You are the enterprise support coordinator. When the user asks to triage, "
        "investigate, escalate, or resolve any support ticket (e.g. INC-101 or INC-666), "
        "transfer control to the `remediation_agent` sub-agent — it owns the runbook "
        "execution. Do not call MCP tools yourself. Preloaded memories (if any) may "
        "mention a prior incident on the same connector or customer — pass that context "
        "along to remediation_agent so it doesn't re-investigate from scratch."
    ),
    tools=[PreloadMemoryTool()],
    sub_agents=[remediation_agent],
    before_model_callback=model_armor_input_guard,
    after_agent_callback=generate_memories_callback,
)

enterprise_support_agent = triage_agent
root_agent = triage_agent
