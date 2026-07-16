# Shared helpers for scripts/lab/**/*.sh — sourced, not executed.
# Keep this file dependency-free (pure bash + gcloud + basic coreutils).

set -euo pipefail

# Consistent, minimal color output. Falls back cleanly on non-TTY.
if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; RESET=$'\e[0m'
else
  BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; CYAN=''; RESET=''
fi

# Print a step banner. Every script starts with one of these.
banner() {
  local pillar="$1"; shift
  local title="$*"
  printf '\n%s┌─────────────────────────────────────────────────────────────────────%s\n' "$CYAN" "$RESET"
  printf '%s│%s %s[%s]%s %s%s%s\n' "$CYAN" "$RESET" "$DIM" "$pillar" "$RESET" "$BOLD" "$title" "$RESET"
  printf '%s└─────────────────────────────────────────────────────────────────────%s\n' "$CYAN" "$RESET"
}

info() { printf '%s→%s %s\n' "$CYAN" "$RESET" "$*"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s⚠%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s✗%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# Shared naming — the workshop uses one MCP gateway, one Model Armor template,
# one Agent Registry entry, one skill. Only per-engineer Agent Engine instances
# are suffixed. Keep these constants in one place so scripts stay consistent.
readonly SHARED_MCP_SERVICE="sre-mcp-gateway"
readonly SHARED_ARTIFACT_REPO="enterprise-support-agent"
readonly SHARED_MODEL_ARMOR_TEMPLATE="enterprise-security-template"
readonly SHARED_SKILL_ID="incident-escalator"
readonly SHARED_STAGING_BUCKET_SUFFIX="agent-engine-staging"  # combined with project number
readonly SHARED_MCP_URL_SECRET="mcp-gateway-url"

require_env() {
  local var
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      die "Required env var $var is not set. Set it and re-run."
    fi
  done
}

require_cmd() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' not found on PATH."
  done
}

project_number() {
  gcloud projects describe "$GOOGLE_CLOUD_PROJECT" --format='value(projectNumber)'
}

console_url() {
  # Small helper so every "verify in Console" line is formatted the same.
  printf '   %s→ Console:%s %s\n' "$DIM" "$RESET" "$1"
}
