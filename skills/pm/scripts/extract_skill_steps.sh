#!/usr/bin/env bash
# extract_skill_steps.sh — semantic step extraction from a SKILL.md, with
# bash-side validation and optional recursion into nested skill invocations.
#
# Two extraction modes:
#   --mode llm     (default if a supported LLM CLI is on PATH) — calls either
#                  `claude -p` or `codex exec -` with a structured prompt,
#                  then VALIDATES that every step's anchor is a verbatim
#                  substring of the source SKILL.md. Steps that fail
#                  validation are marked verified=false in the output rather
#                  than dropped — the caller can decide whether to trust them.
#   --mode regex   — falls back to extract_steps.py (the existing pattern-
#                  matching extractor). Always available; no LLM dependency.
#
# Recursion: when an LLM-extracted step lists subskills_invoked, this script
# recurses (subject to --max-depth) and splices the nested skill's steps under
# the parent step's `nested` key. Each nested step's `n` is prefixed with the
# parent's `n` and a dot — e.g. parent step 9 invoking skill X yields nested
# steps named `9.X.S1`, `9.X.S2`, etc.
#
# Usage:
#   extract_skill_steps.sh <skill-name>
#   extract_skill_steps.sh --path /abs/path/to/SKILL.md
#   extract_skill_steps.sh <skill-name> --max-depth 2 --mode llm
#   extract_skill_steps.sh <skill-name> --no-validate    # skip the grep-back step
#
# Output: JSON to stdout with the same shape as extract_steps.py but with
# `verified` per step and an optional `nested` array per step.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REGEX_EXTRACTOR="$SCRIPT_DIR/../skill-shared/extract_steps.py"
if [[ ! -f "$REGEX_EXTRACTOR" ]]; then
  for cand in \
      "$HOME/.codex/skills/pm-skill-shared/extract_steps.py" \
      "$HOME/.codex/skills/.system/pm-skill-shared/extract_steps.py" \
      "$HOME/.claude/skills/pm-skill-shared/extract_steps.py"; do
    if [[ -f "$cand" ]]; then
      REGEX_EXTRACTOR="$cand"
      break
    fi
  done
fi

skill_name=""
skill_path=""
mode="auto"
max_depth=2
validate="yes"
llm_cli=""

pick_llm_cli() {
  local override="${PM_LLM_CLI:-}"
  if [[ -n "$override" ]]; then
    case "$override" in
      codex|claude)
        llm_cli="$override"
        return 0
        ;;
      *)
        echo "unsupported PM_LLM_CLI value: $override (expected codex or claude)" >&2
        return 1
        ;;
    esac
  fi

  if [[ -n "${CODEX_THREAD_ID:-}${CODEX_CI:-}${CODEX_SANDBOX:-}" ]] \
     && command -v codex >/dev/null 2>&1; then
    llm_cli="codex"
    return 0
  fi
  if [[ -n "${CLAUDE_PROJECT_DIR:-}${CLAUDE_ENV_FILE:-}${CLAUDE_CODE_SIMPLE:-}" ]] \
     && command -v claude >/dev/null 2>&1; then
    llm_cli="claude"
    return 0
  fi
  if command -v claude >/dev/null 2>&1; then
    llm_cli="claude"
    return 0
  fi
  if command -v codex >/dev/null 2>&1; then
    llm_cli="codex"
    return 0
  fi
  return 1
}

run_llm_cli() {
  case "$llm_cli" in
    claude)
      printf '%s' "$1" | claude -p 2>/dev/null
      ;;
    codex)
      printf '%s' "$1" | codex exec --skip-git-repo-check - 2>/dev/null
      ;;
    *)
      echo "unsupported llm cli: $llm_cli" >&2
      return 1
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)        skill_path="$2"; shift 2 ;;
    --mode)        mode="$2";       shift 2 ;;
    --max-depth)   max_depth="$2";  shift 2 ;;
    --no-validate) validate="no";   shift   ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# //; s/^#//'
      exit 0
      ;;
    -*) echo "unknown arg: $1" >&2; exit 64 ;;
    *)  skill_name="$1"; shift ;;
  esac
done

[[ -n "$skill_name" || -n "$skill_path" ]] || { echo "provide skill name or --path" >&2; exit 64; }

