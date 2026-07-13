# Scenario B — Prompt Injection Containment

*High-level components and request flow when the agent encounters a malicious ticket.*

**Model:** Gemini 3.5 Flash **·** **Outcome:** Model Armor BLOCK (app + network layer) **·** **Kickoff:** via Antigravity Agent panel or `make smoke-test`

> **The lesson:** the agent did the right thing — it followed the runbook with the legitimate customer email. **The platform still blocked its tool calls** because the malicious payload was sitting in the conversation context, at two independent layers (the agent's own callbacks, and — once Agent Gateway egress is set up — the network layer too). Defense in depth: the agent is not responsible for security; the platform is.

## Diagram

```mermaid
flowchart LR
  classDef user     fill:#dbeafe,stroke:#1e40af,color:#0b1d3a,stroke-width:2px
  classDef agent    fill:#ede9fe,stroke:#6d28d9,color:#2e1065,stroke-width:2px
  classDef gcp      fill:#fef3c7,stroke:#b45309,color:#78350f,stroke-width:2px
  classDef armor    fill:#dc2626,stroke:#7f1d1d,color:#ffffff,stroke-width:3px
  classDef ext      fill:#f1f5f9,stroke:#475569,color:#0f172a,stroke-width:2px
  classDef never    fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:6 4,stroke-width:2px
  classDef obs      fill:#d1fae5,stroke:#047857,color:#064e3b,stroke-width:2px

  USER["Kickoff<br/>Antigravity / make smoke-test"]:::user
  AGENT["Multi-agent System<br/>(context poisoned)"]:::agent
  SKILL["Skill Registry"]:::gcp
  ARMORAPP["Model Armor — APP layer<br/>BLOCKS HERE (1st chance)"]:::armor
  AGW["Agent Gateway — egress<br/>Model Armor — NETWORK layer<br/>BLOCKS HERE TOO (2nd chance)"]:::armor
  MCP["MCP Gateway<br/>(Cloud Run)"]:::gcp
  ZD["Zendesk<br/>(malicious ticket)"]:::ext
  SF["Salesforce<br/>NEVER CALLED"]:::never
  OBS["Security tab<br/>(Model Armor + SCC findings)"]:::obs

  USER -->|"1. Submit ticket"| AGENT
  AGENT -->|"2. Load runbook"| SKILL
  AGENT -->|"3. Fetch ticket"| MCP
  MCP --> ZD
  ZD -. "4. Malicious payload<br/>now in agent context" .-> AGENT
  AGENT -->|"5. Follows runbook<br/>(legit Salesforce call)"| ARMORAPP
  ARMORAPP -->|"6. BLOCKED<br/>poisoned context"| AGENT
  AGENT -. "would have gone here<br/>if app layer missed it" .-> AGW
  AGW -.->|"Salesforce<br/>never reached"| SF
  ARMORAPP -.->|"7. Audit row"| OBS
  AGW -.->|"Audit row"| OBS
  AGENT -->|"8. SECURITY EXCEPTION"| USER
```

## What happens, end-to-end — and where to watch it in Console

| Step | What | Watch in Console |
|:---:|---|---|
| 1 | A ticket whose description contains an injected instruction is submitted. | Playground or Traces tab |
| 2 | Agent pulls the runbook from Skill Registry — same as the happy path. | Traces tab |
| 3 | Agent fetches the Zendesk ticket. The malicious payload now lives in the agent's context. | Traces tab → event content |
| 4 | The agent **follows the runbook correctly** — uses the legitimate sender email, plans a normal Phase 2 investigation. It does **not** fall for the injection. | Traces tab → reasoning text |
| 🛑 **5** | **Model Armor scans the tool call anyway** and refuses to dispatch — app-layer callback first, network-layer Agent Gateway as a second, independent backstop. The platform doesn't trust any tool call from a poisoned context. | Security tab — look for two findings, not one, if Agent Gateway is set up |
| 6 | A structured audit row lands in Cloud Logging with the matched filter and trace ID. | Security tab (or Cloud Logging directly) |
| 7 | The agent halts and returns the verbatim `SECURITY EXCEPTION`. | Playground response / Traces tab final event |

---

*Enterprise Support Agent — L400 demo.*
