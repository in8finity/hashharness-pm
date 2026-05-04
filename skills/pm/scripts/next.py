#!/usr/bin/env python3
"""Return the next runnable task as JSON, or ``null`` if none.

A task is runnable when:
  - its current status is ``new``
  - every task in ``links.dependsOn`` has current status ``done``
  - every direct child (task whose ``parentTask`` link points at this
    one) has reached a terminal status (``done`` / ``rejected`` /
    ``superseded``). Pending children block the parent so a wrapper
    step (e.g. one expanded into a subskill via ``--depth ≥1``) only
    becomes runnable after its expansion completes — preserving the
    "parent rolls up its children" semantic.
  - its ``attributes.workdir`` matches the caller's workdir (or the task
    has no workdir attribute, i.e. legacy / cross-cutting)

The caller's workdir is ``$PM_WORKDIR`` if set, else ``realpath(cwd)``.
Workdir filtering scopes the queue to a workspace: a worker started in
``~/projects/A`` only sees tasks planned from ``~/projects/A``.

Tasks are returned in created_at order (oldest first).

Usage:
  next.py [--queue Q]
"""
from __future__ import annotations

import argparse
import json
import os
import sys

import store


def caller_workdir() -> str:
    return os.path.realpath(os.environ.get("PM_WORKDIR") or os.getcwd())


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--queue", default="default")
    args = p.parse_args()

    here = caller_workdir()

    tasks = store.list_tasks(args.queue)
    tasks.sort(key=lambda t: t.get("created_at", ""))

    # Link values are record_sha256 (hashharness link contract); we key
    # status lookups off text_sha256, so build a one-shot translation.
    record_to_text = {t["record_sha256"]: t["text_sha256"] for t in tasks}

    status_cache: dict[str, str | None] = {}

    def status_of(sha: str) -> str | None:
        if sha not in status_cache:
            status_cache[sha] = store.status_value(store.latest_status(sha))
        return status_cache[sha]

    def dep_done(d_record: str) -> bool:
        d_text = record_to_text.get(d_record)
        if d_text is None:
            # Cross-queue dep or dangling reference — treat as not-done.
            return False
        return status_of(d_text) == "done"

    workdir_skipped = 0
    for t in tasks:
        sha = t["text_sha256"]
        bound = store.task_workdir(t)
        if bound is not None and bound != here:
            workdir_skipped += 1
            continue
        if status_of(sha) != "new":
            continue
        deps = (t.get("links") or {}).get("dependsOn") or []
        if not all(dep_done(d) for d in deps):
            continue
        # Parent-rolls-up gate moved to finish-time. A parent is now
        # claimable as soon as its deps are done — the queue convention
        # is that parents are grouping/contexting nodes, not work nodes,
        # so claiming them early just holds the lifecycle lease. The
        # rollup-summary work belongs in a final child task that depends
        # on every sibling. finished.py refuses to close a parent while
        # any child is still pending (exit 14). See
        # skills/pm/plan/SKILL.md "Parents are grouping nodes" and
        # planning_parent_gate.als#ParentNotFinishedWhilePendingChild.
        print(json.dumps(t, indent=2))
        return 0

    # Diagnostic: if we returned null but the queue had tasks scoped to
    # a different workdir than the caller's, surface that on stderr so
    # the worker doesn't think the queue is empty when it's just
    # invisible. Fixes the "first worker thought queue was empty" foot-
    # gun where PM_WORKDIR isn't set and tasks all have a workdir.
    if workdir_skipped:
        sys.stderr.write(
            f"pm next: filtered {workdir_skipped} task(s) by workdir "
            f"mismatch (caller workdir={here!r}); set PM_WORKDIR=... or "
            f"run from the planner's cwd to see them\n"
        )
    print("null")
    return 0


if __name__ == "__main__":
    sys.exit(main())
