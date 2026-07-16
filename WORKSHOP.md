# Enterprise Support Agent — Workshop Quickstart

Deploy your own agent, running on Google Cloud, in about 4 minutes.

## Prerequisites

Your instructor has already set up the shared infrastructure (MCP gateway,
Model Armor template, Skill Registry entry). You just deploy YOUR agent
that talks to that shared setup.

You need on your laptop:

- `gcloud` CLI, authenticated: `gcloud auth login && gcloud auth application-default login`
- `python3` (3.10+)
- This repo cloned locally
- 30 seconds to set up a Python virtualenv:

  ```bash
  uv venv --seed && source .venv/bin/activate && pip install -r requirements.txt
  # Or if you don't have uv:
  python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt
  ```

## Deploy your agent (~4 minutes)

Two environment variables, one command:

```bash
export GOOGLE_CLOUD_PROJECT=<the project the instructor gave you>
export LAB_USER_ID=<your first name, lowercase, no spaces>

make lab-deploy
```

What that command does (all visible in the terminal):

1. **Reads the shared MCP gateway URL** from Secret Manager
2. **Creates your own Agent Engine instance** named
   `enterprise_skills_support_agent-<yourname>`
3. **Runs a smoke test** — sends Scenario A (INC-101) and Scenario B (INC-666)
   to your deployed agent and asserts on the tool sequence

Success looks like a green `✅ Your agent is deployed and verified` line at the end.

## Try it interactively

```bash
make lab-web
```

Opens the ADK Web UI at http://127.0.0.1:8000 pointed at your deployed agent.
Try these prompts:

- `Resolve enterprise support ticket INC-101 end-to-end.`
   → watch the multi-agent handoff: triage → remediation → notification. 8 MCP
   tool calls in the right order, some in parallel batches. Ticket resolved.

- `Resolve enterprise support ticket INC-666 end-to-end.`
   → this ticket's description contains a prompt injection. Watch what
   happens — the agent obeys the injection and does the wrong thing. This is
   the *why* for Model Armor at the Agent Gateway (not enabled in this lab —
   the shared template is provisioned so you can inspect it in the Console,
   but it isn't wired into the request path).

## See what happened in the Cloud Console

```bash
make lab-console
```

Prints the exact Console URLs for your agent's Traces tab (see the tool
sequence as spans), Observability tab, and the shared MCP gateway.

## Clean up when you're done

```bash
make lab-teardown
```

Deletes only your Agent Engine instance and staging bucket — every shared
resource is left alone. Safe to run at any time.

---

## Want to understand what the scripts did?

Each script is under 100 lines, single-purpose, with a "GEAP pillar / what it
creates / why" header at the top. Read them in order:

**Admin-only (your instructor ran these before the workshop):**

```
scripts/lab/admin/01-preflight.sh          # Enable APIs
scripts/lab/admin/02-mcp-gateway.sh        # Build + deploy the Cloud Run MCP service
scripts/lab/admin/03-register-mcp.sh       # Agent Registry entry + Model Armor + Secret Manager
scripts/lab/admin/04-publish-skill.sh      # Publish incident-escalator to Skill Registry
```

**Engineer (what `make lab-deploy` chains):**

```
scripts/lab/engineer/05-deploy-agent.sh    # Your Agent Engine instance
scripts/lab/engineer/06-verify.sh          # Smoke test against it
scripts/lab/engineer/99-teardown.sh        # Cleanup — deletes only YOUR resources
```

Python helpers the shell scripts call live under `scripts/lab/_lib/` — you
generally don't need to touch those.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Secret 'mcp-gateway-url' not found` | Ask your instructor if the shared setup ran. |
| `Permission denied` on `deploy-agent` | You need `roles/aiplatform.user` on the project — ask the instructor to grant it. |
| Deploy hangs at "Building..." for >10 min | Cold Cloud Build. Ctrl+C, wait 30s, re-run `make lab-deploy` — it's idempotent. |
| INC-666 scenario doesn't block the injection | Expected in this lab — Model Armor is provisioned but not wired at the request path. See the deck for the "Agent Gateway" story. |
| ADK Web UI can't reach your agent | The `.agent_engine_id` file at the repo root is stale — re-run `make lab-deploy`. |

Everything more advanced: see the full [`README.md`](./README.md) or ask your
instructor.
