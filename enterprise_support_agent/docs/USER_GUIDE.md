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
4. Made your first change to the agent's runbook — without redeploying it.
5. Cleaned up everything you created.

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

## Using Antigravity IDE with this lab (optional)

If you're running this in [Antigravity IDE](https://antigravity.google/docs/ide/overview), each task
below has an **▶ Antigravity** callout with a literal prompt to paste into the Agent panel and a note
on which IDE surface fits best. Skip the callouts if you're on a different editor — every task also
works from a plain terminal.

Quick reference for which Antigravity surface to reach for:

| When you want to… | Use… |
|---|---|
| Multi-file change with a reviewable plan first | Agent panel, **Planning Mode** → **Implementation Plan** artifact |
| Small localized edit, fast | Agent panel, **Fast Mode** |
| Draft in place (skill markdown, config value) | **Tab** autocomplete |
| Long-running command while you keep working | Agent panel, delegated to background |
| Verify a change worked in Cloud Console | **Browser Agent** — save the recording as an artifact |
| Debug across code + Cloud Logging + Cloud Trace together | Agent panel, Planning Mode, cross-source prompt (see Troubleshooting) |

The callouts throughout intentionally teach one Antigravity surface at a time so you finish the lab
knowing which lever to pull for which situation, not just how to run the demo.

---

## Task 1 — Set up your environment

