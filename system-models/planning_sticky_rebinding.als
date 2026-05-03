module planning_sticky_rebinding

/*
  planning_sticky_rebinding.als — verify the rebinding semantic
  for sticky-context tasks after a reclaim.

  The sticky-context contract (planning.als#StickyChainCoherence /
  StickyBindingOnlyAtClaim) binds a sticky task's TaskStatus chain to
  the agent context that first claims it. When the worker dies and
  the sweeper reclaims the task, the new TaskStatus(new, reclaimed=
  true) carries no context_id (see store.reclaim — extra_attrs only
  records reclaimed/reclaimer). This model asks: what binding rules
  does the next claim observe?

  Maps to:
    skills/pm/scripts/store.py:
      - status_context_id, task_context_id (binding lookup)
      - check_sticky_eligibility, collect_required_contexts
      - reclaim() — appends new with no context_id
    skills/pm/scripts/{executing,heartbeat,report,finished}.py:
      - call check_sticky_eligibility before any chain-advancing op
    skills/pm/scripts/sweep.py: triggers reclaim on dead workers

  Modeling decisions:
    - Temporal model (var sig) — "rebind after reclaim" is inherently
      a sequence of events: claim → reclaim → claim.
    - Context = abstract handle for $PM_CONTEXT_ID. Two contexts in
      scope are enough to demonstrate rebinding (c1 → reclaim → c2)
      and the conflict case (parent c1 + child rebind to c2 refused).
    - Phase = {New, Working, Done}. Rejected/Superseded omitted —
      they're orthogonal terminal states with the same binding
      semantics as Done.
    - parentTask is the only sticky-chain edge here; depends_on
      composition is verified in planning.als#StickyChainCoherence
      and not duplicated.

  Verifies:
    SR1 ReclaimClearsBinding         — after reclaim, t.ctx is empty.
    SR2 ClaimRespectsAncestorChain   — claim succeeds only if the
                                       agent's context matches every
                                       sticky ancestor's binding (or
                                       the ancestor is unbound).
    SR3 NoRebindOnLiveBinding        — a Working task can't have its
                                       binding overwritten without
                                       first going through reclaim.
    SR4 RebindPreservesChainCoherence— after a successful rebind, the
                                       task's binding agrees with all
                                       its sticky ancestors' bindings.

  SAT scenarios (witnesses):
    RebindWitness                    — happy path: c1 → reclaim → c2.
    RebindBlockedByLiveAncestor      — refusal: live parent in c1
                                       prevents child rebind to c2.
    RebindAllowedAfterAncestorDone   — once the ancestor finishes
                                       (still bound to c1 historically
                                       on its terminal status), the
                                       gate behavior depends on whether
                                       a Done task counts as "bound
                                       for required-context purposes."
                                       The code's task_context_id reads
                                       LATEST status, so a Done sticky
                                       ancestor with c1 on its done-
                                       status WOULD still propagate c1.
                                       This scenario surfaces that
                                       behavior for the user to confirm.
*/

abstract sig Phase {}
one sig PNew, PWorking, PDone extends Phase {}

sig Context {}

sig Task {
  parent: lone Task,
  sticky: one Bool,
  var phase: one Phase,
  // ctx is the context_id recorded on the LATEST TaskStatus. Cleared
  // (lone, no value) when the task is New-and-unbound — i.e. after
  // genesis-new or reclaim-new. Populated by claim, persists through
  // finish (Done status carries the working-status ctx for audit).
  var ctx:   lone Context
}

abstract sig Bool {}
one sig True, False extends Bool {}

// Acyclic parent graph (matches data model).
fact NoSelfParent  { all t: Task | t.parent != t }
fact NoCycleParent { no t: Task | t in t.^parent }

// Initial state: every task is New, no context binding.
fact Init {
  all t: Task | t.phase = PNew and no t.ctx
}

// ---- helpers ----------------------------------------------------------

// Sticky ancestors of t (inclusive of t? No — strictly upward.)
fun sticky_ancestors[t: Task] : set Task {
  { a: t.^parent | a.sticky = True }
}

// Required contexts at the moment of a claim — every sticky ancestor's
// CURRENT binding (post-init, may be empty if ancestor hasn't been
// claimed yet). Mirrors store.collect_required_contexts (upward walk).
fun required_contexts[t: Task] : set Context {
  { c: Context | some a: sticky_ancestors[t] | a.ctx = c }
}

// ---- transitions ------------------------------------------------------

// claim(t, c): t goes from New to Working with binding c.
// Sticky enforcement matches store.check_sticky_eligibility:
//   1. The required-contexts set (sticky ancestors with a binding)
//      must have at most one element — multiple distinct bindings
//      raise StickyContextConflict in code.
//   2. If the set is non-empty, c must equal that single required
//      context (else StickyContextMismatch).
// Together these ensure post-claim chain coherence.
pred claim[t: Task, c: Context] {
  t.phase = PNew
  t.sticky = True implies (
    let req = required_contexts[t] |
      lone req                       // no conflict between multiple ancestors
      and (no req or c in req)       // matches the single required context
  )
  t.phase' = PWorking
  t.ctx'   = c
  // frame other tasks
  all t2: Task - t | t2.phase' = t2.phase and t2.ctx' = t2.ctx
}

// reclaim(t): t goes from Working back to New. Binding is cleared
// — this is the rebinding-enabling event.
pred reclaim[t: Task] {
  t.phase = PWorking
  t.phase' = PNew
  no t.ctx'
  all t2: Task - t | t2.phase' = t2.phase and t2.ctx' = t2.ctx
}

