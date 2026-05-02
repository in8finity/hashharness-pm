#!/usr/bin/env python3
"""pm dashboard — minimal HTTP server showing planning-board state.

Reads via the same MCP client / store helpers the rest of pm uses.
Auto-refresh in the browser; no JS dependency, no external libs.

Usage:
  pm dashboard [--port 38418] [--bind 127.0.0.1] [--refresh 5]

Endpoints:
  /              HTML dashboard (auto-refresh)
  /api/state     JSON snapshot (workdirs → queues → task tree + status)
  /healthz       liveness probe ("ok")

Exit:
  Ctrl+C
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import mcp_client
import store


def _unwrap_items(res):
    if not res:
        return []
    if isinstance(res, list):
        return res
    if isinstance(res, dict):
        return res.get("items") or []
    return []


def fetch_state() -> dict:
    """Return all tasks grouped by (workdir, queue), each with status + tree info."""
    raw = mcp_client.tool("find_items", {"type": "Task", "limit": 10000})
    tasks = _unwrap_items(raw)

    # record_sha256 → text_sha256 lookup for resolving parentTask links.
    record_to_text = {
        t["record_sha256"]: t["text_sha256"]
        for t in tasks
        if "record_sha256" in t and "text_sha256" in t
    }

    workdirs: dict[str, dict[str, list[dict]]] = defaultdict(lambda: defaultdict(list))
    by_status: dict[str, int] = defaultdict(int)
    total = 0

    for t in tasks:
        attrs = t.get("attributes") or {}
        sha = t.get("text_sha256")
        if not sha:
            continue
        workdir = attrs.get("workdir") or "<no-workdir>"
        queue = attrs.get("queue") or "default"

        latest = store.latest_status(sha)
        status = store.status_value(latest) or "?"

        links = t.get("links") or {}
        parent_record = links.get("parentTask")
        parent_text = record_to_text.get(parent_record) if parent_record else None
        deps = links.get("dependsOn") or []

        owner = (latest.get("attributes") or {}).get("agent") if isinstance(latest, dict) else None
        ctx = (latest.get("attributes") or {}).get("context_id") if isinstance(latest, dict) else None

        workdirs[workdir][queue].append({
            "sha": sha,
            "short_sha": sha[:12],
            "slug": attrs.get("slug", "?"),
            "title": t.get("title", "") or "",
            "status": status,
            "queue": queue,
            "workdir": workdir,
            "sticky": bool(attrs.get("sticky")),
            "verifier": attrs.get("verifier") or "",
            "parent": parent_text,
            "deps_count": len(deps),
            "created_at": t.get("created_at"),
            "owner": owner or "",
            "context_id": ctx[:8] if ctx else "",
            "wp_id": t.get("work_package_id") or "",
        })
        by_status[status] += 1
        total += 1

    return {
        "workdirs": {wd: dict(qs) for wd, qs in workdirs.items()},
        "totals": {"tasks": total, "by_status": dict(by_status)},
    }


HTML_HEAD = """<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>pm dashboard</title>
<meta http-equiv="refresh" content="{refresh}">
<style>
body {{ font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", monospace; margin: 1em; background: #fafafa; color: #222; }}
h1 {{ font-size: 1.3em; margin: 0 0 0.5em; }}
h2 {{ font-size: 1.1em; margin: 0 0 0.4em; color: #444; }}
h3 {{ font-size: 1em; margin: 0.4em 0 0.3em; color: #555; }}
.workdir {{ background: #fff; border: 1px solid #ddd; padding: 0.8em 1em; margin-bottom: 1em; border-radius: 4px; }}
.queue {{ margin-left: 0.5em; padding-left: 0.8em; border-left: 3px solid #ccc; margin-bottom: 0.6em; }}
.task {{ padding: 0.2em 0; line-height: 1.4; }}
.task[data-depth="1"] {{ margin-left: 1.5em; }}
.task[data-depth="2"] {{ margin-left: 3em; }}
.task[data-depth="3"] {{ margin-left: 4.5em; }}
.task[data-depth="4"] {{ margin-left: 6em; }}
.status {{ display: inline-block; min-width: 4.5em; text-align: center; padding: 0.05em 0.4em; border-radius: 3px; font-size: 0.78em; font-weight: 600; margin-right: 0.4em; }}
.status-new        {{ background: #e3f2fd; color: #0d47a1; }}
.status-working    {{ background: #fff3e0; color: #e65100; }}
.status-done       {{ background: #e8f5e9; color: #1b5e20; }}
.status-rejected   {{ background: #ffebee; color: #c62828; }}
.status-superseded {{ background: #f3e5f5; color: #6a1b9a; }}
.status-\\?         {{ background: #eee; color: #555; }}
.sha {{ color: #999; font-family: monospace; font-size: 0.82em; }}
.slug {{ font-weight: 600; }}
.title {{ color: #555; margin-left: 0.5em; }}
.tag {{ background: #f0f0f0; color: #333; padding: 0 0.4em; border-radius: 3px; font-size: 0.75em; margin-left: 0.3em; vertical-align: middle; }}
.tag-sticky {{ background: #fff8e1; color: #6a5400; }}
.tag-verifier {{ background: #e1f5fe; color: #014361; }}
.tag-deps {{ background: #f3e5f5; color: #491b75; }}
.tag-owner {{ background: #f5f5f5; color: #333; font-family: monospace; }}
.tag-ctx {{ background: #fff8e1; color: #6a5400; font-family: monospace; }}
.totals {{ background: #fff; border: 1px solid #ddd; padding: 0.5em 0.8em; border-radius: 4px; margin-bottom: 1em; }}
.totals .status {{ margin-right: 0.4em; }}
.empty {{ color: #888; font-style: italic; }}
.foot {{ margin-top: 1.5em; color: #999; font-size: 0.8em; }}
a {{ color: #1976d2; text-decoration: none; }}
a:hover {{ text-decoration: underline; }}
</style>
</head><body>
<h1>pm dashboard <span class="sha">— auto-refresh {refresh}s · <a href="/api/state">json</a></span></h1>
"""


def _render_task(task: dict, children_of: dict, depth: int = 0) -> list[str]:
    out = []
    tags = []
    if task["sticky"]:
        tags.append('<span class="tag tag-sticky">sticky</span>')
    if task["verifier"]:
        tags.append(f'<span class="tag tag-verifier">verifier:{escape(task["verifier"])[:30]}</span>')
    if task["deps_count"]:
        tags.append(f'<span class="tag tag-deps">deps:{task["deps_count"]}</span>')
    if task["owner"]:
        tags.append(f'<span class="tag tag-owner">@{escape(task["owner"])[:24]}</span>')
    if task["context_id"]:
        tags.append(f'<span class="tag tag-ctx">ctx:{escape(task["context_id"])}</span>')

    title_part = f'<span class="title">— {escape(task["title"])[:80]}</span>' if task["title"] else ""

    out.append(
        f'<div class="task" data-depth="{depth}">'
        f'<span class="status status-{escape(task["status"])}">{escape(task["status"])}</span>'
        f'<span class="slug">{escape(task["slug"])}</span> '
        f'<span class="sha">{escape(task["short_sha"])}</span>'
        f'{title_part}'
        f'{"".join(tags)}'
        f'</div>'
    )

    children = sorted(children_of.get(task["sha"], []), key=lambda x: x.get("created_at") or "")
    for c in children:
        out.extend(_render_task(c, children_of, depth + 1))
    return out


def render_html(state: dict, refresh: int) -> str:
    pieces = [HTML_HEAD.format(refresh=refresh)]

    # Totals bar.
    total = state["totals"]["tasks"]
    parts = [f"<strong>Total tasks:</strong> {total}"]
    for st, n in sorted(state["totals"]["by_status"].items()):
        parts.append(f'<span class="status status-{escape(st)}">{escape(st)}: {n}</span>')
    pieces.append(f'<div class="totals">{" ".join(parts)}</div>')

    if not state["workdirs"]:
        pieces.append('<p class="empty">(no tasks in any queue)</p>')

    for workdir in sorted(state["workdirs"].keys()):
        queues = state["workdirs"][workdir]
        pieces.append(f'<div class="workdir"><h2>📂 {escape(workdir)}</h2>')
        for queue in sorted(queues.keys()):
            tasks = queues[queue]
            pieces.append(f'<div class="queue"><h3>queue: <code>{escape(queue)}</code> &nbsp;<span class="sha">({len(tasks)} tasks)</span></h3>')

            # Build parent index.
            by_sha = {t["sha"]: t for t in tasks}
            children_of: dict = defaultdict(list)
            roots = []
            for t in tasks:
                if t["parent"] and t["parent"] in by_sha:
                    children_of[t["parent"]].append(t)
                else:
                    roots.append(t)

            for r in sorted(roots, key=lambda x: x.get("created_at") or ""):
                pieces.extend(_render_task(r, children_of))

            pieces.append('</div>')
        pieces.append('</div>')

    pieces.append(
        '<div class="foot">Powered by <code>pm dashboard</code> reading hashharness MCP. '
        'See <a href="/api/state">/api/state</a> for raw JSON.</div>'
    )
    pieces.append('</body></html>')
    return "\n".join(pieces)


class Handler(BaseHTTPRequestHandler):
    refresh_seconds = 5

    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path == "/api/state":
                state = fetch_state()
                body = json.dumps(state, indent=2, default=str).encode("utf-8")
                self._respond(200, "application/json", body)
            elif path == "/healthz":
                self._respond(200, "text/plain", b"ok")
            elif path in ("/", "/index.html"):
                state = fetch_state()
                body = render_html(state, self.refresh_seconds).encode("utf-8")
                self._respond(200, "text/html; charset=utf-8", body)
            else:
                self._respond(404, "text/plain", b"not found")
        except Exception as e:  # pragma: no cover — surface the error
            msg = f"<pre>error: {escape(str(e))}</pre>".encode("utf-8")
            self._respond(500, "text/html; charset=utf-8", msg)

    def _respond(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002
        # Quieter than default — only log non-200s.
        if args and args[1] not in ("200", "304"):
            sys.stderr.write(f"{self.address_string()} - {format % args}\n")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", type=int, default=38418)
    p.add_argument("--bind", default="127.0.0.1")
    p.add_argument("--refresh", type=int, default=5,
                   help="HTML auto-refresh interval in seconds (default 5)")
    args = p.parse_args()

    Handler.refresh_seconds = args.refresh
    srv = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(f"pm dashboard listening at http://{args.bind}:{args.port}/", file=sys.stderr)
    print(f"  /              auto-refresh every {args.refresh}s", file=sys.stderr)
    print(f"  /api/state     JSON snapshot", file=sys.stderr)
    print(f"  /healthz       liveness probe", file=sys.stderr)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down", file=sys.stderr)
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
