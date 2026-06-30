# Lab Guide — Enterprise Support Agent on Gemini Enterprise Agent Platform

> **Audience:** an engineer running this lab end to end in their own Google Cloud project.

## Lab overview

You'll deploy a small support-ticket-resolution agent that triages an incident, investigates it across
several mocked enterprise systems (Zendesk, Salesforce, Postgres, Workday, Jira) in parallel, fixes it,
and writes the customer back — while a security layer (Model Armor) and a least-privilege multi-agent
design keep it safe even against a malicious ticket. It's built on Google's **Agent Development Kit
(ADK)** and runs on the **Gemini Enterprise Agent Platform (GEAP)**.

By the end of this lab you will have:
1. Provisioned the infrastructure with Terraform.
2. Verified the deployment with an automated test.
3. Interacted with the running agent directly and watched it work.
4. Cleaned up everything you created.

Before you start, open `architecture-overview.html` in a browser — it shows every piece you're about
to stand up, organized by GEAP's four pillars: **Build** (the agent + its runbook), **Scale** (the
managed runtime, short- and long-term memory), **Govern** (identity and security), **Optimize**
(tracing and logging).

## Prerequisites

- A Google Cloud project with billing enabled, and permission to enable APIs and create resources in it.
- `gcloud` CLI, authenticated: `gcloud auth application-default login`. **Don't have `gcloud`
  installed, or can't install it on this machine?** Skip straight to the **No local `gcloud`?** box
  in Task 1 — everything in this lab also runs from Cloud Shell, with nothing to install.
- `terraform` >= 1.5
- `python3` (3.10+)
- A terminal and an editor. This guide uses **Antigravity IDE** as a worked example — Google's
  agent-first IDE, which gives you an editor, an integrated terminal, and an AI agent panel that can
  run commands and report results back to you — but any terminal + editor works identically for every
  command below.

## Before you begin: naming

If you're running this solo in your own project, skip this. If you're in a **shared project with
other engineers** (e.g. a team workshop), pick a short, unique name — it keeps every resource you
create from colliding with theirs:

```bash
export LAB_USER_ID=yourname   # lowercase letters/numbers/hyphens, e.g. "alice"
```

Every command below that takes `LAB_USER_ID=...` uses this. Omit it entirely for a solo run.

---

## Task 1 — Set up your environment

1. Clone the repo and open the folder in Antigravity IDE (`File → Open Folder`, same workflow as VS Code).
2. Open the integrated terminal (`` Ctrl+` ``).
3. Authenticate and install the Python dependencies needed to run and deploy the agent:
   ```bash
   gcloud auth application-default login
   gcloud config set project YOUR_PROJECT_ID
   export GOOGLE_CLOUD_PROJECT=YOUR_PROJECT_ID

   pip install -r requirements.txt
   ```

> **No local `gcloud`, or no permission to install software on this machine?** Open
> [Cloud Shell](https://console.cloud.google.com) (the terminal icon in the Cloud Console toolbar)
> instead of a local terminal. It has `gcloud`, `python3`, and `terraform` preinstalled and already
> authenticated as you — clone the repo there and run every command in this guide exactly as written,
> from that terminal instead of Antigravity's. The only difference comes up in Task 3, noted there.

**Using Antigravity's Agent panel instead of typing commands yourself:** it can run terminal commands
for you and report back what happened — useful for the longer steps below where you mainly want a
pass/fail summary rather than to watch every log line. For example, you could type into the Agent
panel:

> "Run `gcloud auth application-default login` in the terminal, wait for it to finish, and confirm it
> succeeded."

The rest of this guide shows the raw command for every task — type it yourself, or ask the Agent panel
to run it and summarize the result. Both work the same way; the Agent panel is just a convenience.

---

## Task 2 — Provision the infrastructure

```bash
make tf-apply LAB_USER_ID=$LAB_USER_ID
```

This single command (Terraform under the hood — see `../../terraform/README.md` if you're curious
exactly what it creates and how) sets up:
- A private container service (Cloud Run) that brokers the agent's connections to the mocked backend
  systems
- A security policy (Model Armor template) that screens every model input and tool call for prompt
  injection and jailbreak attempts
- Storage and secrets the agent needs
- The agent itself, deployed to Agent Runtime with its own cryptographic identity (not a shared
  password/key)

It takes a few minutes — most of that is the container build. When it finishes, it prints the gateway
URL and a few other values; you don't need to copy anything down, the next commands read them
automatically.

**Agent panel example:**
> "Run `make tf-apply LAB_USER_ID=alice` in the terminal. It'll take a few minutes — let me know when
> it finishes, whether it succeeded, and paste the final output block."

---

## Task 3 — Verify the deployment

```bash
make smoke-test LAB_USER_ID=$LAB_USER_ID
```

This runs three scenarios against your freshly-deployed agent and reports pass/fail for each:

- **Scenario A — Autonomous Remediation:** the happy path. The agent triages a ticket, investigates it
  across multiple systems in parallel, fixes the issue, and resolves it.
- **Scenario B — Prompt Injection Containment:** a ticket with a hidden malicious instruction embedded
  in it. The agent should refuse to act on the injection, and the platform should block the affected
  tool calls.
- **Scenario C — Long-Term Memory:** the same ticket, replayed in a brand-new conversation. The second
  run should reference the first run's fix instead of starting from scratch.

You should see `🟢 Demo is GO` at the end. If you see ✗ marks instead, check **Troubleshooting** below.

**Agent panel example:**
> "Run `make smoke-test LAB_USER_ID=alice`. Summarize which of the three scenarios passed or failed,
> and quote the detail line for anything that failed."

---

## Task 4 — Interact with the agent yourself

There are three ways to do this. Start with the first — it's the richest and the one you'll likely use
most while exploring the agent's behavior.

### Option A (recommended): ADK Web UI, running locally

This runs the actual agent code on your machine — full Gemini reasoning, real tool calls to your
deployed gateway — while sharing **Sessions and Memory Bank** with the agent you just deployed, so
anything it remembers here, the deployed agent remembers too (and vice versa).

```bash
make web LAB_USER_ID=$LAB_USER_ID
```

Then open the URL it prints (`http://127.0.0.1:8000` by default) in your browser. You get the full ADK
Web UI: a chat pane, an event-by-event trace of every tool call, and a graph view of the multi-agent
topology.

Try: `Resolve enterprise support ticket INC-101 end-to-end.`

> **On Cloud Shell instead of a local machine:** `adk web` still starts the same local server, but
> Cloud Shell can't open `127.0.0.1` in your browser directly — click **Web Preview** (top-right of the
> Cloud Shell toolbar) → **Preview on port 8000** instead.

