# Lab Guide — Enterprise Support Agent on GEAP, driven from Antigravity IDE

> **Audience:** an engineer running this lab end to end in their own Google Cloud project.
>
> **How this guide works:** you drive the entire lab from **[Antigravity IDE](https://antigravity.google/docs/ide/overview)** — you give the Agent panel high-level intents, it runs the commands, reads the code, queries your Cloud Logs, and reports back. You'll only leave the IDE for a couple of specific moments (browser preview, Cloud Console tabs) which are called out where they come up. Every prompt below is a literal copy-paste into Antigravity's Agent panel.

## What you'll do

1. Wire Antigravity to your Google Cloud project (5 min, one-time)
2. Bring the whole lab stack up
3. Have Antigravity explain the codebase to you
4. Verify the deployment works — and debug it if it doesn't
5. See the agent working live via a Browser Agent walkthrough
6. Make your first change to the runbook — without redeploying
7. Clean up

The whole thing is ~60 minutes. Open [`architecture-overview.html`](./architecture-overview.html) in a browser now for a 2-minute look at what you're about to stand up — the four GEAP pillars (Build, Scale, Govern, Optimize) and the pieces mapped to each.

## Prerequisites

- **Antigravity IDE** installed — see [https://antigravity.google/docs/ide/overview](https://antigravity.google/docs/ide/overview).
- A **Google Cloud project** with billing enabled and permission to enable APIs/create resources.
- `gcloud`, `terraform >= 1.5`, `python3 >= 3.10` available on your machine. Antigravity will invoke these on your behalf — you don't need to run them yourself. If any are missing, Antigravity will tell you and offer the install command.

## Before you begin: pick a lab name (only if sharing a project)

If several engineers are running this lab in the same GCP project (workshop setup), export a short unique suffix so nobody's resources collide. Skip if you're solo.

```bash
export LAB_USER_ID=yourname   # lowercase letters/numbers/hyphens; e.g. "alice"
export GOOGLE_CLOUD_PROJECT=your-gcp-project-id
```

Every prompt below uses `$LAB_USER_ID` and `$GOOGLE_CLOUD_PROJECT` — Antigravity picks them up from the terminal environment.

---

## Step 1 — Wire Antigravity to Google Cloud (5 min, one-time)

To let Antigravity read your Cloud Logs and use Google's own troubleshooting agent (Gemini Cloud Assist), install two MCP servers from the built-in [MCP Store](https://antigravity.google/docs/mcp#antigravity-ide):

1. Click **⋯** at the top of the Agent side panel → **MCP Servers**.
2. Install these two, both authenticate with your local `gcloud` ADC (no extra credentials to manage):
   - **Cloud Logging** — lets Antigravity query your project's logs in natural language.
   - **Gemini Cloud Assist** — gives Antigravity access to `investigate_issue`, `ask_cloud_assist`, and related tools. Think of it as an SRE-shaped subagent that already knows your cloud estate.
3. In a terminal, make sure your ADC is set: `gcloud auth application-default login`.

Verify both work — paste into the Agent panel:
```
Using the Cloud Logging MCP, tell me if there are any severity>=ERROR log entries in project $GOOGLE_CLOUD_PROJECT in the last 24 hours. Then, using Gemini Cloud Assist, ask "what agent runtimes are deployed in this project" and summarize the response.
```

If both return sensibly, you're wired up. From here, when Antigravity says "let me check the logs" it means it — it can actually see them.

---

## Step 2 — Bring the lab up

Clone the repo, open the folder in Antigravity (`File → Open Folder`), open the integrated terminal (`` Ctrl+` ``), then paste this into the Agent panel:

```
Bring up the enterprise support agent lab end to end in project $GOOGLE_CLOUD_PROJECT with LAB_USER_ID=$LAB_USER_ID:

  1. Authenticate: `gcloud auth application-default login` and `gcloud config set project $GOOGLE_CLOUD_PROJECT`.
  2. Create a Python venv at the repo root with `uv venv --seed` (fall back to `python3 -m venv .venv` if uv isn't installed — install uv first: curl -LsSf https://astral.sh/uv/install.sh | sh). Activate it. Install `requirements.txt` from the repo root (NOT enterprise_support_agent/requirements.txt — that's for the MCP container).
  3. Run `make tf-apply LAB_USER_ID=$LAB_USER_ID` in the background. This takes 5–10 min (most of it is a container build). Notify me the moment it finishes.
  4. When it finishes, quote the terraform outputs (gateway URL, staging bucket, resolved lab suffix).

If any step fails, quote the error verbatim, then use the Cloud Logging MCP to check for related errors in the last 15 minutes, then propose a fix as an Implementation Plan — don't retry until I approve the plan.
```

**Why Planning Mode matters here:** if provisioning fails midway, you want Antigravity to *diagnose*, not blindly retry. An Implementation Plan (Antigravity's reviewable artifact for proposed changes) lets you see what it thinks is wrong before it acts.

---

## Step 3 — Get an architectural tour of what you just deployed

While the deploy is running (or right after), paste this into a **new Agent panel conversation**:

```
Give me a walkthrough of this codebase, targeted at an engineer who's about to modify it. Cover:

  1. The three sub-agents in enterprise_support_agent/agent.py: what each is responsible for, and how the least-privilege boundary is enforced (which tools each one is allowed to call).
  2. The runbook in enterprise_support_agent/skills/incident-escalator/SKILL.md: how the agent loads it at runtime and why it's separate from the code.
  3. How Model Armor is wired — both the app-layer callbacks (enterprise_support_agent/callbacks.py) and the network-layer story via Agent Gateway (docs/agent-gateway-setup.md).
  4. Where Sessions and Memory Bank plug in (agent.py's PreloadMemoryTool + generate_memories_callback).
  5. Which files I would touch to add a new backend tool vs. change a runbook step vs. add a new sub-agent.

Reference specific file paths and line ranges as you go. Point out anything that would surprise a first-time reader.
```

This is worth doing before you touch anything — Antigravity has full context on the repo, so its tour is grounded in what's actually there, not what a generic tutorial says should be there.

---

## Step 4 — Verify it works (and debug it if not)

```
Run `make smoke-test LAB_USER_ID=$LAB_USER_ID`. This exercises three scenarios against the deployed agent:
  - Scenario A: happy-path incident remediation
  - Scenario B: prompt injection containment (Model Armor should block)
  - Scenario C: long-term memory recall across sessions

Summarize which scenarios passed/failed, and quote the detail line for anything that failed.

If any scenario failed, DO NOT just retry. Instead:
  1. Use the Cloud Logging MCP to pull `jsonPayload.event="tool_invoked"` entries from the last 15 minutes in $GOOGLE_CLOUD_PROJECT.
  2. Use Gemini Cloud Assist's `investigate_issue` to root-cause the failure — pass it the scenario name and the failure detail.
  3. Correlate what you find against the code (agent.py, callbacks.py, mcp_server.py).
  4. Produce an Implementation Plan naming the root cause and the fix. Don't touch any files until I approve the plan.
```

**What this teaches you:** the debug loop for a deployed agent isn't "read logs OR read traces OR read code" — it's all three at once, correlated. That's exactly what Antigravity + Cloud Logging MCP + Cloud Assist can do inline, without you tab-switching to Cloud Console.

---

## Step 5 — Watch the agent work, live (Browser Agent)

Time to actually see the agent doing what all these tests just verified. Paste this into the Agent panel:

```
Use the Browser Agent to run a live walkthrough of the deployed agent in the Google Cloud Console:

  1. Navigate to https://console.cloud.google.com/gemini-enterprise/agent-registry?project=$GOOGLE_CLOUD_PROJECT.
  2. Find and open the agent named `enterprise_skills_support_agent-$LAB_USER_ID`.
  3. Go to the Playground tab. Send: "Resolve enterprise support ticket INC-101 end-to-end." Wait for the full response.
  4. Switch to the Traces tab and open the run you just created. Describe the tool call sequence — flag which calls happened in parallel batches (Phase 2 should show 3 parallel calls, Phase 3 should show 2).
  5. Switch to the Identity tab — capture the SPIFFE principal string (this is the agent's own cryptographic identity, not a shared service account).
  6. Switch to the Memories tab — note whether any memories exist yet.

Save a browser recording of the entire flow. When done, summarize what you saw at each step.
```

The browser recording becomes an **Antigravity Artifact** — a reusable walkthrough you can hand to a teammate later instead of scheduling a screen-share.

For a hand-authored, narrated walkthrough of each scenario individually, see [`scenario-a.html`](./scenario-a.html), [`scenario-b.html`](./scenario-b.html), and [`scenario-c.html`](./scenario-c.html) (open in a browser).

---

## Step 6 — Make your first change (the "no redeploy" moment)

Change what the deployed agent does — without redeploying it. This is the platform feature the whole lab is really about, and it's the mental model to leave with.

```
Modify the agent's runbook to include one extra bullet in its final summary, and verify the deployed agent picks up the change without any redeploy:

  1. Open enterprise_support_agent/skills/incident-escalator/SKILL.md, find the `## Phase 6 — Present resolution output` section, and add one new bullet under it: "Total elapsed time from ticket receipt to resolution."
  2. Run `make publish-skill LAB_USER_ID=$LAB_USER_ID` — this publishes the updated runbook to GEAP Skill Registry.
  3. Run `make smoke-test LAB_USER_ID=$LAB_USER_ID` again.
  4. Quote the Scenario A final summary from the smoke test output and confirm whether it now includes the elapsed-time bullet I just added.
  5. Explicitly note that we did NOT re-run `make tf-apply` or `make deploy-agent` — the agent binary was never redeployed.
```

The point: **runbook changes are data, not code**. The agent loads its runbook from Skill Registry on every run, so ops teams can change how the agent behaves without any deployment pipeline. Once you internalize this, you'll know which changes are safe to make live and which need a proper deploy — the biggest source of hesitation for teams new to agent platforms.

---

## Step 7 — Clean up

```
Tear down everything I created in this lab:
  1. Run `make tear-down LAB_USER_ID=$LAB_USER_ID` (deletes the deployed Agent Engine instance).
  2. Run `make tf-destroy LAB_USER_ID=$LAB_USER_ID` (deletes the Cloud Run service, Model Armor template, secrets, storage bucket, Artifact Registry repo).
  3. Confirm every resource is gone by using Gemini Cloud Assist to list agent runtimes, Cloud Run services, and secrets matching `*$LAB_USER_ID*` in $GOOGLE_CLOUD_PROJECT — flag anything that survived.
```

If you're sharing a project, everything you created was suffixed with your `LAB_USER_ID`, so this affects only your lab — teammates' resources are untouched.

---

## When to open the Cloud Console yourself

Antigravity's Browser Agent covers most walkthrough moments (Step 5), but there are a few things you'll want to see with your own eyes — either because a screenshot is worth a thousand tool calls, or because the Console UI conveys context that a text summary can't:

| To see this | Open |
|---|---|
| Your agent has its own SPIFFE identity (not a shared service account) | Console → Agent Registry → your agent → **Identity** tab |
| The multi-agent topology graph, generated from real traffic | Console → Agent Registry → your agent → **Topology** tab |
| Model Armor findings + Security Command Center summary for this agent | Console → Agent Registry → your agent → **Security** tab |
| The exact Model Armor template protecting this agent | Console → Security → Model Armor → `enterprise-security-template-$LAB_USER_ID` |
| A specific failed tool call with full request/response | Console → Agent Registry → your agent → **Traces** tab → click the span |
| Persisted long-term memory entries | Console → Agent Registry → your agent → **Memories** tab (populated after Step 5's second Scenario C run) |

You can always ask the Browser Agent to open any of these for you if you'd rather not click.

---

## Troubleshooting

Almost every failure has the same first move — ask Antigravity to correlate the failure across the sources it now has access to. Paste this into the Agent panel:

```
The most recent `make` command failed. Read its terminal output first. Then:
  1. Query Cloud Logging (severity>=ERROR, last 15 minutes, project $GOOGLE_CLOUD_PROJECT) via the Cloud Logging MCP.
  2. Call Gemini Cloud Assist `investigate_issue` with a description of what I was trying to do and what failed.
  3. Cross-reference against the known cases in this troubleshooting section.

Produce an Implementation Plan with the root cause and the proposed fix. Don't edit any files until I approve the plan.
```

Known symptoms worth listing here (the ones above are handled by the prompt):

| Symptom | Fix |
|---|---|
| `pip install` fails with `error: externally-managed-environment` (PEP 668) | You skipped the venv step, or your venv was created with plain `uv venv` (no `--seed`) and `pip` fell through to system pip. Re-run Step 2 exactly. Do NOT use `--break-system-packages`. |
| `python3 -m venv .venv` fails with `ensurepip is not available` | Your Python is missing the venv stdlib module. Either install it (the error names the exact package, e.g. `apt install python3.12-venv`), or use `uv venv --seed` instead — `uv` needs no system packages. |
| `make tf-apply` fails on API enablement | Confirm billing is enabled on the project and you have the Service Usage Admin role. |
| `make smoke-test` fails on Scenario A or B the first time | Cold start after a fresh deploy is sometimes flaky. Re-run once. If it still fails, use the debug prompt above. |
| Scenario C doesn't show recall on the second run | Memory generation is async — bump `SMOKE_TEST_MEMORY_WAIT_SECONDS` (default 15) and rerun. |
| `make tf-apply` says a resource already exists | You already provisioned under this `LAB_USER_ID`. Either reuse it (re-running `tf-apply` is idempotent) or pick a different `LAB_USER_ID`. |
| You want to run this lab in a shared project without touching the shared setup | Pass `manage_shared_infra=false`: `make tf-apply LAB_USER_ID=yourname MANAGE_SHARED_INFRA=false`. See [`terraform/README.md`](../../terraform/README.md). |

---

## Where to learn more

- [`architecture-overview.html`](./architecture-overview.html) — the full picture, organized by GEAP pillar.
- [`scenario-a.html`](./scenario-a.html), [`scenario-b.html`](./scenario-b.html), [`scenario-c.html`](./scenario-c.html) — narrated walkthroughs of each demo scenario.
- [`agent-gateway-setup.md`](./agent-gateway-setup.md) — provisioning the network-layer Model Armor path (optional; skipped by default in this lab).
- [Gemini Enterprise Agent Platform overview](https://docs.cloud.google.com/gemini-enterprise-agent-platform/overview)
- [Agent Development Kit docs](https://adk.dev/)
- [Antigravity IDE overview](https://antigravity.google/docs/ide/overview) and [MCP server integration](https://antigravity.google/docs/mcp)
- [Cloud Logging MCP server reference](https://docs.cloud.google.com/logging/docs/use-logging-mcp)
- [Gemini Cloud Assist MCP reference](https://docs.cloud.google.com/cloud-assist/reference/mcp)
