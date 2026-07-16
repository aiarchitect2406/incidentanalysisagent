"""Google ID token minting for IAM-gated Cloud Run invocation.

`google.oauth2.id_token.fetch_id_token` resolves via Application Default
Credentials, so *which* identity signs the token depends entirely on how the
caller is deployed — this code doesn't change:
  * Deployed with Agent Identity (scripts/lab/_lib/deploy_agent.py sets
    identity_type=AGENT_IDENTITY): ADC resolves to this agent's own SPIFFE
    identity, and the resulting token is cryptographically bound to its
    auto-rotated X.509 cert — not a shared service account.
  * Deployed without Agent Identity, or before that flag existed: ADC
    resolves to the shared Agent Platform Reasoning Engine service agent
    (`service-PROJECT_NUMBER@gcp-sa-aiplatform-re.iam.gserviceaccount.com`).
  * Local `adk web`: ADC resolves to the developer's own `gcloud auth
    application-default login` user credentials.
In every case, Cloud Run validates the token's audience and the caller's
`roles/run.invoker` IAM binding before forwarding to the MCP gateway
container. Once MCP traffic instead routes through an Agent Gateway (see
docs/agent-gateway-setup.md), this module isn't used at all for that path —
the gateway terminates mTLS using Agent Identity itself.
"""
import google.auth.transport.requests
import google.oauth2.id_token


def id_token_headers_for(audience: str):
    """Return a callable producing fresh Authorization headers for the given audience.

    ADK's StreamableHTTPConnectionParams accepts a callable in `headers`; calling
    it on each request gives us automatic token refresh handled by the google-auth
    library's metadata-server caching.
    """
    request = google.auth.transport.requests.Request()

    def _headers() -> dict[str, str]:
        token = google.oauth2.id_token.fetch_id_token(request, audience)
        return {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        }

    return _headers
