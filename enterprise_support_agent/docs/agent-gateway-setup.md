# Agent Gateway setup — egress (Agent-to-Anywhere) in front of the MCP gateway

## What this buys you, beyond the app-layer Model Armor callbacks

`callbacks.py`'s `before_model_callback`/`before_tool_callback` are the **app layer** of defense in
depth — they run unconditionally inside the agent process, so a jailbroken agent can't route around
them. Agent Gateway adds the **network layer**: it sits between the agent and the MCP Cloud Run
service, terminates the connection using the agent's own Agent Identity (mTLS, no manual token
minting), enforces IAM/IAP access control on which agents may reach which registered tools, and — the
part most relevant to Scenario B — can run the *same* Model Armor template against egress traffic
independent of whether `callbacks.py` ran correctly. See
[Agent Gateway overview](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/agent-gateway-overview)
and the
[Model Armor + Agent Gateway integration](https://docs.cloud.google.com/model-armor/model-armor-agent-gateway-integration).

This is genuinely separate infrastructure, not a Python import — there is no `agent.py` code change
that "turns on" Agent Gateway. The steps below provision it; `agent.py` just needs `AGENT_GATEWAY_URL`
pointed at the resulting endpoint (`config.agent_gateway_url()` / `mcp_gateway_routes_through_agent_gateway()`).

## Prerequisites

- The MCP server registered in Agent Registry — run `make register-mcp` (or `bash
  scripts/register_mcp_in_agent_registry.sh`) first. Agent Gateway's egress policies are scoped to
  registered endpoints; an unregistered MCP server is denied by default.
- The agent deployed with `identity_type=AGENT_IDENTITY` (`make deploy-agent`, which writes
  `.agent_identity`). Agent Gateway uses that SPIFFE identity as the authorization principal — without
  it you're back to granting the shared Reasoning Engine service agent broad access, which defeats the
  point.
- An existing Model Armor template (`make` already creates `enterprise-security-template[-LAB_USER_ID]`
  as part of the demo chain).

## Steps

1. **Plan the deployment.** Decide ingress vs. egress (we want **Agent-to-Anywhere / egress** — securing
   the agent's outbound calls to the MCP server) and the region (must match where the Model Armor
   template and the registered MCP server live). See
   [Plan your Agent Gateway deployment](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/gateways/set-up-agent-gateway#plan-agw).

2. **Create the gateway resource itself.**
   > ⚠️ **Confirm the exact command before running.** I verified the MCP-server-registration command
   > below (`gcloud agent-registry services create`) against current docs, but could not find a
   > documented, stable `gcloud` command for creating the Agent Gateway resource itself in time for
   > this writeup — it's a Preview surface that may differ by `gcloud` component version. Run
   > `gcloud alpha gemini-enterprise-agent-platform agent-gateways --help` (the command group name may
   > have shipped under a different alpha/beta path by the time you read this) and use whatever it
   > reports, rather than trusting a flag set fabricated here. This is the one step in this whole repo
   > I'm intentionally not giving you copy-paste-able flags for — everything else has been checked
   > against a real wheel, a real REST reference, or a real documented `gcloud` command.

3. **Set up IAP (access control enforcement, on by default).** Start in dry-run mode to validate
   without blocking traffic:
   [Create IAM agent policies](https://docs.cloud.google.com/gemini-enterprise-agent-platform/govern/policies/assign-identity-iam).

4. **Attach the Model Armor template to the egress gateway.** Grant the gateway's service account the
   roles documented in
   [Configure Model Armor on a gateway](https://docs.cloud.google.com/model-armor/model-armor-agent-gateway-integration#configure-model-armor-on-a-gateway):
   ```bash
   gcloud projects add-iam-policy-binding "$GATEWAY_PROJECT_ID" \
     --member="serviceAccount:service-${GATEWAY_PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com" \
     --role="roles/modelarmor.calloutUser"
   gcloud projects add-iam-policy-binding "$GATEWAY_PROJECT_ID" \
     --member="serviceAccount:service-${GATEWAY_PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com" \
     --role="roles/serviceusage.serviceUsageConsumer"
   gcloud projects add-iam-policy-binding "$MODEL_ARMOR_PROJECT_ID" \
     --member="serviceAccount:service-${GATEWAY_PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com" \
     --role="roles/modelarmor.user"
   ```
   Then point the gateway's egress config at `$MODEL_ARMOR_TEMPLATE` (same template name `make` already
   created — see `config.model_armor_template()`).

5. **Grant the agent's identity egress access to the registered MCP server.**
   ```bash
   identity="$(cat .agent_identity)"
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
     --member="principal://${identity}" \
     --role="roles/iap.egressor"
   ```
   (Same `--member=` caveat as `make bind-agent-identity` in the Makefile — verify the exact
   `principal://...` formatting gcloud accepts against
   [Principal identifiers](https://docs.cloud.google.com/iam/docs/principal-identifiers) if this is
   rejected.)

6. **Point the agent at the gateway.** Set `AGENT_GATEWAY_URL` to the egress gateway's endpoint
   (`scripts/deploy_skills_agent.py` already forwards this through as an `AdkApp` env var; redeploy with
   `AGENT_GATEWAY_URL=https://... make deploy-agent`). `agent.py`'s `_build_mcp_gateway()` then routes
   through the gateway and skips minting its own ID token (the gateway handles auth — see
   `_build_connection_params`'s docstring).

## Verifying it's actually in the path

- Console → Agent Registry → your agent → **Topology** tab should now show the Agent Gateway node
  between the agent and the `sre-mcp-gateway` MCP server, not a direct edge.
- Re-run Scenario B (`make smoke-test` or the Playground). The Model Armor block should now also be
  attributable to the gateway in Console → Agent Registry → your agent → **Security** tab, not only to
  the app-layer `model_armor_blocked` Cloud Logging row from `callbacks.py`.