1. Clone the repo and open the folder in Antigravity IDE (`File → Open Folder`, same workflow as VS Code).
2. Open the integrated terminal (`` Ctrl+` ``).
3. Authenticate to Google Cloud:
   ```bash
   gcloud auth application-default login
   gcloud config set project YOUR_PROJECT_ID
   export GOOGLE_CLOUD_PROJECT=YOUR_PROJECT_ID
   ```
4. Create a Python virtual environment at the repo root and install the dependencies into it.
   **Pick whichever of these two paths works on your machine:**

   **Option 1 (recommended, works everywhere): [`uv`](https://docs.astral.sh/uv/getting-started/installation/)**
   ```bash
   # One-time install of uv itself, if you don't already have it:
   #   macOS/Linux: curl -LsSf https://astral.sh/uv/install.sh | sh
   #   Windows:     powershell -c "irm https://astral.sh/uv/install.ps1 | iex"
   uv venv --seed                      # creates .venv/ with a real pip inside it (see note below)
   source .venv/bin/activate           # Windows: .venv\Scripts\activate
   pip install -r requirements.txt     # <-- root-level file, NOT enterprise_support_agent/requirements.txt
   ```
   Use `--seed` — plain `uv venv` does not install a `pip` binary into the venv, so after activating
   it a plain `pip install` silently falls through to your *system* pip and hits the exact same PEP
   668 error again. `--seed` avoids that trap. (If you'd rather not use `--seed`, `uv pip install -r
   requirements.txt` also works without it — just don't mix the two, and default to `pip install`
   once `--seed` is used so muscle memory doesn't bite you here or in Tasks 2–5.)

   **Option 2 (stdlib fallback): `python3 -m venv`**
   ```bash
   python3 -m venv .venv
   source .venv/bin/activate           # Windows: .venv\Scripts\activate
   pip install -r requirements.txt     # <-- root-level file, NOT enterprise_support_agent/requirements.txt
   ```
   If Option 2 errors with `ensurepip is not available`, your Python install is missing the venv
   module (common on stripped-down Linux/container images and some Cloud Shell states) — the error
   message itself names the exact package to install, e.g. `sudo apt install python3.12-venv` (the
   version suffix matches your `python3 --version`). No sudo, or it's still not available? Use Option
   1 instead — `uv` needs no system packages at all.

   **Why a venv is required, not `pip install -r requirements.txt` directly?** Modern Python installs
   on Debian, Ubuntu, macOS Homebrew, and corp-managed machines refuse system-wide `pip install`
   (`error: externally-managed-environment`, PEP 668). A venv is the standard fix and works the same
   on every OS. **Do not use `--break-system-packages`** — it silently installs the agent's deps into
   your system Python and can corrupt other tools that depend on those packages.

   Keep the venv activated for every terminal you run subsequent tasks in (`make` shells out to
   `python3`, which picks up whichever one is first on `PATH` — activating the venv puts the venv's
   `python3` first).

   Two similarly-named `requirements.txt` files exist for a reason: the **root** one is for running
   and deploying the agent locally (what you want now); `enterprise_support_agent/requirements.txt`
   is scoped to what gets baked into the MCP gateway container image and is installed *inside* that
   container by Cloud Build — never on your local machine.

> **No local `gcloud`, or no permission to install software on this machine?** Open
> [Cloud Shell](https://console.cloud.google.com) (the terminal icon in the Cloud Console toolbar)
> instead of a local terminal. It has `gcloud`, `python3`, and `terraform` preinstalled and already
> authenticated as you — clone the repo there and run every command in this guide exactly as written,
> from that terminal instead of Antigravity's. The venv step above still applies (Cloud Shell's system
> Python is also PEP-668-managed). The only other difference comes up in Task 3, noted there.

**▶ Antigravity — Agent panel, Fast Mode.** Paste this instead of running the setup steps by hand:
```
Do the following in the integrated terminal, one at a time, waiting for each to finish before starting the next. For each step, tell me whether it succeeded and quote any error verbatim:
  1. gcloud auth application-default login
  2. gcloud config set project $GOOGLE_CLOUD_PROJECT
  3. Create a Python venv at the repo root using `uv venv --seed` (fall back to `python3 -m venv .venv` if uv isn't installed — install uv first if that's the case, from https://astral.sh/uv/install.sh)
  4. source .venv/bin/activate
  5. pip install -r requirements.txt
Do not proceed to the next step if the previous one errored.
```
*You're learning:* Antigravity handles multi-step terminal work and hands you a pass/fail summary
instead of a log wall. Good default for anything with more than one command that has to succeed in
order.

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

**▶ Antigravity — Agent panel, delegated to background.** Paste this so you can keep reading/prep-ing
Task 3 while infra provisions:
```
Run `make tf-apply LAB_USER_ID=$LAB_USER_ID` in the background. Notify me the moment it finishes. If it succeeded, paste the `terraform apply` outputs (gateway URL, secret name, staging bucket). If it failed, quote the first error line + the last 10 lines of output, and check whether the failure is one of the entries in the Troubleshooting section of this doc.
```
*You're learning:* long provisioning runs shouldn't lock your session. Antigravity's async execution
model runs it in the background and pings you when done — same pattern applies to `make smoke-test`
or any long `gcloud` command.

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

**▶ Antigravity — Agent panel, Fast Mode (happy path).** Paste:
```
Run `make smoke-test LAB_USER_ID=$LAB_USER_ID`. Summarize which of Scenarios A, B, and C passed or failed, and quote the detail line for anything that failed.
```

**▶ Antigravity — Agent panel, Planning Mode (if something fails).** Paste this only if a scenario
failed above:
```
`make smoke-test` failed. Read the terminal output first, then correlate against Cloud Logging (jsonPayload.event="tool_invoked" AND severity>=WARNING, last 15 minutes, project $GOOGLE_CLOUD_PROJECT), then read the last Cloud Trace for the deployed agent (resource name in .agent_engine_id). Produce an Implementation Plan naming the root cause and the fix — don't edit any files until I approve the plan.
```
*You're learning:* debugging a deployed agent is a cross-source problem — you need code + logs +
traces together. The Planning Mode + Implementation Plan artifact keeps Antigravity from silently
"fixing" the wrong thing; you get a written proposal you can accept, comment on, or reject.

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

**▶ Antigravity — Browser Agent (Console walkthrough as an artifact).** Paste this to drive the
Console tour without clicking manually — and, importantly, capture the whole thing as a **browser
recording** you can play back later or share with a teammate:
```
Open https://console.cloud.google.com/gemini-enterprise/agent-registry in Chrome. Find and click the agent named `enterprise_skills_support_agent-$LAB_USER_ID`. Then:
  1. Playground tab: send "Resolve enterprise support ticket INC-101 end-to-end", wait for the response.
  2. Traces tab: click the run you just created; list the tool call sequence and flag any that ran in parallel batches (Phase 2 should show 3, Phase 3 should show 2).
  3. Identity tab: capture the SPIFFE principal string.
  4. Memories tab: capture whether any memory entries exist yet.
Save a browser recording of the whole flow as an artifact.
```
*You're learning:* the "walkthrough" of your deployed lab is now a reproducible artifact — send the
recording to a colleague instead of scheduling a screen-share. Same pattern works for any Cloud
Console flow (verifying a Cloud Run deploy, checking a Model Armor block, etc).

For a narrated, hand-authored walkthrough of all three scenarios, see `scenario-a.html`,
`scenario-b.html`, and `scenario-c.html` (open them in a browser).

---

## Task 5 — Make your first change (the "no redeploy" moment)

Everything you've done so far runs an agent you deployed. Now change what that agent does — in a way
that most first-time GEAP engineers assume requires rebuilding and redeploying, but doesn't. This is
the mental model to leave the lab with.

The change: add one sentence to the runbook's final summary. Edit
`enterprise_support_agent/skills/incident-escalator/SKILL.md`, find the `## Phase 6 — Present
resolution output` section, and add one bullet — e.g.:
```
- Total elapsed time from ticket receipt to resolution.
```
Then republish the skill and re-run a scenario:
```bash
make publish-skill LAB_USER_ID=$LAB_USER_ID
make smoke-test LAB_USER_ID=$LAB_USER_ID   # or fire a Playground message
```

The next agent run should include your new bullet in its final summary. **You did not redeploy the
agent** (no `make tf-apply`, no `make deploy-agent`) — the runbook lives in Skill Registry, which the
agent fetches on every run. That's the platform feature this whole lab is built to demonstrate.

**▶ Antigravity — Tab + Agent panel, Fast Mode.** Two ways to do this in Antigravity:

- *Editing the SKILL.md:* open it in the editor and use **Tab** to draft the new bullet — Tab
  autocompletes in the surrounding markdown style. Faster than typing.
- *Publishing + verifying:* paste this into the Agent panel after saving the edit:
  ```
  Run `make publish-skill LAB_USER_ID=$LAB_USER_ID`, then `make smoke-test LAB_USER_ID=$LAB_USER_ID`. When smoke-test finishes, quote the Scenario A final summary section from the output and confirm whether it includes the new "elapsed time" bullet I just added to Phase 6 of SKILL.md.
  ```

*You're learning:* runbook changes ≠ code changes ≠ redeploys. On GEAP, the agent is code, the
runbook is data, and the platform composes them at runtime. Once you internalize this you'll know
which changes are safe to make live and which need a deploy — the single most common source of
"is this going to break prod?" hesitation for teams new to agent platforms.

---

## Task 6 — Clean up

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

**▶ Antigravity — first line of defense before you scan the table.** Any `make` command failing?
Paste this into the Agent panel:
```
The most recent `make` command in this terminal failed. Read its output, then check for related errors in Cloud Logging (severity>=ERROR, last 10 minutes, project $GOOGLE_CLOUD_PROJECT), then cross-reference against the Troubleshooting table in enterprise_support_agent/docs/USER_GUIDE.md. Tell me which known symptom this matches, or — if it's not in the table — produce an Implementation Plan naming the root cause and the fix without editing files yet.
```
The manual table below covers the common cases in one place, but the prompt above is a good first
swing at anything unusual — it correlates logs + code + doc automatically.

| Symptom | What to try |
|---|---|
| `pip install -r requirements.txt` fails with `error: externally-managed-environment` (PEP 668) | You skipped the venv step in Task 1, or you're inside a venv created with plain `uv venv` (no `--seed`) and `pip` fell through to the system one. See Task 1 for the two options. Do NOT use `--break-system-packages`. |
| `python3 -m venv .venv` fails with `ensurepip is not available` | Your Python is missing the venv stdlib module. Run the exact `apt install python3.X-venv` command the error message names (it includes your Python's version), or use `uv venv --seed` instead (needs no system packages). |
| `ModuleNotFoundError: No module named 'google.adk'` (or similar) when `make` runs a script | The venv isn't activated in this terminal — run `source .venv/bin/activate` and retry. Every new terminal needs it. |
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
