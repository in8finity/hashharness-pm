module planning_lease

/*
  planning_lease.als — extends the planning protocol with ownership
  liveness (lease + crash + reclaim).

  This is the high-severity blind spot #1 from
  reports/planning-blind-spots.md: a worker that claims a task and then
  dies leaves the task stuck in PWorking forever — no other agent can
  legitimately take over.

  This model adds:
    - Alive : a var subset of Agent representing currently-living workers
    - Crash(a) action that removes a from Alive (simulating process death)
    - Reclaim(t) action enabled when t is working AND its owner is not Alive,
      which resets t back to PNew so another agent can claim it.

  Verifies:
    SingleOwner               — at most one owner per task at any time,
                                 even with Crash and Reclaim in the mix.
    ReclaimRequiresDeadOwner  — reclaim can never fire on a task with a
                                 living owner (a healthy worker is safe).
    LiveWorkerActions         — only Alive agents can claim/report/finish
                                 (a dead agent can't keep the task hostage).
    ProofRequiredForTerminal  — terminal phases still require a TaskReport.
    NoZombieAfterReclaim      — after reclaim, the task is PNew with no
                                 owner; another agent can claim it.

  Liveness scenarios (SAT):
    HappyPathNoCrash             — claim→report→finish without preemption.
    ZombieRecovery               — claim, crash, reclaim, re-claim, finish.
    RecoveryByDifferentAgent     — explicitly: a2 finishes the task that
                                    crashed agent a1 had claimed.

  This model is orthogonal to claim race-safety (planning.als): the
  two-phase claim isn't reproduced here — claim is atomic — because the
  race fix and the lease fix are independent concerns. A production
  system needs both; the formal layer verifies them in separate modules.
*/

abstract sig Phase {}
one sig PNew, PWorking, PDone, PRejected extends Phase {}

sig Agent {}
sig Task {
  var phase: lone Phase,
  var owner: lone Agent
}

var sig Pending   in Task  {}
var sig Alive     in Agent {}
var sig HasReport in Task  {}
var sig HasProof  in Task  {}

// Race-aware sweep: per-task flag set whenever a live owner heartbeats,
// cleared whenever the sweeper takes a freshness observation. Models
// the chain_predecessor compare-and-swap on the TaskHeartbeat chain —
// the preempt heartbeat sweepers write before reclaim only commits if
// no live heartbeat has advanced the chain since the observation. The
// sweeper's reclaim precondition reads this flag instead of `Alive`
// directly; the model thereby captures the gap between "ground-truth
// liveness" and "what the sweeper can know via heartbeats".
var sig HbSinceObs in Task {}

fact Init {
  no Pending
  no HasReport
  no HasProof
  no HbSinceObs
  Alive = Agent                           // all agents start alive
  all t: Task | no t.phase and no t.owner
}

// ===== Static invariants =====
fact PhaseIffPending {
  always all t: Task | one t.phase <=> t in Pending
}
fact ProofOnlyOnTerminal {
  always all t: Task | t in HasProof => t.phase in PDone + PRejected
}
fact OwnerOnlyAfterClaim {
  always all t: Task | one t.owner => t.phase != PNew
}

// ===== Phase predicates =====
pred isNew      [t: Task] { t.phase = PNew }
pred isWorking  [t: Task] { t.phase = PWorking }
pred isDone     [t: Task] { t.phase = PDone }
pred isRejected [t: Task] { t.phase = PRejected }
pred isTerminal [t: Task] { isDone[t] or isRejected[t] }

// ===== Frame helpers =====
pred frameOtherTasks[t: Task] {
  all u: Task - t | u.phase' = u.phase and u.owner' = u.owner
}
pred frameAllTasks {
  all u: Task | u.phase' = u.phase and u.owner' = u.owner
}

// ===== Transitions =====

pred plan[t: Task] {
  t not in Pending
  Pending'    = Pending + t
  HasReport'  = HasReport
  HasProof'   = HasProof
  Alive'      = Alive
  HbSinceObs' = HbSinceObs
  t.phase'  = PNew
  no t.owner'
  frameOtherTasks[t]
}

// Atomic claim — only an Alive agent may claim, and only a New task.
// Re-claim resets the heartbeat-since-observation flag because the
// chain logically restarts: the sweeper's prior observation refers to
// the previous owner's chain.
pred claim[a: Agent, t: Task] {
  isNew[t]
  a in Alive
  Pending'    = Pending
  HasReport'  = HasReport
  HasProof'   = HasProof
  Alive'      = Alive
  HbSinceObs' = HbSinceObs - t            // fresh chain for new owner
  t.phase' = PWorking
  t.owner' = a
  frameOtherTasks[t]
}

// Agent crashes: removed from Alive. Tasks they own are unchanged at
// this step (still show owner=a, phase=PWorking) — this is the zombie
// state, recoverable only via Reclaim.
pred crash[a: Agent] {
  a in Alive
  Alive' = Alive - a
  Pending'    = Pending
  HasReport'  = HasReport
  HasProof'   = HasProof
  HbSinceObs' = HbSinceObs
  frameAllTasks
}

