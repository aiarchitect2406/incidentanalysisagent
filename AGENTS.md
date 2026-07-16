# AGENTS.md — instructions for AI coding assistants

Read this before editing anything. It captures what would take an unaided
AI agent hours (and several broken deploys) to rediscover.

## What this project is

A hands-on enablement lab that stands up a multi-agent incident-triage system
on Google's Gemini Enterprise Agent Platform (GEAP). Three agents (`triage →
remediation → notification`) resolve a mocked support ticket end-to-end,
calling mocked backends (Zendesk, Salesforce, Postgres, Workday, Jira) via an
MCP gateway on Cloud Run. Designed to be deployed by 5–15 engineers at once
in one shared GCP project.

Primary users:
- **Engineers** run `make lab-deploy` — creates only their own Agent Engine.
- **The instructor** runs `make lab-admin-setup` once — creates the shared MCP
  gateway, Skill Registry entry, Agent Registry entry, Model Armor template.
- **Solo devs** run `make local` — no GCP deploy, all on localhost.

## The two-stage workshop model — most important thing to understand

Shared vs. per-engineer is enforced by directory structure, not by flags:

- `scripts/lab/admin/`    → shared resources (unsuffixed names, one per project)
- `scripts/lab/engineer/` → per-engineer resources (suffixed with `$LAB_USER_ID`)

The engineer scripts **read shared resources from Secret Manager**
(`mcp-gateway-url`), so no engineer ever needs to know or paste a URL. The
teardown scripts are safe by construction — `admin/99-teardown.sh` cannot be
run from engineer flow, and `engineer/99-teardown.sh` deletes only that
engineer's own Agent Engine + staging bucket.

**Never re-introduce a `LAB_USER_ID` suffix on the MCP gateway, Model Armor
template, or Skill Registry entry.** Those are shared. Only the Agent Engine
display name and per-engineer staging bucket get suffixed.

## Directory layout

```
enterprise_support_agent/       Python package that IS the agent
├── agent.py                    triage/remediation/notification wired together
├── config.py                   central config (env vars + Secret Manager fallback)
├── auth_provider.py            Google ID-token minting for IAM-gated Cloud Run
├── mcp_server.py               FastMCP server (runs in the Cloud Run gateway)
├── skills/incident-escalator/SKILL.md   the runbook, published to Skill Registry
├── toolspec.json               MCP tool metadata for Agent Registry
├── evals/                      eval set
└── docs/                       user-facing docs + workshop-deck.html

scripts/
├── console-urls.sh             prints Cloud Console URLs (make lab-console)
├── lab/
│   ├── admin/                  INSTRUCTOR: make lab-admin-setup
│   ├── engineer/               EACH ENGINEER: make lab-deploy
│   └── _lib/                   Python helpers the shell scripts call
└── local/
    └── run.sh                  make local — MCP + adk api_server on localhost

tests/
├── smoke_test.py               end-to-end against deployed agent
└── eval_run.py                 ADK evaluation harness

terraform/                      LEGACY — scheduled for deletion once
                                make lab-admin-setup proves out. Do not
                                add new features here.

