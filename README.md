# hashharness-pm

A planning board for parallel agents — twelve Claude Code skills + a `pm` CLI dispatcher backed by [hashharness](https://github.com/in8finity/hashharness)'s append-only hash-chained storage.

The system was designed against a formal model. The model is in this repo. Three structural fixes that landed (claim race-safety, slug uniqueness, and the migration of claim-race resolution to hashharness's native `chain_predecessor` head-move check) were each driven by counterexamples or properties the model produced before the code changed.

## Goal

Give LLM agents a durable substrate for controlling the execution of complex skills and multi-step tasks: a shared planning board where one agent can decompose work into dependent tasks, hand them off to parallel workers, supervise progress through immutable status and report chains, and replan or cancel mid-flight — without losing track of who claimed what, what was proven done, and what is still blocked. The append-only storage and explicit claim protocol exist so that an agent driving a long-running skill can reason about the queue's state at any point and recover deterministically across restarts.

## Use cases

### 1. Planning tooling

Treat the queue as a first-class planning surface for an agent (or a human supervising one). `pm-plan` enqueues tasks with body, verifier, and `dependsOn[]` links; `next` returns the next runnable task once its dependency chain is `done`; `pm-replan` restarts a task and its ancestors when the chain breaks; `pm-cancel` terminates a task and cascades to unfinished subtasks. Subtasks link back to the parent's TaskStatus current at spawn time, so the decomposition is reconstructible from storage alone — useful for breaking a large objective into a dependency graph, handing pieces to parallel workers, and supervising progress without external state.

### 2. Executing a skill in a controlled manner

Two skills wrap the queue to drive *another* skill's documented flow as a sequence of tasks (one task per SKILL.md step, chained by `dependsOn`):

- **Auto** (`pm-auto-skill-execution`) — hands-off run. Every choice the target skill would normally ask the user about is resolved to its documented default; the choice and reasoning are recorded in the task report. Best for routine runs, batch processing, and well-understood skills.
- **Guided** (`pm-guided-skill-execution`) — step-by-step with user-in-the-loop gates. Pauses after each step to surface decisions, accept user-supplied subtask requests, and confirm before moving on. Best for novel problems and sign-off gates.

Both modes give the same audit trail — immutable status chain plus proof-of-work reports per step — so a long-running skill execution can be paused, resumed, or replanned mid-flight without losing what was already proven done. `pm-execute` then drains the resulting queue with N parallel workers when steps are independent.

### 3. Sticky sessions — pin a chain to one agent context

A task planned with `--sticky` binds its TaskStatus chain to whichever agent context first claims it (the binding is recorded as `context_id` on the working-status record). Subsequent claims, reports, heartbeats, and finishes against that task — and any sticky descendants in its parent / dependency chain — must come from the same `$PM_CONTEXT_ID`; mismatches refuse with exit 10. Use it when the work needs continuity that survives across calls but mustn't drift across agents: an in-progress refactor with uncommitted edits in a worktree, a debugging session holding open browser/REPL state, a scratchpad an agent has been building up. The `StickyChainCoherence` and `StickyBindingOnlyAtClaim` properties are formally verified in `system-models/planning.als`.

### 4. Workdir-scoped queues — one hashharness backend, many workspaces

`pm plan` records `os.path.realpath(cwd)` (or `$PM_WORKDIR`) into `task.attributes.workdir` at plan time, and `pm next` filters out tasks whose workdir doesn't match the caller's. The result: a single hashharness instance can host queues for many independent workspaces without cross-talk — a worker started in `~/projects/A` only ever pulls tasks planned from `~/projects/A`, even if `~/projects/B` is also using the same backend. Subtasks inherit the parent's workdir so a planner in one repo can spawn children that stay scoped there. Useful for developer machines running multiple projects against shared hashharness storage, or for sandboxed worker pools that should only see tasks scoped to their assigned workspace.

### 5. Supervisor recovery — cancel, replan, reclaim

Long-running queues develop pathologies: a worker dies mid-claim, a task gets stuck because its dependency was resolved wrong, a whole subtree needs to be redone with adjusted parameters. Three supervisor primitives handle each case:

- **`pm-cancel`** terminates a task (and optionally cascades to unfinished subtasks) regardless of ownership; synthesizes a `TaskReport` carrying the cancel reason so the closing `rejected` status still satisfies the proof-of-work invariant.
- **`pm-replan`** restarts a task — and by default its dependency-chain ancestors — by appending a fresh `new` status, so a different worker can pick the chain up from the start. Supports body / verifier edits via `--text` / `--verifier` (clone-and-supersede mode).
- **`pm sweep` + `store.reclaim`** detect heartbeat-stale claimants (the worker process died holding a `working` status), append a `new` status with `reclaimed=true`, and let the queue route the task to a healthy worker. Verified in `system-models/planning_lease.als` against crash interleavings.

These keep an autonomous queue self-healing without requiring an operator to surgically edit storage when something goes wrong.

## Similar systems

The closest direct comparators are agent orchestration frameworks. The workflow tools below are included separately because they are not agent-first products, even though they are now used to run agent workloads.

### Direct agent orchestration frameworks

| System | Primary abstraction | Persistence / state | Multi-agent patterns | Worker claiming | Proof / report chain | Formal protocol model |
|---|---|---|---|---|---|---|
| **hashharness-pm** | Task + TaskStatus + TaskReport | Append-only hash-chained items in hashharness | Parallel worker queue with dependencies | Explicit `next` / `executing` claim protocol | Yes, first-class | Yes, Alloy/Dafny in repo |
| [OpenAI Agents SDK](https://platform.openai.com/docs/guides/agents-sdk/) | Agents, tools, handoffs | Run state and traces in SDK/runtime | Managers, handoffs, agents-as-tools | No queue claim primitive | No | No |
| [LangGraph](https://docs.langchain.com/oss/python/langgraph/overview) | Stateful agent graph | Checkpointed graph state | Single, multi-agent, hierarchical graphs | No queue claim primitive¹ | No | No |
| [CrewAI](https://docs.crewai.com/en/introduction) | Crews, flows, tasks | Framework-managed run state | Sequential, hierarchical, hybrid crews | No queue claim primitive | No | No |
| [AutoGen](https://microsoft.github.io/autogen/stable/user-guide/core-user-guide/core-concepts/agent-and-multi-agent-application.html) | Message-passing agents | Agent-local state + runtime messaging | Multi-agent conversations and patterns | No queue claim primitive | No | No |
| [Semantic Kernel Agent Orchestration](https://learn.microsoft.com/en-us/semantic-kernel/frameworks/agent/agent-orchestration/) | Agents + orchestration runtime | Runtime-managed orchestration state | Concurrent, sequential, handoff, group chat | No queue claim primitive | No | No |
| [Mastra](https://mastra.ai/agents) | Agents, workflows, agent networks | Stateful agent runtime | Workflows and agent networks | No queue claim primitive | No | No |

¹ LangGraph the library has no task queue; durable queueing was deliberately moved to the separate hosted [LangGraph Platform](https://blog.langchain.com/building-langgraph/), which manages execution internally rather than exposing a worker pull-and-claim API.

### Adjacent workflow/orchestration systems used for agents

These are credible comparisons on durability, retries, and state management, but they are broader workflow products rather than small agent coordination layers:

| System | Core fit | Why it is still relevant here | Evidence of agent usage |
|---|---|---|---|
| [Temporal](https://temporal.io/) | Durable workflow engine | Strong match on long-running state, retries, task queues, and failure recovery | [AI agents overview](https://ai.temporal.io/), [AI/agent workflow articles](https://temporal.io/blog/categories/Using%20Temporal) |
| [Prefect](https://www.prefect.io/docs) | State-oriented workflow orchestration | Strong match on dynamic state transitions and human-in-the-loop workflows | [AI Teams page](https://www.prefect.io/solutions/agents), [Pydantic AI integration article](https://www.prefect.io/blog/prefect-pydantic-integration) |

For storage-model analogues rather than orchestration analogues, [git-bug](https://github.com/git-bug/git-bug) and [Radicle](https://radicle.xyz/) are closer to the immutable collaborative-object side of the design than to the agent-coordination side.

In short: `hashharness-pm` is a small, storage-first coordination layer for parallel coding agents. It overlaps with agent frameworks on orchestration, and with workflow engines on durability, but is more explicit than either about immutable task records, claim races, and proof-of-work closure.

## Layout

```
hashharness-pm/
├── skills/
│   └── pm/                          # Twelve Claude Code skills + shared scripts
│       ├── plan/SKILL.md                    # pm-plan        — enqueue a task
│       ├── next/SKILL.md                    # pm-next        — pull next runnable task
│       ├── executing/SKILL.md               # pm-executing   — claim a task
│       ├── report/SKILL.md                  # pm-report      — submit proof of work
│       ├── finished/SKILL.md                # pm-finished    — close as done/rejected
│       ├── execute/SKILL.md                 # pm-execute     — spawn N parallel workers
│       ├── cancel/SKILL.md                  # pm-cancel      — supervisor override: terminate + cascade to subtasks
│       ├── replan/SKILL.md                  # pm-replan      — restart a task (and dep-chain ancestors) from scratch
│       ├── heartbeat/SKILL.md               # pm-heartbeat   — keep a working claim alive (exit 12 if lease lost)
│       ├── sweep/SKILL.md                   # pm-sweep       — reclaim stale working tasks; race-safe via preempt heartbeat
│       ├── auto-skill-execution/SKILL.md    # pm-auto-skill-execution    — drive another skill end-to-end, no prompts
│       ├── guided-skill-execution/SKILL.md  # pm-guided-skill-execution  — drive another skill with user-in-the-loop gates
│       ├── skill-shared/extract_steps.py    # SKILL.md step extractor used by auto/guided
│       ├── scripts/
│       │   ├── pm                       # bash dispatcher
│       │   ├── plan.py / next.py / executing.py / report.py / finished.py   # worker-loop primitives
│       │   ├── replan.py / cancel.py / sweep.py / reclaim.py / heartbeat.py # supervisor primitives
│       │   ├── pull.py                  # atomic next + claim with race retry
│       │   ├── store.py                 # hashharness write helpers + HeadMoved/SlugTaken/ClaimLost
│       │   ├── mcp_client.py            # JSON-RPC over HTTP (tool / tool_safe)
│       │   ├── setup_schema.py          # registers Task/TaskStatus/TaskReport/TaskHeartbeat
│       │   ├── schema_fragment.json     # schema with chain_predecessor links
│       │   ├── context_id.py            # PM_CONTEXT_ID generator (sticky-session id)
│       │   ├── bulk_plan.py / heal_orphans.py / queue_status.py             # operator helpers
│       │   ├── stress_claim_race.py     # race smoke-tester
│       │   └── now_iso.py
│       └── README.md
├── system-models/
│   ├── planning.als                 # core protocol model (13 checks)
│   ├── planning_lease.als           # ownership liveness + heartbeat-vs-reclaim race (6 checks)
│   ├── planning_plan_race.als       # slug-race verifier (1 check)
│   ├── planning_replan.als          # replan semantics: 4 modes + supersede + cascade-up (8 checks)
│   ├── planning_cancel_cascade.als  # cancel --cascade correctness: parent-reverse closure (6 checks)
│   ├── planning.dfy                 # Dafny port of planning.als — unbounded proofs
│   ├── planning_plan_race.dfy       # Dafny port of planning_plan_race.als
│   ├── model-isomorphism-check.md   # mapping note for related agent frameworks
│   └── reports/
│       ├── planning-reconciliation.md       # model ↔ code/skills cross-source audit
│       ├── planning-enforcement.md          # gate audit chain across model/code/skills/tests
│       ├── alloy-dafny-reconciliation.md    # Alloy ↔ Dafny coverage diff
│       ├── planning-blind-spots.md          # known gaps & open questions
│       └── cache-staleness-investigation.md # historical: pre-migration claim-race investigation
└── tests/
    └── integration/test_golden.py    # 17 golden-flow live integration tests
```

## Storage model (hashharness)

Four item types are registered in the planning schema:

| Type | `text` | Key attributes | Links |
|---|---|---|---|
| **Task** | `task:<queue>/<slug>` (canonical key — slug uniqueness is structural) | `slug`, `queue`, `body`, optional `verifier`, `sticky`, `workdir` | `parentTask`, `spawnedAt → TaskStatus`, `dependsOn[]` |
| **TaskStatus** | `<note>\n#nonce:<random>` | `status ∈ {new, working, done, rejected, superseded}`; sticky claims also carry `context_id`; reclaim/cancel close-out statuses carry `reclaimed` / `cancelled` flags | `task`, `prevStatus` (chain_predecessor), `proof → TaskReport` |
| **TaskReport** | the user's report body | (none — body is the proof) | `task`, `prevReport` (chain_predecessor) |
| **TaskHeartbeat** | `hb:<task[:8]>:<agent>\n#nonce:<random>` | `agent` | `task`, `claimStatus → TaskStatus(working)`, `prevHeartbeat` (chain_predecessor) |

Four chains exist per task: status, report, heartbeat, and (for subtasks) `parentTask` plus `spawnedAt` to the parent's TaskStatus current at spawn time. The three `chain_predecessor` links are the load-bearing race-resolution gate — hashharness compare-and-swaps the per-(work_package_id, type) head pointer on every append, rejecting stale writes with 'head moved'.

## Quick start

1. **Run hashharness in HTTP mode** (separate terminal):
   ```bash
   HASHHARNESS_MCP_TRANSPORT=http \
   HASHHARNESS_HTTP_PORT=38417 \
   HASHHARNESS_DATA_DIR=$HOME/.hashharness/data \
   python -m hashharness.mcp_server
   ```
2. **Register the planning schema** (once per data dir):
   ```bash
   skills/pm/scripts/pm setup
   ```
3. **Use the skills** — invoke through Claude Code via `pm-plan`, `pm-next`, `pm-executing`, `pm-report`, `pm-finished` (or `pm-replan`, `pm-cancel`, `pm-execute`, `pm-heartbeat`, `pm-sweep`, `pm-auto-skill-execution`, `pm-guided-skill-execution`), or call `pm` directly:
   ```bash
   pm plan --title "Build X" --text "Detailed description..."
   pm next                       # pulls the next runnable task
   pm executing --task <sha>     # claim it
   pm report --task <sha> --title "done" --text-file out.md
   pm finished --task <sha>      # close (requires a report)
   ```

The skills read `HASHHARNESS_MCP_URL` (default `http://127.0.0.1:38417/mcp`).

## Concurrency guarantees (formally verified)

The Alloy models prove these hold under any interleaving of parallel agents using `pm`:

| Property | Where enforced |
|---|---|
| Done/rejected is absorbing — a finished task never transitions out | `finished.py` rejects unless current is `working`/`new`; `cancel.py` exit 6 on terminal |
| A terminal status always has a `proof` link to a TaskReport | `finished.py` refuses without a report → exit 7; `cancel_task` synthesizes proof before the rejected status |
| At most one agent owns the latest TaskStatus of a task | hashharness `chain_predecessor` on `prevStatus` (compare-and-swap on the TaskStatus head) → `HeadMoved` → `ClaimLost` → `executing.py` exit 8 |
| Dependencies are `done` at the moment a task is claimed | `next.py` skips blocked tasks |
| Verifier-required tasks cannot reach `done` without a passing verifier | `finished.py` runs the verifier and refuses on non-zero exit → exit 9 |
| Sticky chains stay bound to one agent context | `store.check_sticky_eligibility`; refusal exit 10 across `executing`/`heartbeat`/`report`/`finished` |
| A live worker is never wrongly reclaimed (heartbeat-vs-reclaim race) | `sweep.py` snapshots the heartbeat tip, then `store.reclaim(preempt_heartbeat=True, …)` writes a preempt heartbeat first; `chain_predecessor` on `prevHeartbeat` rejects if a worker raced → `WorkerStillAlive` → sweep aborts (`LiveHeartbeatBlocksReclaim`, `ReclaimRequiresStableHeartbeatChain` in `planning_lease.als`) |
| Zombie heartbeats from displaced agents are refused | `heartbeat.py` checks current working status's `agent` matches `--agent` → exit 12 if not |
| A dead worker's task is recoverable | `sweep.py` reclaims tasks past heartbeat TTL; `store.reclaim` appends `new` status with `reclaimed=true` (`NoZombieAfterReclaim`) |
| Two parallel `pm plan` calls cannot both create the same slug | `Task.text` is `task:<queue>/<slug>`; hashharness rejects duplicate `text_sha256` → `SlugTaken` → exit 4 |
| Every claim attempt eventually resolves (commit or abort) | `executing.py` always exits 0/6/8/10 |

Both race conditions are content-addressed gates inside hashharness: slug uniqueness rides the `text_sha256` index, and claim ordering rides the per-(work_package_id, type) `chain_predecessor` head pointer. The scripts plumb those structural rejections up to the operator-visible exit codes.

## Worker loop (`pm` agents)

```
1. pm next --queue <Q>             → JSON or "null"
2. pm executing --task TASK        → exit 0 win | 6 pre-claim refusal | 8 race-lost | 10 sticky-context refusal
3. read task.attributes.body, do the work
4. pm report --task TASK --title T --text-file ...
5. pm finished --task TASK         → exit 0 done | 7 missing report | 9 verifier failed | 10 sticky-context refusal
```

`pm plan` itself can also exit 4 (slug already taken in this queue). `pm execute` (the `pm-execute` skill) spawns N agents in parallel running this loop.

## Threat model

The formal model verifies the protocol assuming every state transition goes through `pm`. A client writing directly to hashharness via MCP can bypass most assertions (state-machine ordering, proof-of-work, dep gate, sticky-context check, verifier gate). What survives a bypass is the storage layer: item immutability, schema link types, link-target existence, `text_sha256` uniqueness on the canonical slug key, and `chain_predecessor` head-move enforcement on `prevStatus` / `prevReport` / `prevHeartbeat` (so even a bypass can't double-claim or fork a chain).

For cooperative-agent usage (the actual use case), convention is sufficient. See `system-models/reports/planning-reconciliation.md#threat-model` for hardening options if adversarial bypass becomes a concern.

## Re-running the model

```bash
# Bring the formal-methods skill's runner along:
verify=~/.claude/plugins/cache/morozov-claude-plugin/formal-methods/1.3.0/skills/formal-modeling/scripts/verify.sh

# Alloy (bounded counterexamples + scenarios)
bash $verify system-models/planning.als            # 13 checks, 11 SAT runs + 2 expected-UNSAT
bash $verify system-models/planning_lease.als      # 6 checks, 5 SAT runs + 2 expected-UNSAT
bash $verify system-models/planning_plan_race.als  # 1 check, 1 expected-UNSAT
bash $verify system-models/planning_replan.als     # 8 checks, 4 SAT runs + 2 expected-UNSAT
bash $verify system-models/planning_cancel_cascade.als  # 6 checks, 3 SAT runs + 1 expected-UNSAT

# Dafny (unbounded inductive proofs over the same protocol)
bash $verify system-models/planning.dfy            # 14 lemmas + 23 functions
bash $verify system-models/planning_plan_race.dfy  # 5 lemmas
```

To reproduce the historical slug-race counterexample, swap `commitPlan[p]` for `commitPlanBuggy[p]` in `planning_plan_race.als`'s `Transitions` fact and re-run; the counterexample re-appears in 4 steps.

## Reports

- `system-models/reports/planning-reconciliation.md` — per-property cross-source consistency table (model ↔ code ↔ skills ↔ schema), threat model, boundary review.
- `system-models/reports/planning-enforcement.md` — for each verified property, the gate audit chain across model / code / skill texts / integration tests, plus the storage-layer gate-artifact check.
- `system-models/reports/alloy-dafny-reconciliation.md` — Alloy ↔ Dafny coverage diff (which properties live in which formalism, and which Alloy-only layers haven't been ported yet).
- `system-models/reports/planning-blind-spots.md` — known modeling gaps and open design questions.
- `system-models/reports/cache-staleness-investigation.md` — historical artifact: the pre-migration claim-race investigation that motivated the move to `chain_predecessor`. Kept for context, not a current-state document.

## Acknowledgments

- [hashharness](https://github.com/in8finity/hashharness) — append-only text store with MCP server.
- The Alloy 6 model and reports were produced by the [`formal-modeling`](https://github.com/in8finity/claude-plugin) skill.
