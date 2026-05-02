module planning_isolation

/*
  planning_isolation.als — formal model of cross-queue and workdir
  isolation in the next-task selector.

  Maps to: skills/pm/scripts/next.py (the candidate-filter loop) +
            skills/pm/next/SKILL.md (selection rules) +
            skills/pm/scripts/plan.py (workdir inheritance).

  ===== Why a separate (static) module =====
  The other planning models are temporal (var sigs, traces). Isolation
  is about FILTERING immutable task attributes — a Task's queue and
  workdir are fixed at plan time and never mutate. A static model
  captures the relevant properties without the overhead of trace
  reasoning.

  Verifies:
    Q1   QueueFilterCorrect              — visible iff worker's queue arg matches task.queue
    W1   WorkdirFilterCorrect            — visible iff workdirs match or task has none
    W2   SubtaskInheritsWorkdir          — child's workdir == parent's workdir (when parent has one)
    W3   DifferentWorkdirMutuallyExclusive — no worker sees tasks from two distinct non-null workdirs
    Q2   DifferentQueueMutuallyExclusive — no `pm next --queue Q` returns tasks from a different queue
    W4   NullWorkdirUniversallyVisible    — tasks with no workdir are visible to every worker in their queue
    PCSV ParentChildSameVisibility       — when parent and child are in the same queue, they're visible to the same set of workers

  Boundary (intentionally excluded):
    * Phase / status — orthogonal; the runtime's `pm next` also
      filters by `latest status == new`, but that's a temporal property
      verified in planning.als (DependenciesDoneAtClaim,
      TerminalAbsorbing). Here we focus on the visibility-filter shape.
    * Queue inheritance — the runtime's plan.py does NOT inherit queue
      from parent; subtasks can be in different queues. Captured as a
      witness scenario CrossQueueSubtask below.
    * Sticky context — orthogonal; covered in planning.als.
*/

sig Queue {}
sig Workdir {}

sig Task {
  taskQueue:   one Queue,
  taskWorkdir: lone Workdir,         // lone — empty means "any worker can claim"
  parent:      lone Task
}

sig Worker {
  workerWorkdir: one Workdir          // every worker has a workdir
}

fact NoSelfParent { all t: Task | t.parent != t }
fact NoCycle      { no t: Task | t in t.^parent }

// W2: subtask inherits parent's workdir at plan time. Modeled as a
// structural fact since `attributes.workdir` is immutable on a Task.
fact SubtaskInheritsWorkdir {
  all child: Task |
    some child.parent and some child.parent.taskWorkdir
      => child.taskWorkdir = child.parent.taskWorkdir
}

// ===== Visibility predicate =====
// A task t is visible to worker w issuing `pm next --queue q` iff:
//   1. t's queue equals the queried queue, AND
//   2. t has no workdir OR t's workdir matches w's workdir.
// Mirrors next.py:
//   - "Skip tasks whose workdir is set and does not equal caller's"
//   - "iterate Tasks in the queue ordered by created_at"
pred visibleTo[t: Task, w: Worker, q: Queue] {
  t.taskQueue = q
  no t.taskWorkdir or t.taskWorkdir = w.workerWorkdir
}

// ===== Safety assertions =====

// Q1: filter correctness for queue.
assert Q1_QueueFilterCorrect {
  all t: Task, w: Worker, q: Queue |
    visibleTo[t, w, q] => t.taskQueue = q
}
check Q1_QueueFilterCorrect for 5

// W1: filter correctness for workdir.
assert W1_WorkdirFilterCorrect {
  all t: Task, w: Worker, q: Queue |
    visibleTo[t, w, q] and some t.taskWorkdir
      => t.taskWorkdir = w.workerWorkdir
}
check W1_WorkdirFilterCorrect for 5

// W2: workdir inheritance — child takes parent's workdir.
assert W2_SubtaskInheritsWorkdir {
  all child: Task |
    some child.parent and some child.parent.taskWorkdir
      => child.taskWorkdir = child.parent.taskWorkdir
}
check W2_SubtaskInheritsWorkdir for 5