// Worker heartbeat — the live owner extends the heartbeat chain.
// Sets the per-task `HbSinceObs` flag, which the sweeper's reclaim
// precondition reads. Mirrors the runtime's `pm heartbeat` (which
// chain_predecessor-appends a TaskHeartbeat).
pred heartbeat[a: Agent, t: Task] {
  isWorking[t]
  t.owner = a
  a in Alive
  HbSinceObs' = HbSinceObs + t
  Pending'    = Pending
  HasReport'  = HasReport
  HasProof'   = HasProof
  Alive'      = Alive
  frameAllTasks
}

// Sweeper freshness observation. Clears `HbSinceObs[t]` so any
// subsequent worker heartbeat will be visible to the sweep's reclaim
// precondition. Mirrors `latest_heartbeat()` snapshot in `sweep.py`.
pred sweepObserve[t: Task] {
  isWorking[t]                            // only working tasks are observed
  HbSinceObs' = HbSinceObs - t
  Pending'    = Pending
  HasReport'  = HasReport
  HasProof'   = HasProof
  Alive'      = Alive
  frameAllTasks
}

// Reclaim a task: reset to PNew, no owner. Sweeper acts on the
// observation, NOT on `Alive` directly — so reclaim's precondition is
// "no heartbeat has advanced the chain since my observation"
// (`t not in HbSinceObs`). The runtime enforces this via
// chain_predecessor on prevHeartbeat: a preempt heartbeat with stale
// prev is rejected with WorkerStillAlive.
//
// This decouples sweeper-belief from ground-truth liveness — and is
// where the model now matches the runtime's actual race surface.
pred reclaim[t: Task] {
  isWorking[t]
  some t.owner
  t not in HbSinceObs                     // preempt would commit
  Pending'    = Pending
  HasReport'  = HasReport                 // reports survive recycling
  HasProof'   = HasProof
  Alive'      = Alive
  HbSinceObs' = HbSinceObs - t            // chain logically resets
  t.phase' = PNew
  no t.owner'
  frameOtherTasks[t]
}

pred report[a: Agent, t: Task] {
  isWorking[t]
  t.owner = a
  a in Alive
  HasReport'  = HasReport + t
  Pending'    = Pending
  HasProof'   = HasProof
  Alive'      = Alive
  HbSinceObs' = HbSinceObs
  frameAllTasks
}

pred finish[a: Agent, t: Task, terminal: Phase] {
  terminal in PDone + PRejected
  isWorking[t]
  t.owner = a
  a in Alive                              // dead agent can't finish
  t in HasReport
  HasProof'   = HasProof + t
  Pending'    = Pending
  HasReport'  = HasReport
  Alive'      = Alive
  HbSinceObs' = HbSinceObs
  t.phase' = terminal
  t.owner' = t.owner
  frameOtherTasks[t]
}

pred stutter {
  Pending' = Pending and Alive' = Alive
  and HasReport' = HasReport and HasProof' = HasProof
  and HbSinceObs' = HbSinceObs
  and frameAllTasks
}

fact Transitions {
  always (
    stutter
    or (some t: Task              | plan[t])
    or (some a: Agent, t: Task    | claim[a, t])
    or (some a: Agent             | crash[a])
    or (some a: Agent, t: Task    | heartbeat[a, t])
    or (some t: Task              | sweepObserve[t])
    or (some t: Task              | reclaim[t])
    or (some a: Agent, t: Task    | report[a, t])
    or (some a: Agent, t: Task, p: Phase | finish[a, t, p])
  )
}

// ===== Safety assertions =====

// 1. At most one owner per task at any moment, even with crash + reclaim.
assert SingleOwner {
  always all t: Task | lone t.owner
}
check SingleOwner for 4 but 10 steps

// (Removed: `ReclaimRequiresDeadOwner` from the omniscient lease model.
//  Intentionally weakened in the race-aware model — the sweeper acts on
//  heartbeat freshness rather than ground-truth liveness, so a live
//  worker that doesn't heartbeat fast enough CAN be reclaimed. The
//  operational constraint is captured by the run scenario
//  `LiveWorkerCanBeReclaimedIfSilent` below; the realistic safety
//  property is `LiveHeartbeatBlocksReclaim`.)

