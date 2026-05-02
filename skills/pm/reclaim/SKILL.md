---
name: pm-reclaim
description: >
  Force-reclaim a stuck working task — append TaskStatus(new, reclaimed=true)
  so a fresh worker can pick it up. Supervisor / human override; refuses if
  the task isn't currently working. With --cascade also reclaims every
  working descendant via parentTask reverse-links. Use when a worker died
  holding a claim (and you don't want to wait for sweep TTL), or when a
  sticky chain's session needs to be released as a subtree.
---

# pm:reclaim — force-release a stuck working claim

## Procedure

`../scripts/pm reclaim --task <task-sha> [--reason TEXT] [--reclaimer ID] [--cascade]`

- Reads the latest TaskStatus for `<task-sha>`. **Refuses with exit 6**
  if the task isn't in `working` (terminal tasks are absorbing; tasks
  in `new` are already reclaimable, no operation needed).
- Appends a `TaskStatus(new, reclaimed=true, reclaimer=<id>)` — the
  task returns to the pool for `pm next` to pick up.
- With `--cascade`: walks `parentTask` reverse-links (DFS, visited-set
  cycle-break) and force-reclaims every descendant that is currently
  `working`. Skips `new`/`done`/`rejected`/`superseded` descendants
  (only working subtasks have a lease to release).

## When to use this vs `pm sweep`

- **`pm sweep`** is the periodic, race-safe automatic path. It only
  reclaims tasks past the heartbeat TTL and uses a preempt-heartbeat
  protocol so a still-live worker can't be wrongly evicted.
- **`pm reclaim`** is the manual, immediate override. Use when you
  KNOW the worker is dead (e.g., the agent process crashed visibly,
  the host went away, or a sticky chain needs to be unstuck right now).
  No TTL gating, no preempt — the operator is asserting authority.

## Cascade properties (formally verified)

The `--cascade` walk is `parentTask`-reverse, depth-first, with a
visited set. Six properties are verified in
`system-models/planning_reclaim_cascade.als`:

- **RC1 NoWorkingDescendantLeftWorking** — every `working` descendant
  of the root ends up `new` with no owner.
- **RC2 NewDescendantsUntouched** — descendants already in `new` are
  not touched (nothing to reclaim — no one owns them).
- **RC3 TerminalDescendantsUntouched** — descendants in `done`/
  `rejected` stay where they were (nothing to reclaim).
- **RC4 CascadeIsParentTransitive** — A→B→C, reclaiming A reaches C
  if all three are working.
- **RC5 NonDescendantUntouched** — sibling subtrees are isolated.
- **RC6 ReclaimRefusesNonWorkingRoot** — reclaim on a root not in
  `working` exits 6 without entering the cascade DFS.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Reclaim succeeded (and any cascade) |
| 6 | Task not in `working` — refused |

## Notes

- `attributes.reclaimer = <id>` on the new TaskStatus records who
  triggered the override. Useful for post-mortem.
- For automatic dead-worker recovery, prefer `pm sweep` — it's
  race-safe against live workers via the preempt-heartbeat protocol.
- For "kill this subtree forever" semantics (rather than "release the
  leases"), use `pm cancel --cascade` instead.
