/*
  planning_lease.dfy — Dafny port of system-models/planning_lease.als.

  Verifies the lease-and-heartbeat-race protocol for traces of any
  length. Self-contained (doesn't import planning.dfy) — different
  abstraction layer:
    * planning.dfy   : two-phase claim with race-safety on TaskStatus
    * planning_lease : atomic claim, models worker liveness (Alive
                       set), and the heartbeat-vs-reclaim race surface

  Maps to: skills/pm/scripts/{sweep,reclaim,heartbeat,store}.py +
            skills/pm/{sweep,reclaim,heartbeat}/SKILL.md.

  Properties proved (mirror planning_lease.als):
    SingleOwner                       — at most one owner per task
    LiveWorkerActions                 — only alive agents can claim
    ProofRequiredForTerminal          — every terminal task has proof
    NoZombieAfterReclaim              — after reclaim, no owner
    ReclaimRequiresStableHeartbeatChain — reclaim's preempt would commit
    LiveHeartbeatBlocksReclaim        — heartbeat after observe blocks reclaim

  Operational caveat captured by the model: a live worker that fails
  to heartbeat between observations CAN be reclaimed. This mirrors
  the Alloy SAT scenario `LiveWorkerCanBeReclaimedIfSilent` — the
  realistic abstraction is that the sweeper acts on heartbeat
  freshness, not on ground-truth liveness.
*/

datatype Phase = PNew | PWorking | PDone | PRejected

ghost predicate IsTerminal(p: Phase) {
  p == PDone || p == PRejected
}

datatype State = State(
  pending:     set<int>,
  phase:       map<int, Phase>,
  owner:       map<int, int>,        // task -> agent
  hasReport:   set<int>,
  hasProof:    set<int>,
  alive:       set<int>,             // currently-living agents
  hbSinceObs:  set<int>              // tasks whose heartbeat chain advanced since last observe
)

datatype Action =
  | Plan(t: int)
  | Claim(a: int, t: int)
  | Crash(a: int)
  | Heartbeat(a: int, t: int)
  | SweepObserve(t: int)
  | Reclaim(t: int)
  | Report(a: int, t: int)
  | Finish(a: int, t: int, terminal: Phase)
  | Stutter

ghost predicate Init(s: State, agents: set<int>) {
  s.pending == {} &&
  s.phase == map[] &&
  s.owner == map[] &&
  s.hasReport == {} &&
  s.hasProof == {} &&
  s.alive == agents &&            // all agents start alive
  s.hbSinceObs == {}
}

ghost predicate Inv(s: State) {
  (forall t :: t in s.pending <==> t in s.phase) &&
  (forall t :: t in s.owner ==> t in s.phase && s.phase[t] != PNew) &&
  (forall t :: t in s.hasProof ==> t in s.phase && IsTerminal(s.phase[t])) &&
  (forall t :: t in s.phase && s.phase[t] == PWorking ==> t in s.owner) &&
  (forall t :: t in s.phase && IsTerminal(s.phase[t]) ==> t in s.hasProof)
}

// ===== Transitions =====

ghost predicate StepPlan(s: State, s': State, t: int) {
  t !in s.pending &&
  s' == s.(
    pending := s.pending + {t},
    phase   := s.phase[t := PNew]
  )
}

ghost predicate StepClaim(s: State, s': State, a: int, t: int) {
  t in s.phase && s.phase[t] == PNew &&
  a in s.alive &&
  s' == s.(
    phase      := s.phase[t := PWorking],
    owner      := s.owner[t := a],
    hbSinceObs := s.hbSinceObs - {t}    // fresh chain for new owner
  )
}

// Agent crashes: removed from alive. Tasks they own remain in
// PWorking (zombie state — recoverable via Reclaim).
ghost predicate StepCrash(s: State, s': State, a: int) {
  a in s.alive &&
  s' == s.(alive := s.alive - {a})
}

// Worker heartbeat. Sets hbSinceObs[t] — sweep's reclaim precondition
// reads this. Mirrors `pm heartbeat` writing to the TaskHeartbeat
// chain (chain_predecessor on prevHeartbeat at the storage layer).
ghost predicate StepHeartbeat(s: State, s': State, a: int, t: int) {
  t in s.phase && s.phase[t] == PWorking &&
  t in s.owner && s.owner[t] == a &&
  a in s.alive &&
  s' == s.(hbSinceObs := s.hbSinceObs + {t})
}

