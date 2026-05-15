#!/usr/bin/env bash
# codex_pm.sh — launch Codex with the hashharness-pm environment preloaded.
#
# Usage:
#   skills/pm/scripts/codex_pm.sh [codex args...]
#   skills/pm/scripts/codex_pm.sh --check
#
# Effects:
#   - sources the first matching hashharness env file
#   - prepends skills/pm/scripts to PATH so `pm` is callable directly
#   - mints PM_CONTEXT_ID once per Codex session if one is not already set
#   - on first use, warns if ~/.codex/config.toml still auto-approves
#     raw hashharness create_item / set_schema writes
#
# This is the Codex-side substitute for Claude's SessionStart hook.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPTS_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(cd -P "$SCRIPTS_DIR/../../.." >/dev/null 2>&1 && pwd)"
CODEX_CONFIG="$HOME/.codex/config.toml"
HINT_SENTINEL="$HOME/.codex/memories/hashharness-pm-codex-config-hint-v1"

ENV_CANDIDATES=(
  "${HASHHARNESS_ENV:-}"
  "$HOME/.hashharness/env"
  "$HOME/.codex/hashharness/env"
  "$HOME/.claude/hashharness/env"
  "$PROJECT_ROOT/.hashharness/env"
)

env_file=""
for cand in "${ENV_CANDIDATES[@]}"; do
  [[ -n "$cand" && -f "$cand" ]] || continue
  env_file="$cand"
  break
done

if [[ -n "$env_file" ]]; then
  # shellcheck disable=SC1090
  source "$env_file"
  export HASHHARNESS_ENV="$env_file"
fi

export PATH="$SCRIPTS_DIR:$PATH"

if [[ -z "${PM_CONTEXT_ID:-}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PM_CONTEXT_ID="$(python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
)"
  elif command -v uuidgen >/dev/null 2>&1; then
    PM_CONTEXT_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
  fi
  [[ -n "${PM_CONTEXT_ID:-}" ]] && export PM_CONTEXT_ID
fi

should_hint_codex_config() {
  [[ -f "$CODEX_CONFIG" ]] || return 1
  [[ -e "$HINT_SENTINEL" ]] && return 1
  if rg -U -q '\[mcp_servers\.hashharness\.tools\.create_item\][[:space:]\r\n]+approval_mode = "approve"' "$CODEX_CONFIG"; then
    return 0
  fi
  if rg -U -q '\[mcp_servers\.hashharness\.tools\.set_schema\][[:space:]\r\n]+approval_mode = "approve"' "$CODEX_CONFIG"; then
    return 0
  fi
  return 1
}

emit_codex_config_hint() {
  mkdir -p "$(dirname "$HINT_SENTINEL")" 2>/dev/null || true
  : > "$HINT_SENTINEL" 2>/dev/null || true
  cat >&2 <<EOF
hashharness-pm: Codex config suggestion

Your ~/.codex/config.toml appears to auto-approve one or both raw
hashharness write tools:
  - mcp_servers.hashharness.tools.create_item
  - mcp_servers.hashharness.tools.set_schema

For normal pm usage under Codex, prefer leaving reads approved but
removing auto-approval for those two raw write tools. That keeps \`pm\`
as the normal write path for Task / TaskStatus / TaskReport updates.

See:
  docs/codex-integration.md
EOF
}

if [[ "${1:-}" == "--check" ]]; then
  printf 'codex_pm.sh\n'
  printf '  project root: %s\n' "$PROJECT_ROOT"
  printf '  env file:     %s\n' "${env_file:-<none>}"
  printf '  mcp url:      %s\n' "${HASHHARNESS_MCP_URL:-<unset>}"
  printf '  pm context:   %s\n' "${PM_CONTEXT_ID:-<unset>}"
  printf '  pm on PATH:   %s\n' "$SCRIPTS_DIR"
  if should_hint_codex_config; then
    printf '  codex config: suggest tightening hashharness write approvals\n'
  else
    printf '  codex config: no first-use warning needed\n'
  fi
  exit 0
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "codex_pm.sh: \`codex\` not found on PATH" >&2
  exit 127
fi

if [[ -z "${HASHHARNESS_MCP_URL:-}" ]]; then
  cat >&2 <<EOF
codex_pm.sh: no hashharness env file found and HASHHARNESS_MCP_URL is unset.
The Codex session will still start, but pm commands that touch storage will fail
until you run:
  skills/pm/scripts/pm install --to-home --yes
or export HASHHARNESS_MCP_URL by hand.
EOF
fi

if should_hint_codex_config; then
  emit_codex_config_hint
fi

exec codex "$@"
