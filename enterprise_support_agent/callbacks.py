"""Model Armor guards installed as ADK lifecycle callbacks.

This is the APP-LAYER half of defense in depth. The agent does not have to
remember to call Model Armor — ADK runs these callbacks unconditionally on
every model invocation and every tool dispatch, so a jailbroken agent cannot
route around them from inside the agent process.

The NETWORK-LAYER half lives outside this process: once MCP traffic is
routed through an Agent Gateway egress (config.AGENT_GATEWAY_URL — see
docs/agent-gateway-setup.md), the same Model Armor template also inspects
traffic at the gateway, independent of whether this code ran at all. Keep
both — app-layer callbacks catch issues before a tool call is even attempted
and work the same locally or deployed; the gateway layer catches anything
that reaches the network regardless of agent-code correctness.

Reference: https://docs.cloud.google.com/security-command-center/docs/model-armor-overview
Reference: https://docs.cloud.google.com/model-armor/model-armor-agent-gateway-integration
"""
from __future__ import annotations

import json
from typing import Any

from google.adk.models import LlmResponse
from google.api_core.client_options import ClientOptions
from google.cloud import modelarmor_v1
from google.genai import types as genai_types

from . import config
from .logging_setup import event, init_logging

_logger = init_logging()
_client: modelarmor_v1.ModelArmorClient | None = None


def _client_singleton() -> modelarmor_v1.ModelArmorClient:
    global _client
    if _client is None:
        _client = modelarmor_v1.ModelArmorClient(
            client_options=ClientOptions(api_endpoint=config.model_armor_endpoint())
        )
    return _client


def _scan(text: str) -> tuple[bool, str | None, str | None]:
    """Run a Model Armor sanitize_user_prompt scan.

    Returns (blocked, error_message, matched_filter_type).
    """
    request = modelarmor_v1.SanitizeUserPromptRequest(
        name=config.model_armor_template_path(),
        user_prompt_data=modelarmor_v1.DataItem(text=text),
    )
    response = _client_singleton().sanitize_user_prompt(request=request)
    result = response.sanitization_result
    if result.filter_match_state != modelarmor_v1.FilterMatchState.MATCH_FOUND:
        return False, None, None

    matched_filter = None
    for filter_name, filter_result in result.filter_results.items():
        if getattr(filter_result, "match_state", None) == modelarmor_v1.FilterMatchState.MATCH_FOUND:
            matched_filter = filter_name
            break

    error_msg = getattr(result.sanitization_metadata, "error_message", "") or "Prompt blocked by Model Armor"
    return True, error_msg, matched_filter


def _security_exception_response(error_msg: str) -> LlmResponse:
    body = f"SECURITY EXCEPTION: Tool execution blocked by Model Armor.\n\nDetails: {error_msg}"
    return LlmResponse(
        content=genai_types.Content(
            role="model",
            parts=[genai_types.Part(text=body)],
        ),
    )


def _extract_llm_request_text(llm_request: Any) -> str:
    """Flatten the most recent user-side content into a single string for scanning."""
    chunks: list[str] = []
    contents = getattr(llm_request, "contents", None) or []
    for content in contents:
        for part in getattr(content, "parts", []) or []:
            text = getattr(part, "text", None)
            if text:
                chunks.append(text)
    return "\n\n".join(chunks).strip()


def model_armor_input_guard(callback_context, llm_request) -> LlmResponse | None:
    """ADK before_model_callback. Runs before every LLM invocation."""
    text = _extract_llm_request_text(llm_request)
    if not text:
        return None
    try:
        blocked, error_msg, matched_filter = _scan(text)
    except Exception as exc:
        event(_logger, "model_armor_scan_error", stage="before_model", error=str(exc))
        return None
    if blocked:
        event(
            _logger,
            "model_armor_blocked",
            stage="before_model",
            filter_type=matched_filter,
            error_message=error_msg,
            invocation_id=getattr(callback_context, "invocation_id", None),
        )
        return _security_exception_response(error_msg or "Prompt injection detected.")
    return None


def model_armor_tool_guard(tool, args, tool_context) -> dict | None:
    """ADK before_tool_callback. Scans tool arguments before any MCP dispatch."""
    serialized = json.dumps(args, default=str) if args else ""
    if not serialized:
        return None
    try:
        blocked, error_msg, matched_filter = _scan(serialized)
    except Exception as exc:
        event(_logger, "model_armor_scan_error", stage="before_tool", tool=getattr(tool, "name", "?"), error=str(exc))
        return None
    if blocked:
        event(
            _logger,
            "model_armor_blocked",
            stage="before_tool",
            tool=getattr(tool, "name", "?"),
            filter_type=matched_filter,
            error_message=error_msg,
        )
        return {
            "status": "BLOCKED",
            "error": f"SECURITY EXCEPTION: Tool execution blocked by Model Armor. Details: {error_msg}",
        }
    return None