// Sweeper freshness observation. Clears hbSinceObs[t] so any subsequent
// heartbeat will be visible to the next reclaim's precondition.
// Mirrors `latest_heartbeat()` snapshot in sweep.py.
ghost predicate StepSweepObserve(s: State, s': State, t: int) {
  t in s.phase && s.phase[t] == PWorking &&
  s' == s.(hbSinceObs := s.hbSinceObs - {t})
}

// Reclaim: reset to PNew, no owner. Sweeper acts on the observation,
// NOT on `alive` directly — so the precondition reads hbSinceObs.
// Mirrors `pm sweep`'s preempt-heartbeat protocol: a preempt commits
// only if no live heartbeat advanced the chain since the snapshot.
ghost predicate StepReclaim(s: State, s': State, t: int) {
  t in s.phase && s.phase[t] == PWorking &&
  t in s.owner &&
  t !in s.hbSinceObs &&             // preempt would commit
  s' == s.(
    phase      := s.phase[t := PNew],
    owner      := s.owner - {t},
    hbSinceObs := s.hbSinceObs - {t}    // chain logically resets
  )
}

ghost predicate StepReport(s: State, s': State, a: int, t: int) {
  t in s.phase && s.phase[t] == PWorking &&
  t in s.owner && s.owner[t] == a &&
  a in s.alive &&
  s' == s.(hasReport := s.hasReport + {t})
}

ghost predicate StepFinish(s: State, s': State, a: int, t: int, terminal: Phase) {
  IsTerminal(terminal) &&
  t in s.phase && s.phase[t] == PWorking &&
  t in s.owner && s.owner[t] == a &&
  a in s.alive &&
  t in s.hasReport &&
  s' == s.(
    phase    := s.phase[t := terminal],
    hasProof := s.hasProof + {t}
  )
}