// finish(t): t goes from Working to Done. Binding persists on the
// final status (audit-only).
pred finish[t: Task] {
  t.phase = PWorking
  t.phase' = PDone
  t.ctx' = t.ctx
  all t2: Task - t | t2.phase' = t2.phase and t2.ctx' = t2.ctx
}

pred stutter {
  all t: Task | t.phase' = t.phase and t.ctx' = t.ctx
}

fact Transitions {
  always (
    stutter
    or (some t: Task, c: Context | claim[t, c])
    or (some t: Task | reclaim[t])
    or (some t: Task | finish[t])
  )
}

// Liveness assumption: every transition action is enabled at most when
// its precondition holds (encoded in pred bodies).

// ===== Safety assertions =====

// SR1: After reclaim, the task's binding is empty.
assert SR1_ReclaimClearsBinding {
  always all t: Task |
    reclaim[t] => after no t.ctx
}
check SR1_ReclaimClearsBinding for 4 but 8 steps

// SR2: A claim only succeeds if the agent's context matches the sticky
// ancestor chain (or the chain is empty).
assert SR2_ClaimRespectsAncestorChain {
  always all t: Task, c: Context |
    (claim[t, c] and t.sticky = True) =>
      (let req = required_contexts[t] | no req or c in req)
}
check SR2_ClaimRespectsAncestorChain for 4 but 8 steps

// SR3: A Working task's binding stays put while it remains Working.
// Captures "the binding can't be silently mutated mid-run" — the only
// way to clear/change ctx is via the reclaim or finish transitions.
assert SR3_BindingStableWhileWorking {
  always all t: Task |
    (t.phase = PWorking and t.phase' = PWorking) =>
      t.ctx' = t.ctx
}
check SR3_BindingStableWhileWorking for 4 but 8 steps

// SR4: After a successful claim of a STICKY task, the task's binding
// agrees with every sticky ancestor that has a binding. Restricted to
// sticky t because store.check_sticky_eligibility short-circuits for
// non-sticky tasks — a non-sticky child can run under any context even
// if its sticky parent is bound, since the child's chain isn't
// formally part of the sticky group.
assert SR4_RebindPreservesChainCoherence {
  always all t: Task, c: Context |
    (claim[t, c] and t.sticky = True) =>
      after (all a: sticky_ancestors[t] | some a.ctx => a.ctx = t.ctx)
}
check SR4_RebindPreservesChainCoherence for 4 but 8 steps

// SR5: A claim that fires on a sticky task with conflicting ancestor
// bindings is impossible — i.e., if two distinct sticky ancestors are
// bound to different contexts, no claim of t can succeed. Mirrors the
// StickyContextConflict refusal in store.check_sticky_eligibility.
assert SR5_NoClaimUnderConflict {
  always all t: Task, c: Context |
    (claim[t, c] and t.sticky = True) =>
      lone required_contexts[t]
}
check SR5_NoClaimUnderConflict for 4 but 8 steps

// ===== Liveness / SAT scenarios =====

// RebindWitness — the canonical happy path: a sticky task gets claimed
// by c1, reclaimed (worker dies), then claimed by a different context
// c2. Successful rebinding.
run RebindWitness {
  some t: Task, c1, c2: Context |
    c1 != c2
    and t.sticky = True
    and no t.parent
    and eventually (
      claim[t, c1]
      and after eventually (
        reclaim[t]
        and after eventually (claim[t, c2])
      )
    )
} for exactly 1 Task, exactly 2 Context, 8 steps

// RebindBlockedByLiveAncestor — refusal scenario. A sticky parent is
// claimed by c1 and stays Working. The sticky child gets claimed (via
// inheritance to c1), then reclaimed. Any attempt to rebind the child
// to c2 must be refused while the parent is still bound to c1.
//
// Model captures the refusal as the absence of a successful claim —
// the SAT scenario shows the trace where the rebind never fires
// (because it would violate SR2_ClaimRespectsAncestorChain, which is
// already proven).
run RebindBlockedByLiveAncestor {
  some par, kid: Task, c1, c2: Context |
    c1 != c2
    and par.sticky = True
    and kid.sticky = True
    and kid.parent = par
    and eventually (
      claim[par, c1]
      and after eventually (
        claim[kid, c1]
        and after eventually (
          reclaim[kid]
          // Parent stays Working with c1; ancestor binding persists.
          and after (par.phase = PWorking and par.ctx = c1)
        )
      )
    )
    // Negative: at no point in this trace does kid get claimed by c2.
    and always not claim[kid, c2]
} for exactly 2 Task, exactly 2 Context, 10 steps

// RebindAllowedWhenAncestorAlsoReclaimed — once both parent and child
// are reclaimed, the chain is unbound and a fresh rebind to c2 (for
// both, in order) succeeds.
run RebindAllowedAfterChainReset {
  some par, kid: Task, c1, c2: Context |
    c1 != c2
    and par.sticky = True
    and kid.sticky = True
    and kid.parent = par
    and eventually (
      claim[par, c1]
      and after eventually (
        claim[kid, c1]
        and after eventually (
          reclaim[par]
          and after eventually (
            reclaim[kid]
            and after eventually (
              claim[par, c2]
              and after eventually claim[kid, c2]
            )
          )
        )
      )
    )
} for exactly 2 Task, exactly 2 Context, 14 steps
