module planning_replan

/*
  planning_replan.als — formal model of `pm replan` semantics.

  Maps to: skills/pm/scripts/replan.py (and the worker loop primitives
  it composes from store.append_status / store.create_task).

  ===== Why a separate module =====
  planning.als models the post-plan lifecycle for a fixed set of Tasks
  with phases {New, Working, Done, Rejected}. Replan introduces:
    * a 5th phase, `Superseded`, which is absorbing but NOT in
      `isTerminal` (so ProofRequiredForTerminal doesn't apply);
    * a transition that creates a NEW Task linked back to the
      original via `replan_of`.

  Both additions are invasive in planning.als (every existing fact /
  assertion would need to consider PSuperseded). Carving this out as a
  smaller, replan-focused model keeps the core protocol model lean
  while still proving replan's specific safety properties.

  Maps to runtime modes (cross-product of two flags):
    1. In-place reset, no cascade            (no --text/--verifier, --no-cascade-up)
    2. In-place reset, cascade-up            (no --text/--verifier, default)
    3. Supersede + clone, no cascade         (--text or --verifier, --no-cascade-up)
    4. Supersede + clone, cascade-up         (--text or --verifier, default)

  Verifies:
    R1  ReplanRefusedOnSuperseded   — no replan transition fires on a Superseded task.
    R2  ResetOnlyOnTerminal          — in-place reset only fires when current is Done or Rejected.
    R3  ResetSetsNew                 — after reset, target is in PNew.
    R4  SupersededIsAbsorbing        — once Superseded, always Superseded.
    R5  CloneInheritsDeps            — the cloned task's dep set equals the original's.
    R6  CloneCarriesReplanOf         — every cloned task has its replan_of pointing at its origin.
    R7  CascadeUpResetsTerminalAncestors — every dep-chain ancestor that was terminal at the
                                           start of cascade-up ends up in PNew.
    R8  CascadeUpSkipsNonTerminal    — cascade-up never touches an ancestor in {PNew, PWorking, PSuperseded}.

  Boundary (intentionally excluded):
    * verifier / sticky-context / cancel — orthogonal; verified in planning.als.
    * Race-safety on the TaskStatus chain — verified in planning.als by NoDoubleCommit.
    * Cancel-cascade — separate concern; replan cascade is via dependsOn, not parentTask.
    * Heartbeat / lease — verified in planning_lease.als.
*/

abstract sig Phase {}
one sig PNew, PWorking, PDone, PRejected, PSuperseded extends Phase {}

sig Task {
  // Immutable dep set — Tasks are content-addressed, deps are locked at create.
  deps: set Task,
  // The task this is a replan-clone of, if any (matches `replan_of` attribute on
  // the genesis status of the cloned task).
  replan_of: lone Task,
  var phase: lone Phase
}

// Tasks that exist in the queue at any moment. A "spare" Task not yet in
// Pending is available for `supersede_and_clone` to pull in as the
// new clone target.
var sig Pending in Task {}

fact NoSelfDep   { all t: Task | t not in t.deps }
fact NoCycle     { no t: Task | t in t.^deps }
fact NoSelfClone { all t: Task | t.replan_of != t }

// Bound replan_of's own dep relation: a clone inherits the original's deps.
// Modeled here as a fact because the runtime sets it at create time.
fact ClonePreservesDepRelation {
  all t: Task | some t.replan_of => t.deps = t.replan_of.deps
}

// ===== Init =====
fact Init {
  no Pending
  all t: Task | no t.phase
}

// ===== Static invariants =====
fact PhaseIffPending { always all t: Task | one t.phase <=> t in Pending }

// Cloning is single-source: each task is the clone of at most one origin.
// (Already guaranteed by `lone replan_of`. Stated explicitly for the reader.)

// ===== Phase predicates =====
pred isNew        [t: Task] { t.phase = PNew }
pred isWorking    [t: Task] { t.phase = PWorking }
pred isDone       [t: Task] { t.phase = PDone }
pred isRejected   [t: Task] { t.phase = PRejected }
pred isSuperseded [t: Task] { t.phase = PSuperseded }
pred isTerminal   [t: Task] { isDone[t] or isRejected[t] }
pred isAbsorbing  [t: Task] { isTerminal[t] or isSuperseded[t] }

// ===== Frame helpers =====
pred frameOtherTasks[t: Task] {
  all u: Task - t | u.phase' = u.phase
}
pred frameTasks[ts: set Task] {
  all u: Task - ts | u.phase' = u.phase
}

// ===== Lifecycle transitions (subset of planning.als — just enough to
// reach Done / Rejected so replan is reachable) =====