# Auto-pick mode: prefer LLM if a supported CLI is available, else regex.
if [[ "$mode" == "auto" ]]; then
  if pick_llm_cli >/dev/null 2>&1; then
    mode="llm"
  else
    mode="regex"
  fi
fi
if [[ "$mode" == "llm" ]]; then
  pick_llm_cli
fi

# Normalise subskill references that come back from LLM extraction with
# leading "/" or "skill:" prefixes — these are how SKILL.md authors invoke
# slash-commands or scoped skills, but the on-disk files don't have those
# prefixes in their directory names.
skill_name="${skill_name#/}"
skill_name="${skill_name#skill:}"

# Resolve SKILL.md path if only name was given.
# Search order: Codex skills, agent skills, Claude skills, then plugin caches.
if [[ -z "$skill_path" ]]; then
  for cand in \
      "$HOME/.codex/skills/$skill_name/SKILL.md" \
      "$HOME/.codex/skills/.system/$skill_name/SKILL.md" \
      "$HOME/.agents/skills/$skill_name/SKILL.md" \
      "$HOME/.claude/skills/$skill_name/SKILL.md" \
      "$PWD/.claude/commands/$skill_name.md" \
      "$HOME/.claude/commands/$skill_name.md" \
      "$HOME/.codex/plugins/cache"/*/*/*/skills/"$skill_name"/SKILL.md \
      "$HOME/.codex/plugins/cache"/*/*/skills/"$skill_name"/SKILL.md \
      "$HOME/.codex/plugins/cache"/*/skills/"$skill_name"/SKILL.md \
      "$HOME/.claude/plugins/marketplaces"/*/skills/"$skill_name"/SKILL.md \
      "$HOME/.claude/plugins/cache"/*/*/*/skills/"$skill_name"/SKILL.md \
      "$HOME/.claude/plugins/cache"/*/*/skills/"$skill_name"/SKILL.md \
      "$HOME/.claude/plugins/cache"/*/skills/"$skill_name"/SKILL.md; do
    if [[ -f "$cand" ]]; then
      skill_path="$cand"
      break
    fi
  done
  [[ -n "$skill_path" ]] || { echo "SKILL.md for '$skill_name' not found" >&2; exit 1; }
fi

[[ -z "$skill_name" ]] && skill_name="$(basename "$(dirname "$skill_path")")"

# ---- regex mode: just delegate ------------------------------------------

if [[ "$mode" == "regex" ]]; then
  exec python3 "$REGEX_EXTRACTOR" --path "$skill_path"
fi

# ---- llm mode -----------------------------------------------------------

LLM_PROMPT="$(cat <<'PROMPT'
You are extracting the major workflow steps from an agent skill's
SKILL.md. The SKILL.md is in the file path provided to you.

Your job:
1. Identify the major workflow steps the skill prescribes. They're usually
   numbered ("Step 1", "Step 2", "1. Foo", "2. Bar") or grouped under
   sections like "## Phase 0", "## Phase 1", "## Procedure", "## Workflow".
   Boilerplate sections like Inputs/Notes/Examples/Exit-codes are NOT steps.
2. For each step, capture:
     - n: an opaque step identifier (e.g. "0", "1", "Phase 0", "10b")
     - title: a short title (4-10 words, no markdown)
     - anchor: a VERBATIM substring of the source line where this step is
       defined (heading line preferred). Must be greppable — the consumer
       will grep -F this string back into the source to verify you didn't
       hallucinate it.
     - subskills_invoked: list of OTHER skill names this step explicitly
       invokes (phrases like "use the X skill", "invoke X", "run skill X",
       "call X subagent"). Empty list if none.

Output ONLY valid JSON, no prose, no code fences. Schema:

{
  "steps": [
    {"n": "...", "title": "...", "anchor": "...", "subskills_invoked": []},
    ...
  ]
}

If you can't find a verbatim anchor for a step, OMIT the step rather than
fabricate. Better to under-extract than to invent.
PROMPT
)"

# Use jq to escape the SKILL.md content, then assemble the prompt.
if ! command -v jq >/dev/null 2>&1; then
  echo "llm mode requires jq for JSON handling; install jq or use --mode regex" >&2
  exit 2
fi

skill_md_content="$(cat "$skill_path")"
full_prompt=$(printf "%s\n\n<skill_path>\n%s\n</skill_path>\n\n<skill_content>\n%s\n</skill_content>\n" \
  "$LLM_PROMPT" "$skill_path" "$skill_md_content")

# Call the chosen LLM CLI; capture JSON. Failure here surfaces stderr + exits.
llm_out=$(run_llm_cli "$full_prompt") || {
  echo "$llm_cli invocation failed; falling back to regex" >&2
  exec python3 "$REGEX_EXTRACTOR" --path "$skill_path"
}

# Trim any code-fence wrapping the LLM might have added despite instructions.
llm_out=$(printf '%s' "$llm_out" \
  | sed -e 's/^```json//' -e 's/^```//' -e 's/```$//' \
  | awk '/./')

# Validate JSON shape.
if ! printf '%s' "$llm_out" | jq -e '.steps | type == "array"' >/dev/null 2>&1; then
  echo "LLM output isn't valid JSON with .steps; falling back to regex" >&2
  exec python3 "$REGEX_EXTRACTOR" --path "$skill_path"
fi

# Stage the LLM output to a temp file so subsequent python helpers can read
# from stdin via pipe (heredoc-style `python3 - <<EOF` would block stdin).
work=$(mktemp -t pm-extract-XXXX)
trap "rm -f $work" EXIT
printf '%s' "$llm_out" > "$work"

# ---- bash-side validation: anchor must be a substring of the source ----
# In addition to verified=bool, capture:
#   line_number    — 1-indexed line of the anchor's first match (or null)
#   body_lines     — [start, end] lines spanning this step's body (anchor
#                    line through the line before the next step's anchor,
#                    or end of file). Used by build_task_body.py to
#                    splice the verbatim spec into the worker's task body.

if [[ "$validate" == "yes" ]]; then
  python3 -c "
import json, sys
src_lines = open('$skill_path').read().splitlines()
src_text = '\n'.join(src_lines)
data = json.load(open('$work'))

# First pass: line_number per step.
for step in data.get('steps', []):
    anchor = step.get('anchor', '')
    step['verified'] = bool(anchor) and (anchor in src_text)
    step['line_number'] = None
    if step['verified']:
        for i, ln in enumerate(src_lines, start=1):
            if anchor in ln:
                step['line_number'] = i
                break

# Second pass: body_lines = [own line_number, next step's line_number - 1].
verified = [s for s in data.get('steps', []) if s.get('line_number')]
verified.sort(key=lambda s: s['line_number'])
for i, s in enumerate(verified):
    start = s['line_number']
    end = (verified[i+1]['line_number'] - 1) if i+1 < len(verified) else len(src_lines)
    s['body_lines'] = [start, end]

open('$work', 'w').write(json.dumps(data))
"
fi

# ---- recursion into nested skill invocations ---------------------------

if [[ "$max_depth" -gt 0 ]]; then
  python3 -c "
import json, subprocess
script = '$0'
max_depth = $max_depth
data = json.load(open('$work'))
for step in data.get('steps', []):
    subs = step.get('subskills_invoked') or []
    nested = []
    for sub in subs:
        try:
            res = subprocess.run(
                [script, sub, '--max-depth', str(max_depth - 1)],
                capture_output=True, text=True, timeout=120,
            )
            if res.returncode == 0:
                sub_data = json.loads(res.stdout)
                # Re-key nested step ids so they're disambiguated.
                for ns in sub_data.get('steps', []):
                    ns['n'] = f\"{step['n']}.{sub}.{ns['n']}\"
                nested.append({'skill': sub,
                               'steps': sub_data.get('steps', []),
                               'strategy': sub_data.get('strategy', '')})
        except Exception as e:
            nested.append({'skill': sub, 'error': str(e)})
    if nested:
        step['nested'] = nested
open('$work', 'w').write(json.dumps(data))
"
fi

# ---- emit final JSON --------------------------------------------------

python3 -c "
import json
data = json.load(open('$work'))
out = {
    'skill': '$skill_name',
    'skill_path': '$skill_path',
    'strategy': 'llm-extraction',
    'max_depth': $max_depth,
    **data,
}
print(json.dumps(out, indent=2))
"
