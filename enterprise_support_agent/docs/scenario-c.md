# Scenario C — Long-Term Memory Recall

*Two sessions, same incident — what Memory Bank changes about the second one.*

**Feature:** Memory Bank + `PreloadMemoryTool` **·** **Kickoff:** via Antigravity Agent panel or `make smoke-test` (includes Scenario C)

> **The lesson:** Sessions only hold the current conversation — replaying the same ticket in a brand-new session gives the agent zero built-in memory of the first run. Memory Bank is what closes that gap: a fact persisted after the first session, recalled at the start of the second, silently injected into the system instruction before the model ever sees the user's message.

## Diagram

```mermaid
flowchart LR
  classDef user    fill:#dbeafe,stroke:#1e40af,color:#0b1d3a,stroke-width:2px
  classDef agent   fill:#ede9fe,stroke:#6d28d9,color:#2e1065,stroke-width:2px
  classDef gcp     fill:#fef3c7,stroke:#b45309,color:#78350f,stroke-width:2px
  classDef mem     fill:#dbeafe,stroke:#1e40af,color:#0b1d3a,stroke-width:3px
  classDef obs     fill:#d1fae5,stroke:#047857,color:#064e3b,stroke-width:2px

  USER["Kickoff<br/>Antigravity / make smoke-test"]:::user

  subgraph S1["Session 1 (fresh user)"]
    direction TB
    A1["triage_agent<br/>PreloadMemoryTool finds<br/>nothing for this user"]:::agent
    A2["Full investigation,<br/>same as Scenario A"]:::agent
    A3["after_agent_callback:<br/>add_session_to_memory()"]:::agent
  end

  MEM["Memory Bank<br/>(long-term, per user_id + app_name)"]:::mem

  subgraph S2["Session 2 (same user, new session_id)"]
    direction TB
    B1["triage_agent<br/>PreloadMemoryTool retrieves<br/>the Session 1 memory"]:::agent
    B2["Response references<br/>the prior remediation"]:::agent
  end

  OBS["Agent Registry tabs:<br/>Sessions (per-conversation) ·<br/>Memories (cross-session)"]:::obs

  USER -->|"1. Resolve INC-101"| A1
  A1 --> A2
  A2 -->|"2. Resolved"| A3
  A3 -->|"3. persist"| MEM
  USER -->|"4. Resolve INC-101 again<br/>(new session, same user)"| B1
  MEM -->|"5. recall"| B1
  B1 --> B2
  B2 -->|"6. Response mentions<br/>prior fix"| USER

  S1 -. events .-> OBS
  S2 -. events .-> OBS
  MEM -. entries .-> OBS
```

## What happens, end-to-end — and where to watch it in Console

| Step | What | Watch in Console |
|:---:|---|---|
| 1 | First session: a fresh synthetic user resolves INC-101 exactly like Scenario A — no memory exists yet for this user. | Sessions tab → first session |
| 2 | The session ends; `triage_agent`'s `after_agent_callback` calls `add_session_to_memory()`, generating a long-term fact from the conversation. | Memories tab → new entry appears |
| 3 | Second session, same user, brand-new `session_id`: the same prompt is sent again. | Sessions tab → second, separate session |
| 4 | `PreloadMemoryTool` retrieves the memory and silently injects a `<PAST_CONVERSATIONS>` block into the system instruction — it never shows up as its own tool-call event, which is why this scenario asserts on the response text, not a trace span. | Traces tab → no discrete `preload_memory` span, by design |
| 5 | The response references the prior incident/remediation instead of presenting it as brand-new. | Playground response / `smoke_test.py` output |

---

*Enterprise Support Agent — L400 demo.*
