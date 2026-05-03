module planning_parent_gate

/*
  Parent-rolls-up-children gate for `pm next` / `pm pull`.

  Maps to:
    skills/pm/scripts/next.py  (children_settled())
    skills/pm/scripts/pull.py  (same logic, race-safe path)

  Modeling decisions:
    - Static snapshot: given a fixed graph of tasks with statuses, who is
      runnable? The rule is order-free, so a single-state model suffices.
    - Concurrency / chain safety is covered by planning.als (Race + Lease
      invariants); this model only verifies the gate predicate itself.
    - "Settled for parent" = {Done, Rejected, Superseded}. Working and New
      are unsettled. Rationale: rejected/superseded children will never
      produce more work, so a parent gated on them would block forever.
    - No `dependsOn` modeled here — depends_on gating is orthogonal and
      already verified in planning.als#GateOnDeps. We compose them at the
      code level: `next.py` checks both, but each invariant stands alone.

  Verifies:
    1. ParentBlockedByPendingChild — a task with any New/Working child
       is NOT runnable, even if status is New.
    2. ParentRunnableAfterChildrenSettle — once every child is in
       {Done, Rejected, Superseded}, a New parent IS runnable.
    3. NoSelfBlocking — a task with no children is never blocked by
       itself (sanity check on the predicate).
    4. ChildlessNewTaskRunnable — the depth-0 case (today's behavior)
       still returns runnable for any New task with no children.
    5. RejectedChildIsTerminalForGate — a parent with only Rejected
       children IS runnable (otherwise a failed subtree would orphan
       its parent forever).
*/

abstract sig Status {}
one sig SNew, SWorking, SDone, SRejected, SSuperseded extends Status {}

sig Task {
  parent: lone Task,
  status: one Status
}

// No cycles in the parent graph (already enforced by data model).
fact NoSelfParent { all t: Task | t.parent != t }
fact NoCycle      { no t: Task | t in t.^parent }

// Reverse projection: c is a child of p iff c.parent = p.
fun children[p: Task] : set Task { parent.p }

// Statuses that count as settled from the parent's perspective.
// (Done — successful; Rejected/Superseded — terminal failure or replacement.)
fun terminalForParent : set Status { SDone + SRejected + SSuperseded }

// A task is runnable iff status=New AND every child is settled.
// (depends_on omitted — composed orthogonally at the code level.)
pred runnable[t: Task] {
  t.status = SNew
  all c: children[t] | c.status in terminalForParent
}

// ---- safety: pending children block the parent ----
assert ParentBlockedByPendingChild {
  all t: Task |
    (some c: children[t] | c.status in (SNew + SWorking))
      => not runnable[t]
}
check ParentBlockedByPendingChild for 6

// ---- liveness: settled children unblock the parent ----
assert ParentRunnableAfterChildrenSettle {
  all t: Task |
    (t.status = SNew and all c: children[t] | c.status in terminalForParent)
      => runnable[t]
}
check ParentRunnableAfterChildrenSettle for 6

// ---- sanity: no self-blocking ----
assert NoSelfBlocking {
  all t: Task | t.status = SNew and no children[t] => runnable[t]
}
check NoSelfBlocking for 6

// ---- backward-compatibility: depth-0 / flat queues unchanged ----
assert ChildlessNewTaskRunnable {
  all t: Task | (t.status = SNew and no children[t]) => runnable[t]
}
check ChildlessNewTaskRunnable for 6

// ---- terminal-for-gate semantics ----
// A parent whose only children are Rejected is still runnable; otherwise
// a failed subtree would strand the parent forever.
assert RejectedChildIsTerminalForGate {
  all t: Task |
    (t.status = SNew
     and some children[t]
     and all c: children[t] | c.status = SRejected)
      => runnable[t]
}
check RejectedChildIsTerminalForGate for 6

// Likewise for Superseded — replan/replacement should not strand the parent.
assert SupersededChildIsTerminalForGate {
  all t: Task |
    (t.status = SNew
     and some children[t]
     and all c: children[t] | c.status = SSuperseded)
      => runnable[t]
}
check SupersededChildIsTerminalForGate for 6

// ---- concrete scenarios ----

// Find a parent + 2 children where one child is Working — parent must NOT
// be runnable. The model should return an instance.
run BlockedByWorkingChild {
  some p: Task |
    p.status = SNew
    and #children[p] = 2
    and (some c: children[p] | c.status = SWorking)
} for 4

// Find a sticky-style nested expansion (parent + 2 children, all Done) and
// verify the parent is runnable.
run UnblockedAfterAllChildrenDone {
  some p: Task |
    p.status = SNew
    and #children[p] = 2
    and (all c: children[p] | c.status = SDone)
    and runnable[p]
} for 4
