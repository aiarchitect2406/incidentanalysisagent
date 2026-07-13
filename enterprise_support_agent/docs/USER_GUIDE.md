# Lab Guide — Enterprise Support Agent on GEAP, driven from Antigravity IDE

> **Audience:** an engineer running this lab end to end in their own Google Cloud project.
>
> **How this guide works:** you drive the entire lab from **[Antigravity IDE](https://antigravity.google/docs/ide/overview)**. You give the Agent panel high-level intents; Antigravity reads the codebase, runs `terraform` / `make` / `gcloud` on your behalf, queries your Cloud Logs, and reports back. You'll leave the IDE for two specific moments (opening the ADK Web UI in your browser to interact with the agent, and dipping into Cloud Console for the platform-side view) — both are called out where they come up.

## What you'll do

1. Connect Antigravity to your Google Cloud project and GEAP
2. Bring the lab stack up (Antigravity drives Terraform + agent deploy)
3. Get an architectural tour of the codebase
4. Verify the deployment with three scenario tests — and debug via MCP if anything fails
5. Interact with the deployed agent via **ADK Web UI** (the real dev inner-loop)
6. Optionally: watch the same interaction happen in the **Cloud Console** with the Browser Agent
7. Make your first change to the runbook — without redeploying
8. Clean up

~60–90 minutes end to end. Open [`architecture-overview.html`](./architecture-overview.html) now for a 2-minute look at what you're about to stand up — the four GEAP pillars (Build, Scale, Govern, Optimize) and their pieces.

## Prerequisites

- **Antigravity IDE** installed — see [https://antigravity.google/docs/ide/overview](https://antigravity.google/docs/ide/overview).
- A **Google Cloud project** with billing enabled and permission to enable APIs / create resources.
- **`gcloud`**, **`terraform >= 1.5`**, **`python3 >= 3.10`** available on your machine. Antigravity will invoke these on your behalf. If any are missing, Antigravity will tell you and offer the install command for your OS.

## Before you begin: pick a lab name (only if sharing a project)

If several engineers are running this lab in the **same GCP project** (workshop setup), export a short unique suffix so resources don't collide. Skip if solo.

```bash
export LAB_USER_ID=yourname          # lowercase letters/numbers/hyphens; e.g. "alice"
export GOOGLE_CLOUD_PROJECT=your-gcp-project-id
```

Every prompt below uses `$LAB_USER_ID` and `$GOOGLE_CLOUD_PROJECT` verbatim — Antigravity picks them up from the terminal environment when it shells out. **Use `LAB_USER_ID` consistently across every step below** — the resource names Terraform creates, the ones `make` looks for, and the ones the smoke tests expect all derive from it. Mixing suffixes across steps will break the run.

---

## Step 1 — Connect Antigravity to your Google Cloud project and GEAP

This step is what turns Antigravity from "an IDE that can run commands" into "an IDE that can see and reason about your live GCP estate." Three parts:

### 1a. Authenticate to Google Cloud

In the Antigravity integrated terminal:

```bash
gcloud auth application-default login
gcloud config set project $GOOGLE_CLOUD_PROJECT
```

This sets **Application Default Credentials (ADC)** locally, which is what Antigravity's MCP servers (next step) use to authenticate as you. Anything Antigravity can do in GCP is bounded by the IAM roles on this account.

### 1b. Install the Google Cloud MCP servers from Antigravity's MCP Store

Antigravity has a built-in [MCP Store](https://antigravity.google/docs/mcp#antigravity-ide) — click **⋯** at the top of the Agent side panel → **MCP Servers**. Install these three (all authenticate via ADC — no extra credentials to manage):

| MCP server | What it unlocks |
|---|---|
| **Cloud Logging** | Antigravity can query your project's logs in natural language (`"any ERROR entries in the last 15 min?"`) |
| **Gemini Cloud Assist** | Antigravity gets access to `investigate_issue` and `ask_cloud_assist` — Google's own SRE-shaped troubleshooting agent that already understands your cloud estate |
| **Agent Registry** | Antigravity can list your deployed agents, MCP servers, and skills — the GEAP-specific view of "what exists in this project" |

### 1c. Verify the wiring

Paste into the Agent panel:
```
Confirm you can reach my Google Cloud environment:
  1. Using the Cloud Logging MCP, tell me if there are any severity>=ERROR log entries in project $GOOGLE_CLOUD_PROJECT in the last 24 hours.
  2. Using Gemini Cloud Assist, ask "what agent runtimes and MCP servers are deployed in this project?" and summarize the response.
  3. Using the Agent Registry MCP, list any registered agents or MCP servers matching *$LAB_USER_ID* (if I have LAB_USER_ID set) — there shouldn't be any yet, since we haven't deployed.
```

If all three respond sensibly, you're wired up. From here, when Antigravity says "let me check the logs" or "let me investigate" it means it — those aren't figures of speech, they're real MCP tool calls.

---

## Step 2 — Bring the lab up

Rather than telling you which `make` targets to run in what order, tell Antigravity the outcome and let it figure out the mechanics from the repo. Clone the repo, open the folder in Antigravity (`File → Open Folder`), open the terminal (`` Ctrl+` ``), then paste this:

```
I've just cloned this repo. Get me from here to a fully deployed, working enterprise support agent in project $GOOGLE_CLOUD_PROJECT, with LAB_USER_ID=$LAB_USER_ID.

To do this yourself:
  1. Read the top-level Makefile, terraform/README.md, and enterprise_support_agent/docs/ to understand what needs to happen.
  2. Set up a Python virtualenv at the repo root and install the ROOT requirements.txt (NOT enterprise_support_agent/requirements.txt — that one is for the MCP container, not local dev). Prefer `uv venv --seed` if `uv` is available; fall back to `python3 -m venv .venv` if not. On PEP-668-managed Python (Debian/Ubuntu/macOS Homebrew), do NOT use --break-system-packages under any circumstances — the venv is the fix.
  3. Provision the infrastructure (Terraform under the hood — apis, IAM, Cloud Run for the MCP gateway, Model Armor template, Secret Manager, GCS staging, and finally the ADK agent deployed to Agent Runtime with its own Agent Identity). Use LAB_USER_ID=$LAB_USER_ID so resource names are suffixed and don't collide with any teammates using the same project.

Report progress step by step. Use Planning Mode (produce an Implementation Plan I can review) if you need to make judgment calls I should approve. If anything fails, use the Cloud Logging MCP and Gemini Cloud Assist's `investigate_issue` to root-cause before retrying. When done, tell me the deployed agent's resource name and the MCP gateway URL.
```

**Why intent-based:** the repo has a Makefile with named targets (`tf-apply`, `deploy-agent`, `publish-skill`, etc.) and Terraform code — Antigravity can read those and orchestrate them without you memorizing them. If the Makefile changes tomorrow, this prompt still works. If Antigravity finds a better path (e.g. running `terraform` directly for finer-grained control), fine.

---

## Step 3 — Get an architectural tour of what you deployed

While Step 2 is provisioning (or immediately after), paste into a **new Agent panel conversation**:

```
Give me an architectural tour of this codebase, targeted at an engineer about to modify it. Cover:

  1. The three sub-agents in enterprise_support_agent/agent.py: what each is responsible for, and how the least-privilege boundary is enforced (which MCP tools each is allowed to call).
  2. The runbook in enterprise_support_agent/skills/incident-escalator/SKILL.md: how the agent loads it at runtime and why it's separate from the code.
  3. How Model Armor is wired — both the app-layer callbacks (enterprise_support_agent/callbacks.py) and the network-layer story via Agent Gateway (docs/agent-gateway-setup.md).
  4. Where Sessions and Memory Bank plug in (agent.py's PreloadMemoryTool + generate_memories_callback).
  5. Which files I'd touch to (a) add a new backend tool, (b) change a runbook step, (c) add a new sub-agent.

Reference specific file paths as you go. Flag anything that would surprise a first-time reader.
```

Antigravity has full read access to the repo — its tour is grounded in what's actually there, not what a generic tutorial says should be there.

---

## Step 4 — Verify with the three scenario tests

The repo ships with three end-to-end scenarios. **Each targets a different platform feature — you want all three green.**

```
Run all three scenario tests against the deployed agent (LAB_USER_ID=$LAB_USER_ID):

  - Scenario A — Autonomous Remediation: happy-path incident triage + parallel investigation + auto-remediation + notification handoff. Exercises the multi-agent flow and Skill Registry.
  - Scenario B — Prompt Injection Containment: a ticket with a hidden malicious instruction. Model Armor should block the affected tool calls.
  - Scenario C — Long-Term Memory Recall: same ticket replayed in a brand-new conversation. The second run should reference the first run's fix (proves Memory Bank works).

Read the Makefile if you need to find the target that runs these. Summarize which passed/failed, and quote the detail line for anything that failed.

If any scenario failed, DO NOT just retry. Instead:
  1. Pull `jsonPayload.event="tool_invoked"` from Cloud Logging for the last 15 minutes via the Cloud Logging MCP.
  2. Call Gemini Cloud Assist's `investigate_issue` with a description of the scenario name and the failure.
  3. Correlate what you find against the code.
  4. Produce an Implementation Plan naming the root cause and the fix — don't touch files until I approve.
```

For narrated walkthroughs of what each scenario *should* do, see [`scenario-a.md`](./scenario-a.md), [`scenario-b.md`](./scenario-b.md), and [`scenario-c.md`](./scenario-c.md) (Mermaid diagrams + step tables render inline on GitHub).

---

## Step 5 — Interact with the deployed agent via ADK Web UI

This is where you actually *use* your agent as an engineer would in the dev inner-loop. The **ADK Web UI** is a local web app that gives you a chat interface + an event-by-event trace pane + a graph view of the multi-agent topology. Critically, we point it at your **deployed Agent Runtime instance** so Sessions and Memory Bank are the real production ones — anything the agent remembers here, the deployed agent remembers too, and vice versa.

```
Launch the ADK Web UI locally, pointed at the Agent Runtime instance we just deployed (LAB_USER_ID=$LAB_USER_ID) so Sessions and Memory Bank are shared with the deployed agent. Tell me the local URL to open in my browser.
```

Antigravity will figure out the right invocation (there's a `make web` target that assembles the ADK CLI flags — `adk web --session_service_uri=agentengine://... --memory_service_uri=agentengine://... .` — pointing at the resource in `.agent_engine_id`). It'll then leave the server running in the terminal.

Open the URL it prints (default `http://127.0.0.1:8000`) in your browser and try:

> `Resolve enterprise support ticket INC-101 end-to-end.`

In the ADK Web UI you'll see:
- Left pane: chat conversation
- Right pane: **event stream** — every LLM turn, every tool call, every sub-agent handoff, in order, with request/response payloads
- **Graph tab**: the multi-agent topology drawn from the actual execution
- **Trace tab**: the same events as a Gantt chart, showing which tool calls fired in parallel batches

Send `INC-666` (the injected ticket) and watch Model Armor block the tool call in real time — you'll see the `SECURITY EXCEPTION` in the event stream. Send `INC-101` again from a fresh session (`+ New session`) and watch Memory Bank surface the prior fix.

**Two things to know:**
- The `adk web` server keeps running in the terminal — kill it with `Ctrl+C` when done.
- If you're on **Cloud Shell** instead of a local machine: the URL is still `http://127.0.0.1:8000`, but you can't open it directly. Click **Web Preview** (top-right of Cloud Shell) → **Preview on port 8000**.

**No local terminal at all? (Cloud Shell not an option either)** — skip to Step 6's Browser Agent + Cloud Console walkthrough. The **Playground** tab of Agent Registry gives you a chat interface to the deployed agent from any browser, no local tooling required, but it doesn't show the rich event stream that ADK Web UI does — you'll want to look at the **Traces** tab separately to see what tools fired.

---

## Step 6 — Optional: watch the same interaction in Cloud Console

The ADK Web UI in Step 5 is the developer's view. The Cloud Console shows the same activity from the **platform's** view — Agent Registry tabs for Identity, Topology, Security, Sessions, Memories. Same run, different lens.

If you want a hand-held tour of the Console tabs — and, importantly, a **browser recording as a shareable artifact** — paste this and let the Browser Agent drive:

```
Using the Browser Agent, walk me through my deployed agent in the Cloud Console:
  1. Open https://console.cloud.google.com/gemini-enterprise/agent-registry?project=$GOOGLE_CLOUD_PROJECT and find the agent named `enterprise_skills_support_agent-$LAB_USER_ID`.
  2. Playground tab: send "Resolve enterprise support ticket INC-101 end-to-end", wait for the response.
  3. Traces tab: describe the tool call sequence for that run — flag which ran in parallel (Phase 2 should show 3 parallel calls, Phase 3 should show 2).
  4. Identity tab: capture the SPIFFE principal string.
  5. Memories tab: note whether any memory entries exist.
Save a browser recording of the entire flow as an artifact.
```

The saved recording is reusable — hand it to a teammate later instead of scheduling a screen-share.

---

## Step 7 — Make your first change (the "no redeploy" moment)

The agent's runbook lives in **Skill Registry** — not baked into the container. That means changes to the runbook take effect on the next agent run, with no redeploy of the agent binary. This is the mental model to leave the lab with, and it's easiest to feel by making a small change and watching it appear live.

```
Help me make a small change to the agent's runbook and confirm the deployed agent picks it up WITHOUT any binary redeploy. Pick a small, safe change — for example, adding one bullet to the runbook's final summary section — then:
  1. Show me the diff you're about to apply.
  2. After I approve, publish the updated skill to Skill Registry.
  3. Run a scenario again (Scenario A is easiest) and quote the final-summary section from the new run.
  4. Explicitly confirm we did NOT rebuild the container, redeploy the agent, or run tf-apply — the only thing that changed is the Skill Registry entry.
```

The point isn't the specific edit — it's the loop: **runbook = data, agent = code, redeploys are for code only**. Once you internalize this, you'll know which changes are safe to make live and which need a proper deploy. That's the single most common source of "is this going to break prod?" hesitation for teams new to agent platforms.

---

## Step 8 — Clean up

```
Tear down everything I created in this lab (LAB_USER_ID=$LAB_USER_ID):
  1. Delete the deployed Agent Engine instance.
  2. Destroy the Terraform-managed infra (Cloud Run service, Model Armor template, Secret Manager secrets, GCS staging bucket, Artifact Registry repo).
  3. Confirm everything is gone: use Gemini Cloud Assist and the Agent Registry MCP to list resources matching *$LAB_USER_ID* in $GOOGLE_CLOUD_PROJECT — flag anything that survived.
```

If you were sharing a project, everything you created was suffixed with your `LAB_USER_ID`, so this affects only your lab — teammates' resources are untouched.

---

## When to open the Cloud Console yourself

The Browser Agent in Step 6 covers most walkthroughs, but there are a few things you'll want to see with your own eyes:

| To see this | Open |
|---|---|
| Your agent's own SPIFFE identity (not a shared service account) | Agent Registry → your agent → **Identity** tab |
| The multi-agent topology graph, generated from real traffic | Agent Registry → your agent → **Topology** tab |
| Model Armor findings + Security Command Center summary for this agent | Agent Registry → your agent → **Security** tab |
| The exact Model Armor template protecting this agent | Security → Model Armor → `enterprise-security-template-$LAB_USER_ID` |
| A specific failed tool call with full request/response | Agent Registry → your agent → **Traces** tab → click the span |
| Persisted long-term memory entries (populated after Scenario C runs) | Agent Registry → your agent → **Memories** tab |

You can always ask the Browser Agent to open any of these for you if clicking around isn't your thing.

---

## Troubleshooting

Almost every failure has the same first move — ask Antigravity to correlate the failure across the sources it now has access to. Paste this into the Agent panel:

```
The most recent command failed. Read its terminal output first. Then:
  1. Query Cloud Logging (severity>=ERROR, last 15 minutes, project $GOOGLE_CLOUD_PROJECT) via the Cloud Logging MCP.
  2. Call Gemini Cloud Assist `investigate_issue` with a description of what I was trying to do and what failed.
  3. Cross-reference against the known cases in the troubleshooting section of USER_GUIDE.md.
Produce an Implementation Plan with the root cause and proposed fix. Don't edit any files until I approve.
```

Known cases worth listing here (Antigravity's prompt above covers the rest):

| Symptom | Fix |
|---|---|
| `pip install` fails with `error: externally-managed-environment` (PEP 668) | Venv missing, or venv created with plain `uv venv` (no `--seed`) so `pip` fell through to system pip. Re-run Step 2. Do NOT use `--break-system-packages`. |
| `python3 -m venv .venv` fails with `ensurepip is not available` | Python missing the venv stdlib module. Install the exact package the error names (e.g. `apt install python3.12-venv`), or use `uv venv --seed` instead — `uv` needs no system packages. |
| `terraform apply` fails on API enablement | Confirm billing is enabled and you have Service Usage Admin on the project. |
| Smoke test fails on Scenario A or B on the first run | Cold start after a fresh deploy is sometimes flaky. Re-run once. If it still fails, use the debug prompt above. |
| Scenario C doesn't show recall on the second run | Memory generation is async — bump `SMOKE_TEST_MEMORY_WAIT_SECONDS` (default 15) and rerun. |
| Terraform says a resource already exists | You already provisioned under this `LAB_USER_ID`. Either reuse it (Terraform is idempotent) or pick a different `LAB_USER_ID`. |
| ADK Web UI (Step 5) can't reach the gateway | The `.agent_engine_id` file at the repo root is stale or missing — re-run Step 2's deploy portion, or point `adk web` at the deployed resource explicitly. |
| Shared project, don't want to touch teammates' shared setup | Pass `manage_shared_infra=false` when Antigravity provisions Terraform (see [`terraform/README.md`](../../terraform/README.md)). |

---

## Where to learn more

- [`architecture-overview.html`](./architecture-overview.html) — the full picture, organized by GEAP pillar.
- [`scenario-a.md`](./scenario-a.md), [`scenario-b.md`](./scenario-b.md), [`scenario-c.md`](./scenario-c.md) — narrated walkthroughs of each demo scenario (Mermaid renders inline on GitHub).
- [`agent-gateway-setup.md`](./agent-gateway-setup.md) — provisioning the network-layer Model Armor path (optional; skipped by default).
- [Gemini Enterprise Agent Platform overview](https://docs.cloud.google.com/gemini-enterprise-agent-platform/overview)
- [Agent Development Kit docs](https://adk.dev/)
- [Antigravity IDE overview](https://antigravity.google/docs/ide/overview) and [MCP server integration](https://antigravity.google/docs/mcp)
- [Cloud Logging MCP server reference](https://docs.cloud.google.com/logging/docs/use-logging-mcp)
- [Gemini Cloud Assist MCP reference](https://docs.cloud.google.com/cloud-assist/reference/mcp)
