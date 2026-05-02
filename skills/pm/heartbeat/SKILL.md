---
name: pm-heartbeat
description: >
  Append a TaskHeartbeat for a task currently in working phase. Workers
  call this periodically to signal they're still alive on a claim; sweep
  uses heartbeat freshness to detect dead claimants. Refuses if the task
  isn't working (exit 6) or if the current working status is owned by a
  different agent (exit 12 — lease lost). Use from a worker loop while
  holding a claim, on an interval shorter than the configured sweep TTL.
---

# pm:heartbeat — keep a working claim alive

## Procedure

`../scripts/pm heartbeat --task <task-sha> [--agent ID]`

- Reads the latest TaskStatus for `<task-sha>`.
- Refuses with **exit 6** if the latest status is not `working` —
  heartbeat is meaningless on a non-working task.
- Refuses with **exit 12** if the latest working status's
  `attributes.agent` does not equal `--agent` — the lease has been
  taken over by a different worker (e.g. via sweep + reclaim, then a
  fresh `pm executing`). This prevents a zombie worker from writing
  heartbeats that mis-attribute liveness to a new owner.
- On success, appends a TaskHeartbeat with:
  - `attributes.agent = <agent-id>`
  - `links.task = <task-sha>`
  - `links.claimStatus = <current working status record>`
  - `links.prevHeartbeat = <prev heartbeat tip>` (omitted if first)

## Worker loop usage

A worker holding a claim should heartbeat at an interval comfortably
shorter than the sweeper's `--ttl` (rule of thumb: 3× margin — e.g.
heartbeat every 60s with `pm sweep --ttl 300`).

```bash
while true; do
  pm heartbeat --task "$TASK" --agent "$PM_AGENT_ID"
  case $? in
    0) sleep 60 ;;
    6|12) echo "lost lease ($?)"; exit 1 ;;
  esac
done
```

`--agent` defaults to `$PM_AGENT_ID` (or `hostname-pid` if unset). Pass
the same agent id used for the original `pm executing` call — otherwise
exit 12 will fire even though your process is the one that holds the
claim.

## Race-safety

Concurrent heartbeats from the same agent serialize via
`chain_predecessor` on `prevHeartbeat`: only one append per round
becomes the new chain tip; the loser raises `HeadMoved` (which the
caller can ignore — the chain extended, that's the goal).

Concurrent sweep preempt-heartbeats compete on the same chain. If the
sweep's preempt commits first, this heartbeat will see `HeadMoved` and
the next call will surface exit 6 (the sweep follow-on appended a
reclaim TaskStatus, so latest status is no longer `working`).

The lease-loss check (exit 12) is the formal counterpart of the
`heartbeat[a, t]` precondition `t.owner = a` in
`system-models/planning_lease.als`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0  | Heartbeat appended |
| 6  | Task not in `working` phase — heartbeat is meaningless (e.g. reclaimed, finished, cancelled) |
| 12 | Current working status is owned by a different agent — lease lost (zombie heartbeat refused) |

## Notes

- Heartbeats are append-only and chained by `prevHeartbeat`. The chain
  is purely an audit trail + a sync point for the sweep preempt; no
  consumer reads heartbeat *content*.
- `claimStatus` lets a sweeper distinguish heartbeats from a dead claim
  cycle from those of a fresh one in case of post-mortem inspection.