ghost predicate Step(s: State, s': State, action: Action) {
  match action {
    case Plan(t) => StepPlan(s, s', t)
    case Claim(a, t) => StepClaim(s, s', a, t)
    case Crash(a) => StepCrash(s, s', a)
    case Heartbeat(a, t) => StepHeartbeat(s, s', a, t)
    case SweepObserve(t) => StepSweepObserve(s, s', t)
    case Reclaim(t) => StepReclaim(s, s', t)
    case Report(a, t) => StepReport(s, s', a, t)
    case Finish(a, t, terminal) => StepFinish(s, s', a, t, terminal)
    case Stutter => s' == s
  }
}

ghost predicate ValidTrace(trace: seq<State>, actions: seq<Action>, agents: set<int>) {
  |trace| >= 1 &&
  |actions| == |trace| - 1 &&
  Init(trace[0], agents) &&
  (forall i :: 0 <= i < |actions| ==> Step(trace[i], trace[i + 1], actions[i]))
}

// ===== Inv preservation =====

lemma StepPreservesInv(s: State, s': State, action: Action)
  requires Inv(s)
  requires Step(s, s', action)
  ensures Inv(s')
{
}

lemma InitImpliesInv(s: State, agents: set<int>)
  requires Init(s, agents)
  ensures Inv(s)
{
}

lemma InvAlwaysHolds(trace: seq<State>, actions: seq<Action>, agents: set<int>, i: int)
  requires ValidTrace(trace, actions, agents)
  requires 0 <= i < |trace|
  ensures Inv(trace[i])
  decreases i
{
  if i == 0 {
    InitImpliesInv(trace[0], agents);
  } else {
    InvAlwaysHolds(trace, actions, agents, i - 1);
    StepPreservesInv(trace[i - 1], trace[i], actions[i - 1]);
  }
}

// ===== Property lemmas =====

// SingleOwner — at most one owner per task. Structural via map<int,int>;
// stated explicitly for the cross-formalism table.
lemma SingleOwner(trace: seq<State>, actions: seq<Action>, agents: set<int>, i: int, t: int, a1: int, a2: int)
  requires ValidTrace(trace, actions, agents)
  requires 0 <= i < |trace|
  requires t in trace[i].owner
  ensures forall b :: t in trace[i].owner && trace[i].owner[t] == b ==> b == trace[i].owner[t]
{
}

// LiveWorkerActions — only an alive agent can claim a task.
lemma LiveWorkerActions(trace: seq<State>, actions: seq<Action>, agents: set<int>, i: int, a: int, t: int)
  requires ValidTrace(trace, actions, agents)
  requires 0 <= i < |actions|
  requires actions[i] == Claim(a, t)
  ensures a in trace[i].alive
{
  assert Step(trace[i], trace[i + 1], actions[i]);
}

// ProofRequiredForTerminal — every terminal task has proof.
lemma ProofRequiredForTerminal(trace: seq<State>, actions: seq<Action>, agents: set<int>, i: int, t: int)
  requires ValidTrace(trace, actions, agents)
  requires 0 <= i < |trace|
  requires t in trace[i].phase && IsTerminal(trace[i].phase[t])
  ensures t in trace[i].hasProof
{
  InvAlwaysHolds(trace, actions, agents, i);
}

// NoZombieAfterReclaim — after Reclaim(t), t has no owner.
lemma NoZombieAfterReclaim(trace: seq<State>, actions: seq<Action>, agents: set<int>, i: int, t: int)
  requires ValidTrace(trace, actions, agents)
  requires 0 <= i < |actions|
  requires actions[i] == Reclaim(t)
  ensures t !in trace[i + 1].owner
  ensures t in trace[i + 1].phase && trace[i + 1].phase[t] == PNew
{
  assert Step(trace[i], trace[i + 1], actions[i]);
}

// ReclaimRequiresStableHeartbeatChain — Reclaim's precondition.
// Mirrors the runtime's preempt-heartbeat: the sweeper's reclaim
// only fires if no heartbeat has advanced the chain since observe.
lemma ReclaimRequiresStableHeartbeatChain(trace: seq<State>, actions: seq<Action>, agents: set<int>, i: int, t: int)
  requires ValidTrace(trace, actions, agents)
  requires 0 <= i < |actions|
  requires actions[i] == Reclaim(t)
  ensures t !in trace[i].hbSinceObs
{
  assert Step(trace[i], trace[i + 1], actions[i]);
}

// LiveHeartbeatBlocksReclaim — if a heartbeat happened since the last
// observe, no reclaim of that task can fire in the same state.
// Equivalent to: t in hbSinceObs implies actions[i] != Reclaim(t).
lemma LiveHeartbeatBlocksReclaim(trace: seq<State>, actions: seq<Action>, agents: set<int>, i: int, t: int)
  requires ValidTrace(trace, actions, agents)
  requires 0 <= i < |actions|
  requires t in trace[i].hbSinceObs
  ensures actions[i] != Reclaim(t)
{
  if actions[i] == Reclaim(t) {
    ReclaimRequiresStableHeartbeatChain(trace, actions, agents, i, t);
    assert false;
  }
}

// Reclaimer-snapshot freshness — a step that fires Reclaim(t) must be
// directly preceded by a SweepObserve(t) OR by a Claim(_, t) (which
// also clears hbSinceObs[t]) at some earlier step, and no Heartbeat
// between then and now. Captured indirectly by hbSinceObs[t] being
// false at the reclaim step. The strict temporal form follows from
// the Step semantics: the only ways to clear hbSinceObs[t] are
// SweepObserve, Claim, or Reclaim itself.
lemma HbSinceObsClearedOnlyByObserveOrClaim(trace: seq<State>, actions: seq<Action>, agents: set<int>, i: int, t: int)
  requires ValidTrace(trace, actions, agents)
  requires 0 <= i < |actions|
  requires t in trace[i].hbSinceObs
  requires t !in trace[i + 1].hbSinceObs
  ensures actions[i] == SweepObserve(t)
       || actions[i] == Reclaim(t)
       || (exists a :: actions[i] == Claim(a, t))
{
  assert Step(trace[i], trace[i + 1], actions[i]);
  match actions[i] {
    case Plan(_) =>
    case Claim(a, t2) =>
      if t2 != t {
        assert t in trace[i + 1].hbSinceObs;
        assert false;
      }
    case Crash(_) =>
    case Heartbeat(_, _) =>
      // Heartbeat ADDS to hbSinceObs; can only add t if t' = t.
      // Either way, t stays in hbSinceObs.
      assert t in trace[i + 1].hbSinceObs;
      assert false;
    case SweepObserve(t2) =>
      if t2 != t {
        assert t in trace[i + 1].hbSinceObs;
        assert false;
      }
    case Reclaim(t2) =>
      if t2 != t {
        assert t in trace[i + 1].hbSinceObs;
        assert false;
      }
    case Report(_, _) =>
      assert t in trace[i + 1].hbSinceObs;
      assert false;
    case Finish(_, _, _) =>
      assert t in trace[i + 1].hbSinceObs;
      assert false;
    case Stutter =>
      assert t in trace[i + 1].hbSinceObs;
      assert false;
  }
}
