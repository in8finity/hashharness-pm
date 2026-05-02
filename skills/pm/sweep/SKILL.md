---
name: pm-sweep
description: >
  Scan a queue for zombie tasks (working but stale) and reclaim them.
  A task is stale when its last activity (latest TaskStatus / TaskReport
  / TaskHeartbeat by created_at) is older than --ttl seconds. Each
  reclaim is race-safe against a still-live worker via a preempt
  heartbeat (chain_predecessor on prevHeartbeat). Use when a queue has
  been running long enough that some workers may have died holding
  working leases, or as a periodic supervisor task.
---

# pm:sweep — reclaim stale working tasks

## Procedure

`../scripts/pm sweep [--queue Q] [--ttl SECONDS] [--reclaimer ID] [--dry-run]`

- Walks every task in `--queue` (default `default`).
- For each task whose latest TaskStatus is `working`, computes
  `age = now - last_activity_at(task)` where `last_activity_at` is the
  max `created_at` across the task's TaskStatus, TaskReport, and
  TaskHeartbeat chains.
- Tasks with `age <= --ttl` (default 300s) are skipped.
- Stale tasks are reclaimed: a TaskStatus(`new`, `reclaimed=true`,
  `reclaimer=<id>`) is appended, and `pm next` will return them again.
- `--dry-run` reports what would be reclaimed without writing.
- Always exits 0 (reclaim of an individual task may be skipped due to a
  race — see "Race-safety" below).

## Race-safety: preempt heartbeat

Before reclaiming, the sweep snapshots the task's TaskHeartbeat chain
tip, then asks `store.reclaim` to write a "preempt heartbeat" with
`prevHeartbeat = that snapshot` BEFORE appending the reclaim status. If
a still-live worker raced and committed a heartbeat between the snapshot
and the preempt, hashharness's `chain_predecessor` rejects the preempt
with 'head moved' → `WorkerStillAlive` → the sweep skips that task and
records it under `raced` in the JSON output.

This closes the TTL-window race: a sweep cannot wrongly evict a worker
that is still heartbeating, even if the freshness snapshot was taken
during a slow heartbeat round.

The matching formal property is `LiveHeartbeatBlocksReclaim` in
`system-models/planning_lease.als`.

## Operational caveat: heartbeat interval < TTL

The sweep treats "no activity for `--ttl` seconds" as evidence that the
worker is dead. A live worker that fails to heartbeat fast enough WILL
be reclaimed (this is the documented model gap
`LiveWorkerCanBeReclaimedIfSilent` in `planning_lease.als`).

Configure your worker loop so that `heartbeat_interval` is comfortably
less than `--ttl`. Rule of thumb: at least 3× margin (e.g.
heartbeat every 60s with `--ttl 300`).

## Output

```json
{
  "scanned": 12,
  "stale": 3,
  "reclaimed": [{"task": "...", "slug": "...", "age_seconds": 380,
                 "last_activity": "...", "reclaim_status_sha": "..."}],
  "raced": [{"task": "...", "slug": "...", "age_seconds": 305,
             "last_activity": "..."}],
  "dry_run": false,
  "ttl": 300
}
```

`raced` lists tasks the sweep targeted but skipped because a heartbeat
beat the preempt — i.e. the worker was alive after all.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Sweep complete (with or without reclaims; per-task races also surface as exit 0 — see `raced` in the JSON output) |

## Notes

- Sweep is safe to run from a cron / supervisor agent / `pm-execute`
  worker — it doesn't claim any tasks itself.
- Two sweeps running concurrently against the same queue serialize via
  `chain_predecessor` on the TaskStatus chain: only one can append the
  reclaim status; the other gets `HeadMoved`.
