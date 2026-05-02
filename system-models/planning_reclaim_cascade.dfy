/*
  planning_reclaim_cascade.dfy — Dafny port of system-models/planning_reclaim_cascade.als.

  Verifies the parent-reverse cascade walk in reclaim.py's --cascade
  path. Mirror to planning_cancel_cascade.dfy with two differences:
    * per-task transition: PWorking → PNew (owner stripped), not
      PNew/PWorking → PRejected
    * skip set: only `working` descendants get reclaimed; new/done/
      rejected/superseded are all left alone

  Maps to: skills/pm/scripts/reclaim.py (cascade DFS) +
            skills/pm/reclaim/SKILL.md.

  Properties proved (mirror RC1-RC6 from planning_reclaim_cascade.als):
    RC1  NoWorkingDescendantLeftWorking — working descendants reset
    RC2  NewDescendantsUntouched         — new descendants preserved
    RC3  TerminalDescendantsUntouched    — done/rejected preserved
    RC4  CascadeIsParentTransitive       — A→B→C all working, all reset
    RC5  NonDescendantUntouched          — outside the closure preserved
    RC6  ReclaimRefusesNonWorkingRoot    — exit 6 short-circuits cascade
*/

datatype Phase = PNew | PWorking | PDone | PRejected

ghost predicate IsTerminal(p: Phase) {
  p == PDone || p == PRejected
}

datatype TaskInfo = TaskInfo(parent: int)

datatype State = State(
  pending: set<int>,
  phase:   map<int, Phase>,
  owner:   map<int, int>     // task -> agent (only present when working)
)

datatype Action =
  | Plan(t: int)
  | Claim(a: int, t: int)
  | Finish(t: int, terminal: Phase)
  | CascadeReclaim(root: int, descendants: set<int>)
  | Stutter

ghost predicate Init(s: State) {
  s.pending == {} &&
  s.phase == map[] &&
  s.owner == map[]
}

ghost predicate Inv(s: State) {
  (forall t :: t in s.pending <==> t in s.phase) &&
  (forall t :: t in s.owner ==> t in s.phase && s.phase[t] != PNew) &&
  (forall t :: t in s.phase && s.phase[t] == PWorking ==> t in s.owner)
}

ghost predicate ValidDescendantsSet(root: int, descendants: set<int>, info: map<int, TaskInfo>) {
  forall d :: d in descendants ==>
    d in info &&
    (info[d].parent == root || info[d].parent in descendants)
}

// ===== Transitions =====

ghost predicate StepPlan(s: State, s': State, info: map<int, TaskInfo>, t: int) {
  t !in s.pending &&
  s' == s.(
    pending := s.pending + {t},
    phase   := s.phase[t := PNew]
  )
}

ghost predicate StepClaim(s: State, s': State, a: int, t: int) {
  t in s.phase && s.phase[t] == PNew &&
  s' == s.(
    phase := s.phase[t := PWorking],
    owner := s.owner[t := a]
  )
}

ghost predicate StepFinish(s: State, s': State, t: int, terminal: Phase) {
  IsTerminal(terminal) &&
  t in s.phase && s.phase[t] == PWorking &&
  s' == s.(phase := s.phase[t := terminal])
}

// Cascade-reclaim: root + every working descendant → PNew, owner
// stripped. Non-working descendants (PNew/PDone/PRejected) untouched.
ghost predicate StepCascadeReclaim(s: State, s': State, info: map<int, TaskInfo>, root: int, descendants: set<int>) {
  root in s.pending &&
  root in s.phase &&
  s.phase[root] == PWorking &&                    // RC6 precondition
  ValidDescendantsSet(root, descendants, info) &&
  s' == s.(
    phase := MapSetMany(s.phase, ToReclaim(root, descendants, s.phase), PNew),
    owner := MapRemoveKeys(s.owner, ToReclaim(root, descendants, s.phase))
  )
}

// Set of tasks that the cascade actually transitions: root + working
// descendants only.
ghost function ToReclaim(root: int, descendants: set<int>, phase: map<int, Phase>): set<int> {
  set t | t in ({root} + descendants) && t in phase && phase[t] == PWorking
}

ghost function MapSetMany(m: map<int, Phase>, keys: set<int>, newPhase: Phase): map<int, Phase>
  ensures forall k :: k in m ==> k in MapSetMany(m, keys, newPhase)
  ensures forall k :: k in MapSetMany(m, keys, newPhase) ==> k in m
  ensures forall k :: k in m && k in keys ==> MapSetMany(m, keys, newPhase)[k] == newPhase
  ensures forall k :: k in m && k !in keys ==> MapSetMany(m, keys, newPhase)[k] == m[k]
{
  map k | k in m :: (if k in keys then newPhase else m[k])
}