WORKSHOP.md                     single-page engineer quickstart
```

## Facts you must know before touching code

### 1. The model requires two env vars, not one

`agent.py` hardcodes `MODEL = "gemini-3.5-flash"`. That model **only resolves
via Vertex's `global` location**, not from regional locations like
us-central1. Confirmed live: a real regional call 404s.

The process running the agent needs both:
- `GOOGLE_GENAI_USE_VERTEXAI=TRUE`  (tells google-genai to use Vertex, not AI Studio)
- `GOOGLE_CLOUD_LOCATION=global`     (config.location() default)

Both are set in `scripts/local/run.sh` and by `scripts/lab/_lib/deploy_agent.py`.
Do not "clean up" either into a subclass, custom `Gemini` client, or config
default — we already deleted that machinery and it made things worse.

### 2. `mcp_server.py` used to deadlock silently

Historical bug: `logging_setup.py` (now deleted) attached a `CloudLoggingHandler`
to the root logger. When `mcp.run()` started uvicorn, uvicorn's
`configure_logging()` called `logging.shutdown()`, which flushed the Cloud
Logging handler's background thread — that thread's gapic client construction
logged through the same locked logging machinery. Deadlock. Silent. Zero
output, no port bound.

**Do not add `google.cloud.logging.Client().setup_logging()` back anywhere.**
The current code uses stdlib `logging` with plain `basicConfig` — Cloud Run
and Agent Engine natively parse stdout JSON as `jsonPayload`.

### 3. Agent Engine deploy pickling requires `_PickleSafeMcpToolset`

`agent.py`'s `_PickleSafeMcpToolset` (subclass of `McpToolset`) exists because
`cloudpickle.dumps()` — which is what Agent Engine's deploy does to the whole
agent tree — fails on the MCP toolset's live streams (`_errlog`,
`_mcp_session_manager`). The subclass drops them for serialization and
rebuilds them in `__setstate__`. Same pattern applies to `GCPSkillRegistry`
inside `_build_skill_toolset()`.

**If deploy starts failing with pickle errors on a new field, extend
`__deepcopy__`/`__getstate__`/`__setstate__` — do not remove the wrapper.**

### 4. Model Armor is not wired into the request path in this lab

The `03-register-mcp.sh` script **creates** the Model Armor template so it's
visible in the Console. But no code reads it. Enforcement would require Agent
Gateway, which this lab intentionally does not provision (Preview surface,
skipped).

Consequence: **Scenario B (INC-666, prompt injection) does not block anything
in this lab.** The agent falls for the injection. This is a known, intentional
gap — do not try to fix Scenario B by:
- Adding an in-process `before_tool_callback` Model Armor scan (we tried, it
  was pure dead code with no permission in the dev project).
- Prompt-engineering the agent to refuse injections (fragile, unclear teaching value).

If you want to genuinely fix Scenario B, provision Agent Gateway. That's a
separate 30-minute chunk of work.

### 5. Model Armor SDK/CLI is blocked by Context-Aware Access in the dev project

In `cloud-llm-preview1`, both `gcloud model-armor` and the Python
`ModelArmorClient.sanitize_user_prompt` / `create_template` return 403
PermissionDenied. This is NOT a code bug. Do not chase it. If you must
verify Model Armor changes, do it in a project where you have the right IAM.

### 6. Do NOT add tracing / logging / callbacks wrapper modules

Agent Engine already emits OTel spans to Cloud Trace (`enable_tracing=True`
in `AdkApp` is already set in `deploy_agent.py`) and Cloud Logging parses
stdout automatically. Locally, ADK's own INFO logs already show every LLM
turn (`Sending out request`), every MCP dispatch (`POST /mcp`), and the mock
backends log every `tool_invoked`.

We deleted these three redundant layers already — do not re-add them:
- `enterprise_support_agent/tracing.py`  (duplicated OTel)
- `enterprise_support_agent/callbacks.py`  (duplicated Model Armor at Agent Gateway)
- `enterprise_support_agent/logging_setup.py`  (duplicated stdlib logging + caused #2)

### 7. Cloud Run is IAM-gated; the deployed agent needs an ID token

The MCP gateway is `--no-allow-unauthenticated`. `agent.py`'s
`_build_connection_params` calls `auth_provider.id_token_headers_for(audience)()`
to mint a Google ID token for the Cloud Run URL. That token is minted ONCE at
agent-import time (StreamableHTTPConnectionParams.headers only accepts a
plain dict, not a callable — confirmed via pydantic ValidationError). So it
has ~1hr TTL against a long-lived session; acceptable trade-off.

`MCP_GATEWAY_REQUIRES_AUTH=false` (set only by `scripts/local/run.sh`) skips
the token minting for the local MCP server.

### 8. `location` vs. `agent_engine_location` — do not conflate

- `config.location()` — model inference location, defaults to `"global"`
- `config.agent_engine_location()` — reasoningEngine hosting region, defaults
  to the literal `"us-central1"`

If you set the second to `location()` (they used to inherit), it silently
becomes `"global"`, which is NOT a valid Agent Engine hosting region.
Session lookups will 404 with masked "ReasoningEngine does not exist" errors.
Keep them decoupled.

### 9. `tests/smoke_test.py` has a required SDK workaround

`_wrap_bidi_stream_query_operation` in `google-cloud-aiplatform` 1.156-1.161
has a bug that silently breaks stream_query registration for AdkApp. The
monkey-patch at the top of `smoke_test.py` fixes it. If you upgrade the SDK,
verify the bug is fixed before removing the patch.

## How to run things

### Local dev (no GCP deploy)
```bash
export GOOGLE_CLOUD_PROJECT=<any project you have access to>
make local
# opens MCP on :8080, adk api_server on :8000
```

### Deploy your agent to a real project
```bash
# Instructor once:
export GOOGLE_CLOUD_PROJECT=<workshop project>
make lab-admin-setup

# Each engineer:
export GOOGLE_CLOUD_PROJECT=<workshop project>
export LAB_USER_ID=<yourname>
make lab-deploy      # deploy YOUR Agent Engine (no auto-smoke)
make lab-web         # ADK Web UI (recommended)
make lab-try-a       # Scenario A via terminal, pretty-printed
make lab-try-b       # Scenario B (prompt injection, does NOT block)
make lab-check       # headless smoke test with pass/fail
make lab-teardown    # cleanup
```

### Verify a change end-to-end
There is no unit test suite. Run:
```bash
make local     # or `make lab-deploy` for the deployed path
# then in another terminal:
curl -s -X POST http://127.0.0.1:8001/apps/enterprise_support_agent/users/u/sessions/s \
  -H 'Content-Type: application/json' -d '{}'
