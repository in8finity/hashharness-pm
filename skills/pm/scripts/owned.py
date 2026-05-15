#!/usr/bin/env python3
"""List `working` tasks currently owned by this agent identity.

Useful as a manual pre-stop check in Codex, where there is no public
turn-end hook equivalent to Claude's `Stop` hook.

Usage:
  owned.py [--queue Q ...] [--json] [--strict] [--agent ID] [--context-id UUID]

Exit codes:
  0  success (or no open owned tasks when --strict is not set)
  1  open owned tasks found and --strict was set
  2  usage / environment / backend error
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys

import mcp_client
import store


def default_agent_id(context_id: str | None = None) -> str:
    if env := os.environ.get("PM_AGENT_ID"):
        return env
    ctx = context_id or os.environ.get("PM_CONTEXT_ID")
    if ctx:
        return f"worker-{ctx[:12]}"
    return f"{socket.gethostname()}-{os.getpid()}"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--queue", action="append", default=[],
                   help="restrict to queue(s); repeatable")
    p.add_argument("--json", action="store_true")
    p.add_argument("--strict", action="store_true",
                   help="exit 1 if any owned tasks are still working")
    p.add_argument("--agent",
                   help="agent identifier (default: $PM_AGENT_ID, else worker-<PM_CONTEXT_ID[:12]>)")
    p.add_argument("--context-id",
                   help="context id used to derive the default agent id")
    args = p.parse_args()

    if not os.environ.get("HASHHARNESS_MCP_URL"):
        sys.stderr.write(
            "HASHHARNESS_MCP_URL is unset. Start hashharness or source an env file first.\n"
        )
        return 2

    me = args.agent or default_agent_id(args.context_id)
    queues = set(args.queue)

    raw = mcp_client.tool("find_items", {"type": "Task", "limit": 10000})
    items = raw if isinstance(raw, list) else (raw.get("items") if isinstance(raw, dict) else [])

    owned: list[dict[str, str]] = []
    for task in items:
        attrs = task.get("attributes") or {}
        sha = task.get("text_sha256") or ""
        if not sha:
            continue
        queue = attrs.get("queue") or "default"
        if queues and queue not in queues:
            continue

        latest = store.latest_status(sha)
        if not latest or store.status_value(latest) != "working":
            continue
        owner = (latest.get("attributes") or {}).get("agent") or ""
        if owner != me:
            continue

        owned.append({
            "queue": queue,
            "slug": attrs.get("slug") or "",
            "title": task.get("title") or "",
            "sha": sha,
        })

    if args.json:
        print(json.dumps({"agent": me, "count": len(owned), "tasks": owned}, indent=2))
    else:
        if owned:
            print(f"agent={me} open_working_tasks={len(owned)}")
            for task in owned:
                label = task["slug"] or task["title"] or "?"
                print(f"  {task['queue']} / {label} ({task['sha'][:12]})")
        else:
            print(f"agent={me} open_working_tasks=0")

    return 1 if args.strict and owned else 0


if __name__ == "__main__":
    sys.exit(main())