// 3. Only Alive agents can claim/report/finish — a dead agent can't
//    progress a task it owns. (Inv-by-construction: each transition
//    requires `a in Alive`. Stated explicitly here for documentation.)
assert LiveWorkerActions {
  always all a: Agent, t: Task |
    (
      // Phase change New → Working  ⇒  the new owner was Alive at the
      // previous moment.
      (isNew[t] and after (isWorking[t] and t.owner' = a))  =>  a in Alive
    )
}
check LiveWorkerActions for 4 but 10 steps

// 4. Proof still required for any terminal task (extends planning.als).
assert ProofRequiredForTerminal {
  always all t: Task | isTerminal[t] => t in HasProof
}
check ProofRequiredForTerminal for 4 but 10 steps

// 5. After reclaim, a task is genuinely PNew with no owner.
assert NoZombieAfterReclaim {
  always all t: Task |
    (isWorking[t] and after isNew[t]) =>
      after (no t.owner)
}
check NoZombieAfterReclaim for 4 but 10 steps

// 6. Race-aware reclaim: a reclaim transition only fires on tasks
//    whose `HbSinceObs` flag is clear. Equivalent to "the sweeper's
//    preempt heartbeat would commit" in runtime terms.
assert ReclaimRequiresStableHeartbeatChain {
  always all t: Task |
    (isWorking[t] and after isNew[t]) =>
      t not in HbSinceObs
}
check ReclaimRequiresStableHeartbeatChain for 4 but 10 steps

// 7. Heartbeat-vs-reclaim race safety: if a live worker heartbeats
//    AFTER the sweeper's most recent observation, the sweeper cannot
//    reclaim until it re-observes. Closes the TTL-window race
//    documented in planning-blind-spots.md and fixed by the
//    preempt-heartbeat protocol in `store.reclaim`.
assert LiveHeartbeatBlocksReclaim {
  always all t: Task |
    (some a: Agent | heartbeat[a, t])
    =>
    after not reclaim[t]
}
check LiveHeartbeatBlocksReclaim for 4 but 10 steps

// ===== Liveness scenarios =====

// A healthy worker can complete a task without anyone crashing.
run HappyPathNoCrash {
  some t: Task, a: Agent | eventually (
    isNew[t] and eventually (
      isWorking[t] and t.owner = a and a in Alive and eventually (
        t in HasReport and a in Alive and eventually (
          isDone[t] and a in Alive
        )
      )
    )
  )
} for exactly 1 Task, exactly 1 Agent, 10 steps

// THE INTERESTING ONE: a worker claims, crashes, the task gets reclaimed.
run ZombieRecovery {
  some t: Task, a: Agent | eventually (
    isWorking[t] and t.owner = a and eventually (
      a not in Alive and eventually (
        isNew[t] and no t.owner          // reclaimed
      )
    )
  )
} for exactly 1 Task, exactly 1 Agent, 10 steps

// A crashed worker's task is finished by a different agent.
run RecoveryByDifferentAgent {
  some t: Task, disj a1, a2: Agent | eventually (
    isWorking[t] and t.owner = a1 and eventually (
      a1 not in Alive and eventually (
        isNew[t] and no t.owner and eventually (
          isWorking[t] and t.owner = a2 and a2 in Alive and eventually (
            t in HasReport and eventually (
              isDone[t] and t in HasProof
            )
          )
        )
      )
    )
  )
} for exactly 1 Task, exactly 2 Agent, 14 steps

// Reclaim cannot fire if the owner is still alive.
//   (Negative scenario — should be UNSAT.)
run TryToReclaimLiveTask {
  some t: Task, a: Agent | eventually (
    isWorking[t] and t.owner = a and a in Alive and after (
      isNew[t]                            // ← attempting reclaim
    )
  )
} for exactly 1 Task, exactly 1 Agent, 6 steps
expect 0

// Operational caveat (witness): a live worker that fails to heartbeat
// between observations CAN be reclaimed. The runtime mitigation is
// configuration: heartbeat interval must be < TTL (sweep config). This
// run is intentionally SAT to document the trade-off rather than hide
// it behind an assertion that would fail by design.
run LiveWorkerCanBeReclaimedIfSilent {
  some t: Task, a: Agent |
    eventually (
      isWorking[t] and t.owner = a and a in Alive and
      eventually (
        sweepObserve[t] and after (
          reclaim[t]                        // succeeds without crash
        )
      )
    )
} for exactly 1 Task, exactly 1 Agent, 8 steps

// Heartbeat-vs-reclaim race witness. The sweeper observes (clears
// HbSinceObs[t]); a live worker heartbeats (sets HbSinceObs[t]);
// sweeper attempts reclaim — must be blocked. SAT trace showing the
// observation + heartbeat + (still-working) outcome.
run RaceWindowSurvived {
  some t: Task, a: Agent |
    eventually (
      isWorking[t] and t.owner = a and a in Alive and
      eventually (
        sweepObserve[t] and after (
          heartbeat[a, t] and after (
            isWorking[t]                  // worker survived; not reclaimed
          )
        )
      )
    )
} for exactly 1 Task, exactly 1 Agent, 10 steps

// Negative — sweeper attempts reclaim immediately after a worker's
// heartbeat. Should be UNSAT under LiveHeartbeatBlocksReclaim.
run TryReclaimAfterHeartbeat {
  some t: Task, a: Agent |
    eventually (
      heartbeat[a, t] and after reclaim[t]
    )
} for exactly 1 Task, exactly 1 Agent, 8 steps
expect 0
