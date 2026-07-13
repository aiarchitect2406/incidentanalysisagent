# Scenario A — Autonomous Remediation

*High-level components and request flow for end-to-end incident resolution.*

**Model:** Gemini 3.5 Flash **·** **Runbook source:** Skill Registry **·** **Kickoff:** via Antigravity Agent panel or `make smoke-test`

## Diagram

```mermaid
flowchart LR
  classDef user    fill:#dbeafe,stroke:#1e40af,color:#0b1d3a,stroke-width:2px
  classDef agent   fill:#ede9fe,stroke:#6d28d9,color:#2e1065,stroke-width:2px
  classDef gcp     fill:#fef3c7,stroke:#b45309,color:#78350f,stroke-width:2px
  classDef model   fill:#fee2e2,stroke:#b91c1c,color:#7f1d1d,stroke-width:2px
  classDef ext     fill:#f1f5f9,stroke:#475569,color:#0f172a,stroke-width:2px
  classDef obs     fill:#d1fae5,stroke:#047857,color:#064e3b,stroke-width:2px

  USER["Kickoff<br/>Antigravity / make smoke-test"]:::user
  AGENT["Multi-agent System<br/>triage · remediation · notification"]:::agent
  SKILL["Skill Registry<br/>(runbook)"]:::gcp
  MODEL["Model Armor (app layer)<br/>+ Gemini 3.5 Flash"]:::model
  AGW["Agent Gateway (egress)<br/>+ Model Armor (network layer)"]:::gcp
  MCP["MCP Gateway<br/>(Cloud Run)"]:::gcp
  BACKENDS["Enterprise systems<br/>Zendesk · Salesforce · Postgres · Workday · Jira"]:::ext
  OBS["Agent Registry tabs:<br/>Traces · Observability"]:::obs

  USER -->|"1. Submit ticket"| AGENT
  AGENT -->|"2. Load runbook"| SKILL
  AGENT <-->|"3. Reason every turn"| MODEL
  AGENT -->|"4. several tool calls<br/>(parallel batches)"| AGW
  AGW --> MCP
  MCP --> BACKENDS
  AGENT -->|"5. Return resolution"| USER

  AGENT -. spans + logs .-> OBS
  AGW   -. spans + logs .-> OBS
  MCP   -. spans + logs .-> OBS
```

## What happens, end-to-end — and where to watch it in Console

| Step | What | Watch in Console |
|:---:|---|---|
| 1 | Kicked off programmatically — via `make smoke-test`, an Antigravity Agent panel prompt, or a message from the Playground tab. | Agent Registry → Playground |
| 2 | The agent system pulls the latest runbook from **Skill Registry** by name. | Traces tab → `load_skill` span |
| 3 | Every reasoning turn passes through **Model Armor** (app-layer callback) before reaching Gemini. Unconditional firewall. | Security tab |
| 4 | The agent issues several MCP tool calls — many in **parallel batches** — through Agent Gateway egress (network-layer Model Armor + Agent Identity mTLS) to the Cloud Run gateway and on to the mocked enterprise systems. Customer SLA fetched, JVM stack trace pulled, on-call identified, Jira bug filed, heap expanded 2GB→4GB, sync retried. | Traces tab → parallel-batch spans; Topology tab → agent ↔ Agent Gateway ↔ MCP edges |
| 5 | Only the **notification sub-agent** writes back to Zendesk (least privilege) and returns the resolution summary. | Traces tab → Author field changes to `notification_agent` |
| ★ | Throughout: every span and tool call lands in **Cloud Trace + Cloud Logging** automatically, surfaced pre-scoped to this agent. | Observability tab |

---

*Enterprise Support Agent — L400 demo.*
