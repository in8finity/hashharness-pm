#!/usr/bin/env bash
# pm_owned_check.sh — narrow Codex-friendly pre-stop check.
#
# Usage:
#   skills/pm/scripts/pm_owned_check.sh [--queue Q ...] [--json]
#
# This wrapper:
#   - sources the first matching hashharness env file
#   - prepends the pm scripts dir to PATH
#   - runs the strict owned-task check
#
# It exists so Codex users can approve/allowlist one narrow command
# instead of a broad `bash -lc ...` shape.

set -euo pipefail

SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPTS_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
PROJECT_ROOT="$(cd -P "$SCRIPTS_DIR/../../.." >/dev/null 2>&1 && pwd)"

ENV_CANDIDATES=(
  "${HASHHARNESS_ENV:-}"
  "$HOME/.hashharness/env"
  "$HOME/.codex/hashharness/env"
  "$HOME/.claude/hashharness/env"
  "$PROJECT_ROOT/.hashharness/env"
)

for cand in "${ENV_CANDIDATES[@]}"; do
  [[ -n "$cand" && -f "$cand" ]] || continue
  # shellcheck disable=SC1090
  source "$cand"
  export HASHHARNESS_ENV="$cand"
  break
done

export PATH="$SCRIPTS_DIR:$PATH"

exec "$SCRIPTS_DIR/owned.py" --strict "$@"