// W3: cross-workdir isolation — no worker sees tasks from two
// distinct non-null workdirs. (Tasks with no workdir are universal
// and don't violate this.)
assert W3_DifferentWorkdirMutuallyExclusive {
  all w: Worker, q: Queue, disj t1, t2: Task |
    (visibleTo[t1, w, q] and visibleTo[t2, w, q]
     and some t1.taskWorkdir and some t2.taskWorkdir)
    => t1.taskWorkdir = t2.taskWorkdir
}
check W3_DifferentWorkdirMutuallyExclusive for 5

// Q2: cross-queue isolation — `pm next --queue Q` never returns
// tasks from a different queue.
assert Q2_DifferentQueueMutuallyExclusive {
  no t: Task, w: Worker, q: Queue |
    visibleTo[t, w, q] and t.taskQueue != q
}
check Q2_DifferentQueueMutuallyExclusive for 5

// W4: null-workdir tasks are universally visible within their queue.
// Mirrors next.py: "Tasks with no workdir attribute (legacy / pre-
// feature) remain visible everywhere."
assert W4_NullWorkdirUniversallyVisible {
  all t: Task, w: Worker |
    no t.taskWorkdir => visibleTo[t, w, t.taskQueue]
}
check W4_NullWorkdirUniversallyVisible for 5

// PCSV: parent + child in the same queue are visible to the same set
// of workers (via workdir inheritance — they end up with the same
// taskWorkdir per W2). When queues differ, this doesn't hold.
assert PCSV_ParentChildSameVisibility {
  all child: Task, w: Worker |
    some child.parent and some child.parent.taskWorkdir
    and child.taskQueue = child.parent.taskQueue
      => (visibleTo[child, w, child.taskQueue]
          iff visibleTo[child.parent, w, child.parent.taskQueue])
}
check PCSV_ParentChildSameVisibility for 5

// ===== Witness scenarios =====

// S1: two workers in different workdirs see disjoint task subsets
// from the same queue.
run TwoWorkersIsolated {
  some disj w1, w2: Worker, q: Queue, disj t1, t2: Task |
    w1.workerWorkdir != w2.workerWorkdir
    and t1.taskQueue = q and t2.taskQueue = q
    and t1.taskWorkdir = w1.workerWorkdir
    and t2.taskWorkdir = w2.workerWorkdir
    and visibleTo[t1, w1, q] and not visibleTo[t1, w2, q]
    and visibleTo[t2, w2, q] and not visibleTo[t2, w1, q]
} for exactly 2 Worker, exactly 1 Queue, exactly 2 Task, exactly 2 Workdir

// S2: a null-workdir task is visible to every worker in its queue.
run NullWorkdirSharedAcrossWorkers {
  some disj w1, w2: Worker, q: Queue, t: Task |
    w1.workerWorkdir != w2.workerWorkdir
    and t.taskQueue = q and no t.taskWorkdir
    and visibleTo[t, w1, q] and visibleTo[t, w2, q]
} for exactly 2 Worker, exactly 1 Queue, exactly 1 Task, exactly 2 Workdir

// S3: cross-queue subtask — child has a different queue than parent
// but inherits workdir. Demonstrates the runtime's behavior where
// queue isn't inherited but workdir is.
run CrossQueueSubtask {
  some disj p, c: Task, disj q1, q2: Queue, wd: Workdir |
    p.taskQueue = q1 and c.taskQueue = q2
    and c.parent = p
    and p.taskWorkdir = wd
    // c.taskWorkdir = wd by W2 (inherited)
} for exactly 2 Task, exactly 2 Queue, exactly 1 Workdir, exactly 0 Worker

// Negative — try to find a worker who sees a task from a different
// workdir. Should be UNSAT under W3.
run TryCrossWorkdirVisibility {
  some w: Worker, q: Queue, t: Task |
    visibleTo[t, w, q]
    and some t.taskWorkdir
    and t.taskWorkdir != w.workerWorkdir
} for 5
expect 0

// Negative — try to find a worker who sees a task from a different
// queue. Should be UNSAT under Q2.
run TryCrossQueueVisibility {
  some w: Worker, q: Queue, t: Task |
    visibleTo[t, w, q] and t.taskQueue != q
} for 5
expect 0