pred plan[t: Task] {
  t not in Pending
  no t.replan_of                          // genesis Task, not a clone
  // Deps must already be on the board (planning.als matches this).
  all d: t.deps | d in Pending
  Pending' = Pending + t
  t.phase' = PNew
  frameOtherTasks[t]
}

pred claim[t: Task] {
  isNew[t]
  all d: t.deps | isDone[d]               // dep gate
  Pending' = Pending
  t.phase' = PWorking
  frameOtherTasks[t]
}

pred finish[t: Task, terminal: Phase] {
  terminal in PDone + PRejected
  isWorking[t]
  Pending' = Pending
  t.phase' = terminal
  frameOtherTasks[t]
}

// ===== Replan transitions =====

// Mode 1/2: in-place reset of a single task. Mirrors `reset_in_place` in
// replan.py — only fires on terminal phases; refuses on Superseded;
// no-op on New/Working.
pred replan_reset[t: Task] {
  isTerminal[t]                           // R2: refuses on New/Working/Superseded
  Pending' = Pending
  t.phase' = PNew                         // R3
  frameOtherTasks[t]
}

// Mode 3/4 (target half): supersede the original and pull a "fresh"
// Task into Pending as the clone. Mirrors `supersede_and_clone`.
//
// The clone `c` is any Task that:
//   * is not yet in Pending,
//   * has c.replan_of = orig (the structural mark of being a clone of orig).
// (`fact ClonePreservesDepRelation` enforces deps inheritance.)
pred replan_supersede_clone[orig, c: Task] {
  not isSuperseded[orig]                  // R1: refuses already-superseded
  orig in Pending
  c not in Pending
  c.replan_of = orig                      // R6: clone carries replan_of
  // Effect:
  Pending' = Pending + c
  orig.phase' = PSuperseded
  c.phase' = PNew                         // genesis status
  frameTasks[orig + c]
}

