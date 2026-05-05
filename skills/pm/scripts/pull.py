#!/usr/bin/env python3
"""Pull and claim the next runnable task in one shot.

Usage:
  pull.py [--queue Q] [--max-retries N] [--regex P]

Behavior:
  1. Call next() to get a runnable task.
  2. Try to claim it via append_status('working'); on race-loss (the latest
     status is no longer 'new'), pull the next one. Retry up to --max-retries
     races (default 5).
  3. On success print three shell-eval-able lines to stdout:
        TASK=<text_sha256>
        IDEA_PATH=<extracted from task.text via regex; empty if no match>
        SLUG=<task.attributes.slug>
     Caller in bash: ``eval "$(pm pull)"`` and then check ``[ -n "$TASK" ]``.
  4. On queue-empty: exit 0 with NO output (TASK ends up empty).
  5. On all races lost: exit 0 with NO output and a stderr note.

The default --regex extracts the path that follows
``Run /qualify-idea-toulmin `` on line 1 of task.text. Override with
``--regex`` (Python regex; first capture group is used) for other workflows.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys

import store
from now_iso import now_iso


def shell_quote(v: str) -> str:
    return "'" + v.replace("'", "'\\''") + "'"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--queue", default="default")
    p.add_argument("--max-retries", type=int, default=5)
    p.add_argument(
        "--regex",
        default=r"Run /qualify-idea-toulmin (\S+)",
        help="Python regex to extract a path-or-arg from task.text; group 1.",
    )
    p.add_argument("--context-id", default=None,
                   help="sticky context id (overrides $PM_CONTEXT_ID). "
                        "Same selection semantics as `pm next --context-id`: "
                        "context-affinitive tasks come first, then FIFO.")
    args = p.parse_args()

    pat = re.compile(args.regex)
    agent_context = args.context_id or os.environ.get("PM_CONTEXT_ID") or None

    for attempt in range(args.max_retries + 1):
        # Re-implement next.py logic inline to avoid double round-trip.
        tasks = store.list_tasks(args.queue)

        # record→text translation matches next.py so the runnable-set
        # here is identical to what `pm next` would return.
        record_to_text = {t["record_sha256"]: t["text_sha256"] for t in tasks}

        status_cache: dict[str, str | None] = {}
        ctx_cache: dict[str, set[str]] = {}

        def status_of(sha: str) -> str | None:
            if sha not in status_cache:
                status_cache[sha] = store.status_value(store.latest_status(sha))
            return status_cache[sha]

        def required_ctx(sha: str) -> set[str]:
            if sha not in ctx_cache:
                ctx_cache[sha] = store.collect_required_contexts(sha)
            return ctx_cache[sha]

        def context_priority(t: dict) -> int:
            """Same shape as next.py's context_priority — see that file
            for the rationale. Mirrors so pull's selection order matches
            what `pm next` would return."""
            if agent_context is None:
                return 1
            sha = t["text_sha256"]
            if store.task_context_id(sha) == agent_context:
                return 0
            return 0 if agent_context in required_ctx(sha) else 1

        tasks.sort(key=lambda t: (context_priority(t), t.get("created_at", "")))

        def dep_done(d_record: str) -> bool:
            d_text = record_to_text.get(d_record)
            return d_text is not None and status_of(d_text) == "done"

        def parent_claimed(t: dict) -> bool:
            parent_record = (t.get("links") or {}).get("parentTask")
            if not parent_record:
                return True
            parent_text = record_to_text.get(parent_record)
            if parent_text is None:
                return True
            return status_of(parent_text) != "new"

        candidate = None
        for t in tasks:
            sha = t["text_sha256"]
            if status_of(sha) != "new":
                continue
            deps = (t.get("links") or {}).get("dependsOn") or []
            if not all(dep_done(d) for d in deps):
                continue
            # See next.py for the rationale on the parent-claim gate.
            if not parent_claimed(t):
                continue
            candidate = t
            break

        if candidate is None:
            return 0  # queue empty

        sha = candidate["text_sha256"]
        # Race-safe claim: hashharness's native `chain_predecessor` on
        # `prevStatus` compare-and-swaps the head; if another agent
        # claimed first, append_claim raises ClaimLost and we retry.
        prev_record_sha = store.latest_status(sha)["record_sha256"]
        try:
            store.append_claim(sha, "pull", prev_record_sha)
        except store.ClaimLost:
            sys.stderr.write(f"pull: race lost on {sha[:16]} (attempt {attempt+1}/{args.max_retries+1})\n")
            continue

        attrs = candidate.get("attributes") or {}
        slug = attrs.get("slug") or ""
        # Match against attributes.body — that's where the human-written
        # body lives. Task.text is the canonical content-address
        # (`task:<queue>/<slug>`) and never contains the workflow
        # command. Falls back to task.text for legacy tasks created
        # before the body migration.
        text = attrs.get("body") or candidate.get("text") or ""
        m = pat.search(text)
        idea_path = m.group(1) if m else ""

        print(f"TASK={shell_quote(sha)}")
        print(f"IDEA_PATH={shell_quote(idea_path)}")
        print(f"SLUG={shell_quote(slug)}")
        return 0

    sys.stderr.write(f"pull: all {args.max_retries+1} attempts lost races\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
