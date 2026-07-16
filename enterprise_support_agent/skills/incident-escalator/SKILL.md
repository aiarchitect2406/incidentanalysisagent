---
name: incident-escalator
description: Multi-phase support incident triage with parallel investigation, P0 engineering escalation, and automatic JVM heap remediation. Issues independent tool calls in parallel within each phase. Prompt-injection defense is enforced by the platform (Model Armor callbacks) and is not the agent's responsibility.
---

# Enterprise Support & Incident Escalation Procedure

> **Security note:** prompt-injection and jailbreak filtering is enforced by Model Armor via `before_model_callback` and `before_tool_callback`. You do **not** need to call any security scan tool. If a malicious payload is detected, the platform halts execution and returns `SECURITY EXCEPTION` automatically.
>
> **Performance note:** **issue every tool call within a phase as a SINGLE parallel batch** (multiple `functionCall` parts in one model response). Phases run sequentially because each phase depends on data produced by the previous one, but tools *within* a phase are independent. Do NOT call them one at a time.

When a support ticket arrives, execute the following five phases in order. Within each phase, call the listed tools in **parallel** — one model response containing multiple function calls.

## Phase 1 — Triage (sequential, 1 tool)
Call `zendesk_get_ticket` with the ticket ID parsed from the user request. From the response capture:
- `customer_email`
- Any connector ID in the subject/description (e.g. `CON-BQ-9812`)

## Phase 2 — Investigation (PARALLEL, 3 tools in one batch)
Issue these three calls in a **single parallel batch** — they have no dependencies on each other:
- `salesforce_get_customer_context(customer_email=...)` — SLA, tier, MRR
- `postgres_get_sync_telemetry(connector_id=...)` — JVM logs and error signature
- `workday_get_oncall_engineer()` — current on-call

## Phase 3 — Engineering response (PARALLEL, 2 tools in one batch)
Once the Phase 2 results are in, issue these two calls in a **single parallel batch**:
- `jira_create_bug_ticket(title, description, assignee)` — file the P0 bug. The description must include the Salesforce SLA, the JVM stack trace from Postgres, and the original Zendesk description. Set `assignee` to the on-call engineer's name returned by Workday.
- `postgres_update_connector_memory(connector_id, new_memory_mb=4096)` — start auto-remediation by expanding JVM heap from 2GB to 4GB. Issue this only if the Postgres telemetry shows `java.lang.OutOfMemoryError`.

## Phase 4 — Verify remediation (sequential, 1 tool)
Call `enterprise_trigger_connector_sync(connector_id)` to manually retry the sync. Verify the returned `status` is `SUCCESS`.

## Phase 5 — Customer notification (handoff)
**Hand off to the `notification_agent` sub-agent** to send the customer-facing message. The notification agent owns the only IAM binding for `zendesk_update_ticket`. Pass it:
- The ticket ID
- The customer-facing resolution summary (root cause, memory expansion 2GB → 4GB, sync verification result, Jira ticket key)

## Phase 6 — Present resolution output
After the notification agent confirms the Zendesk update, summarize the entire incident for the human operator. Include:
- Customer SLA tier and MRR
- The P0 Jira ticket key + assignee
- The automatic remediation (heap 2GB → 4GB, sync retry succeeded)
- The Zendesk ticket's new `Resolved` status

## Required output format
At each step, briefly state which phase you are executing and which tools you are batching. This makes the agent's behavior auditable in the trace view.
