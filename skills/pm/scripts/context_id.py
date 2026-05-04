#!/usr/bin/env python3
"""Generate a fresh context UUID for a worker session.

Sticky tasks are bound to a context at first claim. The agent that
claimed must produce the same context id on every subsequent call
(heartbeat, report, finished) for the lifetime of the binding.
Reclaim strips the binding; sweep reclaim does the same.

Usage:
  pm context-id            # bare UUID — for capturing into env
  pm context-id --export   # `export PM_CONTEXT_ID=<uuid>` — eval-friendly

Two ways to thread it into pm subcommands — pick by execution context:

  Interactive shell (humans):
      export PM_CONTEXT_ID=$(pm context-id)
      pm executing --task ...
      pm report    --task ...

  Sub-agents under a permission allowlist:
      Use the --context-id flag, or inline-env, NOT export-then-call.
      A pattern like `Bash(pm executing *)` won't match `export X=Y;
      pm executing ...` (different command shape) and the sub-agent
      gets a permission denial it can't recover from. Both of these
      DO match an allowlist for `pm executing`:

          pm executing --task TASK --context-id $CTX
          PM_CONTEXT_ID=$CTX pm executing --task TASK

      Mint the context once at the orchestrator, pass it down as an
      explicit string the sub-agents stamp onto each call.
"""
from __future__ import annotations

import argparse
import sys
import uuid


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--export", action="store_true",
                   help="emit `export PM_CONTEXT_ID=...` for shell eval")
    args = p.parse_args()
    cid = str(uuid.uuid4())
    print(f"export PM_CONTEXT_ID={cid}" if args.export else cid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