ghost function MapRemoveKeys(m: map<int, int>, keys: set<int>): map<int, int>
  ensures forall k :: k in MapRemoveKeys(m, keys) <==> k in m && k !in keys
  ensures forall k :: k in MapRemoveKeys(m, keys) ==> MapRemoveKeys(m, keys)[k] == m[k]
{
  map k | k in m && k !in keys :: m[k]
}

ghost predicate Step(s: State, s': State, info: map<int, TaskInfo>, action: Action) {
  match action {
    case Plan(t) => StepPlan(s, s', info, t)
    case Claim(a, t) => StepClaim(s, s', a, t)
    case Finish(t, terminal) => StepFinish(s, s', t, terminal)
    case CascadeReclaim(root, descendants) =>
      StepCascadeReclaim(s, s', info, root, descendants)
    case Stutter => s' == s
  }
}

ghost predicate ValidTrace(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>) {
  |trace| >= 1 &&
  |actions| == |trace| - 1 &&
  Init(trace[0]) &&
  (forall i :: 0 <= i < |actions| ==> Step(trace[i], trace[i + 1], info, actions[i]))
}

lemma StepPreservesInv(s: State, s': State, info: map<int, TaskInfo>, action: Action)
  requires Inv(s)
  requires Step(s, s', info, action)
  ensures Inv(s')
{
}

lemma InitImpliesInv(s: State)
  requires Init(s)
  ensures Inv(s)
{
}

lemma InvAlwaysHolds(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |trace|
  ensures Inv(trace[i])
  decreases i
{
  if i == 0 {
    InitImpliesInv(trace[0]);
  } else {
    InvAlwaysHolds(trace, actions, info, i - 1);
    StepPreservesInv(trace[i - 1], trace[i], info, actions[i - 1]);
  }
}

// ===== Property lemmas =====

// RC1: every working descendant ends up PNew with no owner.
lemma RC1_NoWorkingDescendantLeftWorking(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, root: int, descendants: set<int>, d: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i] == CascadeReclaim(root, descendants)
  requires d in descendants && d in trace[i].phase && trace[i].phase[d] == PWorking
  ensures d in trace[i + 1].phase && trace[i + 1].phase[d] == PNew
  ensures d !in trace[i + 1].owner
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
  assert d in ToReclaim(root, descendants, trace[i].phase);
}

// RC2: descendants already in PNew unchanged.
lemma RC2_NewDescendantsUntouched(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, root: int, descendants: set<int>, d: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i] == CascadeReclaim(root, descendants)
  requires d in descendants && d in trace[i].phase && trace[i].phase[d] == PNew
  ensures d in trace[i + 1].phase && trace[i + 1].phase[d] == PNew
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
  assert d !in ToReclaim(root, descendants, trace[i].phase);
}

// RC3: descendants in done/rejected unchanged.
lemma RC3_TerminalDescendantsUntouched(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, root: int, descendants: set<int>, d: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i] == CascadeReclaim(root, descendants)
  requires d in descendants && d in trace[i].phase && IsTerminal(trace[i].phase[d])
  ensures d in trace[i + 1].phase && trace[i + 1].phase[d] == trace[i].phase[d]
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
  assert d !in ToReclaim(root, descendants, trace[i].phase);
}

// RC4: parent-transitive — if c is in descendants and currently
// working, c gets reset.
lemma RC4_CascadeIsParentTransitive(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, root: int, descendants: set<int>, c: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i] == CascadeReclaim(root, descendants)
  requires c in descendants && c in trace[i].phase && trace[i].phase[c] == PWorking
  ensures c in trace[i + 1].phase && trace[i + 1].phase[c] == PNew
{
  RC1_NoWorkingDescendantLeftWorking(trace, actions, info, i, root, descendants, c);
}

// RC5: tasks NOT in (root + descendants) are unchanged.
lemma RC5_NonDescendantUntouched(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, root: int, descendants: set<int>, t: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i] == CascadeReclaim(root, descendants)
  requires t in trace[i].phase
  requires t != root && t !in descendants
  ensures t in trace[i + 1].phase && trace[i + 1].phase[t] == trace[i].phase[t]
  ensures t in trace[i].owner ==> t in trace[i + 1].owner && trace[i + 1].owner[t] == trace[i].owner[t]
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
  assert t !in ToReclaim(root, descendants, trace[i].phase);
}

// RC6: cascade can only fire on a root in PWorking.
lemma RC6_ReclaimRefusesNonWorkingRoot(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, root: int, descendants: set<int>)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i] == CascadeReclaim(root, descendants)
  ensures root in trace[i].phase && trace[i].phase[root] == PWorking
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
}
