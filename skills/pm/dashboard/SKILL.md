---
name: pm-dashboard
description: >
  Start a minimal HTTP dashboard showing the planning board's current
  state — workdirs grouped by queue, with task trees (parent/subtask
  hierarchy via parentTask), each task's status, owner, sticky
  binding, verifier, and dep count. Stdlib-only Python; no JS, no
  external deps. Use when you want a live view of a hashharness-pm
  instance ("show me what's queued / working / stuck"), or a JSON
  endpoint to scrape from another tool.
---

# pm:dashboard — minimal HTTP view of the planning board

## Procedure

`../scripts/pm dashboard [--port 38418] [--bind 127.0.0.1] [--refresh 5]`

Starts a single-process HTTP server reading from the same hashharness
MCP backend the rest of `pm` uses (via `HASHHARNESS_MCP_URL`). Three
endpoints:

| Path | Returns |
|---|---|
| `/` | HTML dashboard, auto-refreshes every `--refresh` seconds |
| `/api/state` | JSON snapshot — `{workdirs: {wd: {queue: [task_summaries]}}, totals: {...}}` |
| `/healthz` | `ok` (liveness probe for orchestration) |

`Ctrl+C` to stop.

## What's shown

For every Task in storage:

- **workdir grouping** — top-level boxes are workdirs (`attributes.workdir`); tasks with no workdir bucketed under `<no-workdir>`.
- **queue grouping** — within each workdir, tasks are grouped by `attributes.queue`.
- **task tree** — children indent under their parent (`links.parentTask`); roots come first, then descendants by `created_at`.
- **status pill** — colour-coded badge (`new` / `working` / `done` / `rejected` / `superseded`).
- **slug + short sha** — for cross-referencing with `pm` CLI invocations.
- **tags** — `sticky`, `verifier:<spec>`, `deps:N`, `@agent`, `ctx:<8-char>` when applicable.
- **totals bar** — total task count + per-status breakdown at the top.

## Reads, doesn't mutate

The dashboard is read-only. It calls `mcp_client.tool("find_items", {"type": "Task"})` and `store.latest_status(sha)` for each task — no writes, no claims, no state changes. Safe to leave running alongside live workers.

## When to use

- **Watching a long-running queue** — open `/` in a browser tab while `pm execute` workers drain it.
- **Debugging a stuck chain** — see at a glance which tasks are `working` vs `new` vs `rejected`.
- **Operator dashboards** — point an `<iframe>` or a Grafana plugin at `/api/state` for cross-stack visibility.
- **Spot-checking a sticky chain** — the `ctx:` tag shows context-id bindings.

## Notes

- For large queues (~10k tasks) the initial page render takes a couple of seconds (one `find_items` round-trip plus one `find_tip` per task). Subsequent refreshes are the same cost — the dashboard doesn't cache.
- The HTML is intentionally framework-free: stdlib `http.server`, no JS, no external libs. View source for the entire client.
- Reads via `HASHHARNESS_MCP_URL` (default `http://127.0.0.1:38417/mcp`); start the hashharness MCP server first.