// Cascade-up: reset every dep-chain ancestor that is currently terminal.
// Modeled as a single atomic step that resets ALL such ancestors (the
// runtime does this iteratively but the order doesn't matter — they're
// independent appends on different chains).
pred replan_cascade_up[t: Task] {
  let ancs = t.^deps & { a: Task | isTerminal[a] } |
    some ancs and                          // need at least one to reset
    Pending' = Pending and
    (all a: ancs | a.phase' = PNew) and    // R7: all terminal ancestors → PNew
    (all a: t.^deps - ancs | a.phase' = a.phase) and  // R8: non-terminal untouched
    frameTasks[t.^deps]
}

// Cascade-down: reset every dep-chain descendant that is currently
// terminal. Descendants are tasks d such that t ∈ d.^deps (reverse of
// the ancestor walk). Same all-at-once atomic step as cascade-up;
// runtime ordering doesn't matter because each reset appends to a
// distinct chain. Used when the target's output is now stale and
// downstream consumers must rebuild on the new output.
pred replan_cascade_down[t: Task] {
  let descs = { d: Task | t in d.^deps } & { d: Task | isTerminal[d] } |
    some descs and                          // need at least one to reset
    Pending' = Pending and
    (all d: descs | d.phase' = PNew) and    // R9: all terminal descendants → PNew
    (all d: { d: Task | t in d.^deps } - descs | d.phase' = d.phase) and  // R10
    frameTasks[{ d: Task | t in d.^deps }]
}

pred stutter {
  Pending' = Pending and (all t: Task | t.phase' = t.phase)
}

fact Transitions {
  always (
    stutter
    or (some t: Task | plan[t])
    or (some t: Task | claim[t])
    or (some t: Task, p: Phase | finish[t, p])
    or (some t: Task | replan_reset[t])
    or (some orig, c: Task | replan_supersede_clone[orig, c])
    or (some t: Task | replan_cascade_up[t])
    or (some t: Task | replan_cascade_down[t])
  )
}

// ===== Safety assertions =====

assert R1_ReplanRefusedOnSuperseded {
  always all t: Task |
    isSuperseded[t] => after isSuperseded[t]   // never replanned out of Superseded
}
check R1_ReplanRefusedOnSuperseded for 4 but 8 steps

assert R2_ResetOnlyOnTerminal {
  always all t: Task |
    (replan_reset[t]) => isTerminal[t]
}
check R2_ResetOnlyOnTerminal for 4 but 8 steps

assert R3_ResetSetsNew {
  always all t: Task | replan_reset[t] => after isNew[t]
}
check R3_ResetSetsNew for 4 but 8 steps

assert R4_SupersededIsAbsorbing {
  always all t: Task |
    isSuperseded[t] => always isSuperseded[t]
}
check R4_SupersededIsAbsorbing for 4 but 10 steps

assert R5_CloneInheritsDeps {
  always all c: Task | some c.replan_of => c.deps = c.replan_of.deps
}
check R5_CloneInheritsDeps for 4 but 8 steps

assert R6_CloneCarriesReplanOf {
  always all orig, c: Task |
    replan_supersede_clone[orig, c] => c.replan_of = orig
}
check R6_CloneCarriesReplanOf for 4 but 8 steps

assert R7_CascadeUpResetsTerminalAncestors {
  always all t: Task |
    replan_cascade_up[t] =>
      (all a: t.^deps | (isTerminal[a] => after isNew[a]))
}
check R7_CascadeUpResetsTerminalAncestors for 4 but 8 steps

assert R8_CascadeUpSkipsNonTerminal {
  always all t: Task |
    replan_cascade_up[t] =>
      (all a: t.^deps | (not isTerminal[a] => after a.phase = a.phase))
}
check R8_CascadeUpSkipsNonTerminal for 4 but 8 steps

assert R9_CascadeDownResetsTerminalDescendants {
  always all t: Task |
    replan_cascade_down[t] =>
      (all d: { d: Task | t in d.^deps } | (isTerminal[d] => after isNew[d]))
}
check R9_CascadeDownResetsTerminalDescendants for 4 but 8 steps

assert R10_CascadeDownSkipsNonTerminal {
  always all t: Task |
    replan_cascade_down[t] =>
      (all d: { d: Task | t in d.^deps } |
        (not isTerminal[d] => after d.phase = d.phase))
}
check R10_CascadeDownSkipsNonTerminal for 4 but 8 steps

// R11: cascade-down is the symmetric counterpart of cascade-up — for any
// edge x → y (x depends on y) where both are terminal, replanning y with
// cascade-down resets x; replanning x with cascade-up resets y. This
// captures the duality and guards against an asymmetric implementation.
assert R11_CascadeDirectionsAreDual {
  always all t, u: Task |
    (t in u.^deps and isTerminal[t] and isTerminal[u]) =>
      ((replan_cascade_down[t] => after isNew[u])
       and (replan_cascade_up[u] => after isNew[t]))
}
check R11_CascadeDirectionsAreDual for 4 but 8 steps

// ===== Liveness scenarios =====

// Mode 1: plain in-place reset (target only). Task driven to done, then
// replanned, then re-claimed.
run M1_InPlaceReset {
  some t: Task | eventually (
    isDone[t] and eventually (
      isNew[t] and eventually isWorking[t]
    )
  )
} for exactly 1 Task, 8 steps

// Mode 2: cascade-up reset. A task with a done ancestor is replanned
// with cascade — both the target and the ancestor end up in PNew.
run M2_CascadeUpReset {
  some disj a, t: Task |
    t.deps = a and no a.deps and
    eventually (
      isDone[a] and isRejected[t] and eventually (
        isNew[a] and isNew[t]
      )
    )
} for exactly 2 Task, 12 steps

// Mode 3: supersede + clone, no cascade. Target replaced by clone with
// same deps; clone has replan_of = original.
// (replan_of is immutable — it must be `c.replan_of = t` for the whole
// trace, not initially-empty.)
run M3_SupersedeClone {
  some disj t, c: Task |
    no t.deps and c.replan_of = t
    and eventually (
      isRejected[t] and eventually (
        isSuperseded[t] and isNew[c]
      )
    )
} for exactly 2 Task, 10 steps

// Negative: try to replan a Superseded task. Should be UNSAT.
run TryReplanSuperseded {
  some t: Task | eventually (
    isSuperseded[t] and after isNew[t]    // attempting replan_reset
  )
} for exactly 1 Task, 8 steps
expect 0

// Negative: in-place reset of a Working task. Should be UNSAT —
// replan_reset's precondition is isTerminal[t].
run TryResetWorking {
  some t: Task | eventually (
    isWorking[t] and replan_reset[t]
  )
} for exactly 1 Task, 8 steps
expect 0

// Witness: cascade-up where one ancestor is Working — that ancestor is NOT reset.
run CascadeUpSkipsWorking {
  some disj a, t: Task |
    t.deps = a and no a.deps and
    eventually (
      isWorking[a] and isRejected[t] and after (
        isWorking[a] and isNew[t]    // a unchanged, t reset; cascade fired
      )
    )
} for exactly 2 Task, 12 steps