curl -s -X POST http://127.0.0.1:8001/run -H 'Content-Type: application/json' -d '{
  "app_name":"enterprise_support_agent","user_id":"u","session_id":"s",
  "new_message":{"role":"user","parts":[{"text":"Please resolve INC-101 end-to-end."}]}
}'
```
Expect 11 tool calls in order: `transfer_to_agent, load_skill, zendesk_get_ticket,
salesforce_get_customer_context, postgres_get_sync_telemetry,
workday_get_oncall_engineer, jira_create_bug_ticket, postgres_update_connector_memory,
enterprise_trigger_connector_sync, transfer_to_agent, zendesk_update_ticket`.

## Conventions

- **Numbered scripts.** `01-preflight.sh` → `06-verify.sh`. Order is the lab.
- **`_lib/` = internal helpers.** Engineers rarely open these. Leading underscore
  is a soft "don't-touch-me" signal, not enforced.
- **Every lab script starts with a header block** naming the GEAP pillar and
  what it creates. Keep this format when adding scripts.
- **Console URLs come from `scripts/console-urls.sh`**, not hardcoded in docs.
- **Every script sources `scripts/lab/_lib/_common.sh`** for `banner`, `info`,
  `ok`, `warn`, `die`, `require_env`, `require_cmd`, `SHARED_*` constants.
- **No app-layer security callbacks.** Security belongs at Agent Gateway.
- **Don't add comments explaining WHAT code does.** Only WHY, and only when
  non-obvious. Do NOT add a "for the X flow" comment or link to a PR/issue.
- **Don't add unit test suites** unless asked. The lab's verification is the
  smoke test — end-to-end tool-sequence assertions against a real deployed
  or local agent.

## Common task patterns

### "Add a new tool to the agent"
1. Add the `@mcp.tool()`-decorated function in `enterprise_support_agent/mcp_server.py`.
2. Add its annotation entry in `enterprise_support_agent/toolspec.json`.
3. Add it to `_READ_AND_REMEDIATE_TOOLS` (or `_NOTIFICATION_TOOLS`) in `agent.py`.
4. Update `enterprise_support_agent/skills/incident-escalator/SKILL.md` if the
   runbook should call it.
5. Redeploy: `bash scripts/lab/admin/02-mcp-gateway.sh` (rebuild image),
   `bash scripts/lab/admin/03-register-mcp.sh` (update toolspec in Agent
   Registry). Engineers do NOT need to redeploy their agents unless
   `agent.py` changed.

### "Change the runbook"
1. Edit `enterprise_support_agent/skills/incident-escalator/SKILL.md`.
2. Instructor runs `bash scripts/lab/admin/04-publish-skill.sh`.
3. Next agent run picks up the change. **No agent redeploy needed** — this
   is the "runbook = data" point of the lab.

### "Add a new sub-agent"
1. Add `Agent(name=..., ...)` in `agent.py`.
2. Add its MCP tool filter (a set + `tool_filter` lambda on a fresh
   `_build_mcp_gateway()` clone).
3. Add it to the parent agent's `sub_agents=[...]` list.
4. Update the parent's `instruction=` so it knows when to transfer.

### "Debug a failing local run"
1. Check `/tmp/*.log` — `run.sh` writes to `/tmp/mcp*.log` and stdout of
   the api_server.
2. `ADK's own INFO logs` show every LLM turn and MCP dispatch — do not
   add wrappers.
3. Common gotcha: **stale processes.** `pkill -9 -f "mcp_server|adk api_server|run.sh"`,
   confirm `ss -ltn | grep :800` is empty before restarting.
4. Never write a "polling" loop expecting the model to be fast. Vertex
   `gemini-3.5-flash` can take up to 5 minutes to respond on prompts with
   very long context. Use `--max-time 300` on curl at minimum.

## Terraform status

`terraform/` still exists but is legacy. Scheduled for deletion once
`make lab-admin-setup` is proven out end-to-end. If you're adding new
provisioning, add it to `scripts/lab/admin/`, not to Terraform. Do not
port existing scripts into Terraform.

## What's intentionally NOT in this repo

- App-layer prompt-injection callbacks (deleted, reasons above)
- Long-term Memory Bank / `PreloadMemoryTool` / Scenario C (deleted — was
  fragile, docs oversold it, and the model wouldn't quote recalled memory
  back to users reliably)
- Agent Gateway provisioning (Preview surface, exact `gcloud` command
  unverified; will be added when access + confirmed docs are available)
- Custom OTel / Cloud Logging wrappers (Agent Engine + Cloud Run give this
  natively)
- Custom Gemini model client (env vars do the same thing for free)
- A unit test suite (smoke test against real deploy is the verification)

Any AI agent that finds itself about to add one of the above should stop
and re-read this file — someone already tried and it was net-negative.