### Option B: ADK terminal chat, no browser

Same underlying agent and shared memory as Option A, but a plain terminal conversation instead of a
web UI — useful over a remote/SSH-only session, or if you just don't want a browser tab open:

```bash
make run-agent LAB_USER_ID=$LAB_USER_ID
```

### Option C: Google Cloud Console — zero local setup

If you just want to poke at the agent without installing anything locally: open the
[Google Cloud Console](https://console.cloud.google.com), search for **Agent Registry**, and click your
deployed agent (named `enterprise_skills_support_agent-yourname`). Its **Playground** tab is a direct
chat interface to the deployed agent — no terminal, no local Python, nothing to install. It's the
quickest way to fire a quick test message, but Options A/B give you a much richer view of *why* the
agent did what it did.

A few other tabs worth a look while you're there:
- **Traces** — every step the agent took, including which tool calls ran in parallel.
- **Identity** — the agent's own identity, not a shared account.
- **Memories** — empty at first; run the same ticket twice (two different sessions) and a fact appears
  here after the first run.

**If you'd rather not click around manually:** Antigravity's Browser agent can navigate the Console for
you, e.g.:
> "Open the Google Cloud Console, go to Agent Registry, open the agent named
> `enterprise_skills_support_agent-alice`, click the Traces tab, and describe what you see for the most
> recent run."

For a guided, narrated walkthrough of all three scenarios, see `scenario-a.html`, `scenario-b.html`,
and `scenario-c.html` (open them in a browser).

---

## Task 5 — Clean up

When you're done:

```bash
make tear-down LAB_USER_ID=$LAB_USER_ID
make tf-destroy LAB_USER_ID=$LAB_USER_ID
```

This removes everything you created — the deployed agent, the Cloud Run service, the storage and
secrets. It does not affect any other engineer's lab if you're sharing a project (every resource was
suffixed with your `LAB_USER_ID`).

---

## Troubleshooting

| Symptom | What to try |
|---|---|
| `make tf-apply` fails enabling an API | Confirm billing is enabled on the project and you have the Service Usage Admin role. |
| `make smoke-test` fails on Scenario A or B | Re-run it — the very first run after deployment sometimes hits a cold start. If it fails twice, run `make tf-output` and confirm the gateway URL it prints actually resolves (`curl` it). |
| Scenario C doesn't show recall on the second run | Memory generation happens asynchronously after the first session ends — this can occasionally take longer than the test's default wait. Re-run `make smoke-test` once. |
| `make web` / `adk run` can't reach the gateway | Confirm `make tf-apply` and `make smoke-test` both succeeded first — this step assumes the agent is already deployed and the gateway secret already exists. |
| `make tf-apply` says a resource already exists | Someone (maybe you, in an earlier attempt) already created it under the same `LAB_USER_ID`. Either reuse it (re-running `terraform apply` is safe) or pick a different `LAB_USER_ID`. |
| You're sharing a project with others and want to avoid touching their setup | Pass `manage_shared_infra=false`: `make tf-apply LAB_USER_ID=yourname` (see `../../terraform/README.md` for what this controls). |

## Where to learn more

- `architecture-overview.html` — the full picture, organized by GEAP pillar.
- `scenario-a.html`, `scenario-b.html`, `scenario-c.html` — narrated walkthroughs of each demo scenario.
- [Gemini Enterprise Agent Platform overview](https://docs.cloud.google.com/gemini-enterprise-agent-platform/overview)
- [Agent Development Kit docs](https://adk.dev/)
