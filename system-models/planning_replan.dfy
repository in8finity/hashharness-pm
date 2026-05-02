/*
  planning_replan.dfy — Dafny port of system-models/planning_replan.als.

  Verifies the replan protocol for traces of ANY length. Self-contained
  module (doesn't import planning.dfy) because the lifecycle here adds
  PSuperseded as a fifth phase and the replan_of field on tasks — both
  invasive in planning.dfy.

  Maps to:
    skills/pm/scripts/replan.py (reset_in_place + supersede_and_clone)
    skills/pm/replan/SKILL.md

  Properties proved (mirror R1-R8 from planning_replan.als):
    R1  ReplanRefusedOnSuperseded         — no replan_reset on Superseded
    R2  ResetOnlyOnTerminal               — reset only on Done/Rejected
    R3  ResetSetsNew                      — after reset, target is PNew
    R4  SupersededIsAbsorbing             — once Superseded, always Superseded
    R5  CloneInheritsDeps                 — cloned task has same dep set as origin
    R6  CloneCarriesReplanOf              — every clone has replan_of pointing at origin
    R7  CascadeUpResetsTerminalAncestors  — cascade-up resets every terminal ancestor
    R8  CascadeUpSkipsNonTerminal         — cascade-up doesn't touch in-flight ancestors
*/

datatype Phase = PNew | PWorking | PDone | PRejected | PSuperseded

ghost predicate IsTerminal(p: Phase) {
  p == PDone || p == PRejected
}

ghost predicate IsAbsorbing(p: Phase) {
  IsTerminal(p) || p == PSuperseded
}

datatype TaskInfo = TaskInfo(
  deps: set<int>,
  // Some(orig) iff this task is a replan-clone of orig. Immutable
  // alongside `info`; set at create-time only.
  replanOf: int    // sentinel: -1 means "no clone-of"; otherwise origin id
)

ghost predicate IsClone(info: map<int, TaskInfo>, t: int) {
  t in info && info[t].replanOf >= 0
}

datatype State = State(
  pending: set<int>,
  phase:   map<int, Phase>
)

datatype Action =
  | Plan(t: int)
  | Claim(t: int)
  | Finish(t: int, terminal: Phase)
  | ReplanReset(t: int)
  | ReplanSupersedeClone(orig: int, c: int)
  | ReplanCascadeUp(t: int, ancestors: set<int>)
  | Stutter

ghost predicate Init(s: State) {
  s.pending == {} &&
  s.phase == map[]
}

ghost predicate Inv(s: State, info: map<int, TaskInfo>) {
  (forall t :: t in s.pending <==> t in s.phase) &&
  // Clone identity is structural (set in info, not derived from phase).
  // No further phase invariants beyond pending/phase consistency.
  true
}

// ===== Static facts about info =====

// ClonePreservesDepRelation: a clone inherits its origin's deps.
// Stated as a precondition on info passed to ValidTrace.
ghost predicate WellFormedInfo(info: map<int, TaskInfo>) {
  (forall t :: t in info && info[t].replanOf >= 0
     ==> info[t].replanOf in info
         && info[t].deps == info[info[t].replanOf].deps) &&
  // No self-clone: a task can't be a clone of itself.
  (forall t :: t in info ==> info[t].replanOf != t)
}

// ===== Transitions =====

ghost predicate StepPlan(s: State, s': State, info: map<int, TaskInfo>, t: int) {
  t in info &&
  t !in s.pending &&
  info[t].replanOf < 0 &&                  // genesis only — clones land via supersede
  (forall d :: d in info[t].deps ==> d in s.pending) &&
  s' == s.(
    pending := s.pending + {t},
    phase   := s.phase[t := PNew]
  )
}

ghost predicate StepClaim(s: State, s': State, info: map<int, TaskInfo>, t: int) {
  t in info &&
  t in s.phase && s.phase[t] == PNew &&
  (forall d :: d in info[t].deps ==> d in s.phase && s.phase[d] == PDone) &&
  s' == s.(phase := s.phase[t := PWorking])
}

ghost predicate StepFinish(s: State, s': State, t: int, terminal: Phase) {
  IsTerminal(terminal) &&
  t in s.phase && s.phase[t] == PWorking &&
  s' == s.(phase := s.phase[t := terminal])
}

// R1, R2, R3: in-place reset. Refuses on Superseded; refuses if non-terminal.
ghost predicate StepReplanReset(s: State, s': State, t: int) {
  t in s.phase && IsTerminal(s.phase[t]) &&
  s' == s.(phase := s.phase[t := PNew])
}

// R4, R5, R6: supersede + clone.
//   - orig.phase  → PSuperseded   (absorbing — never replanned out)
//   - c           added to pending with phase = PNew
//   - c is required to satisfy info[c].replanOf == orig (R6)
//   - WellFormedInfo gives c.deps = orig.deps (R5)
ghost predicate StepReplanSupersedeClone(s: State, s': State, info: map<int, TaskInfo>, orig: int, c: int) {
  orig in s.phase && s.phase[orig] != PSuperseded &&
  c in info && info[c].replanOf == orig &&
  c !in s.pending &&
  s' == s.(
    pending := s.pending + {c},
    phase   := s.phase[orig := PSuperseded][c := PNew]
  )
}

// R7, R8: cascade-up. The `ancestors` set is the caller-supplied set
// of tasks to reset. Soundness condition: every task in `ancestors`
// must currently be terminal (R7's precondition). We don't model the
// "must be a transitive ancestor of t via deps" structural constraint
// here — the post-state only mutates the supplied set, so non-deps
// tasks are protected by R8 (anything outside `ancestors` is
// unchanged). The runtime guarantees this set is the dep-chain
// ancestor closure; the model abstracts that DFS as the caller's
// responsibility.
ghost predicate StepReplanCascadeUp(s: State, s': State, info: map<int, TaskInfo>, t: int, ancestors: set<int>) {
  t in info &&
  (forall a :: a in ancestors ==> a in s.phase && IsTerminal(s.phase[a])) &&
  ancestors != {} &&
  s' == s.(
    phase := MapResetMany(s.phase, ancestors)
  )
}

// Reset every task in `s` to PNew, preserving the rest of the map.
ghost function MapResetMany(m: map<int, Phase>, s: set<int>): map<int, Phase>
  ensures forall k :: k in m ==> k in MapResetMany(m, s)
  ensures forall k :: k in MapResetMany(m, s) ==> k in m
  ensures forall k :: k in m && k in s ==> MapResetMany(m, s)[k] == PNew
  ensures forall k :: k in m && k !in s ==> MapResetMany(m, s)[k] == m[k]
{
  map k | k in m :: (if k in s then PNew else m[k])
}

ghost predicate Step(s: State, s': State, info: map<int, TaskInfo>, action: Action) {
  match action {
    case Plan(t) => StepPlan(s, s', info, t)
    case Claim(t) => StepClaim(s, s', info, t)
    case Finish(t, terminal) => StepFinish(s, s', t, terminal)
    case ReplanReset(t) => StepReplanReset(s, s', t)
    case ReplanSupersedeClone(orig, c) => StepReplanSupersedeClone(s, s', info, orig, c)
    case ReplanCascadeUp(t, ancestors) => StepReplanCascadeUp(s, s', info, t, ancestors)
    case Stutter => s' == s
  }
}

ghost predicate ValidTrace(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>) {
  WellFormedInfo(info) &&
  |trace| >= 1 &&
  |actions| == |trace| - 1 &&
  Init(trace[0]) &&
  (forall i :: 0 <= i < |actions| ==> Step(trace[i], trace[i + 1], info, actions[i]))
}

// ===== Inv preservation =====

lemma StepPreservesInv(s: State, s': State, info: map<int, TaskInfo>, action: Action)
  requires Inv(s, info)
  requires Step(s, s', info, action)
  ensures Inv(s', info)
{
}

lemma InitImpliesInv(s: State, info: map<int, TaskInfo>)
  requires Init(s)
  ensures Inv(s, info)
{
}

lemma InvAlwaysHolds(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |trace|
  ensures Inv(trace[i], info)
  decreases i
{
  if i == 0 {
    InitImpliesInv(trace[0], info);
  } else {
    InvAlwaysHolds(trace, actions, info, i - 1);
    StepPreservesInv(trace[i - 1], trace[i], info, actions[i - 1]);
  }
}

// ===== Property lemmas =====

// R1: ReplanReset never fires on a Superseded task. (Captured directly
// by StepReplanReset's `IsTerminal` precondition — Superseded is not
// in IsTerminal.)
lemma R1_ReplanRefusedOnSuperseded(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, t: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires t in trace[i].phase && trace[i].phase[t] == PSuperseded
  ensures !actions[i].ReplanReset? || actions[i].t != t
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
  if actions[i].ReplanReset? && actions[i].t == t {
    assert StepReplanReset(trace[i], trace[i + 1], t);
    // StepReplanReset requires IsTerminal(phase[t]); PSuperseded is not.
    assert false;
  }
}

// R2: ResetOnlyOnTerminal — direct from StepReplanReset's precondition.
lemma R2_ResetOnlyOnTerminal(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i].ReplanReset?
  ensures actions[i].t in trace[i].phase
  ensures IsTerminal(trace[i].phase[actions[i].t])
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
  match actions[i] {
    case ReplanReset(t) => assert StepReplanReset(trace[i], trace[i + 1], t);
  }
}

// R3: ResetSetsNew — direct from StepReplanReset's effect.
lemma R3_ResetSetsNew(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i].ReplanReset?
  ensures actions[i].t in trace[i + 1].phase
  ensures trace[i + 1].phase[actions[i].t] == PNew
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
}

// R4: SupersededIsAbsorbing — once Superseded, always Superseded.
lemma R4_SupersededIsAbsorbing(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, j: int, t: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i <= j < |trace|
  requires t in trace[i].phase && trace[i].phase[t] == PSuperseded
  ensures t in trace[j].phase && trace[j].phase[t] == PSuperseded
  decreases j - i
{
  if i < j {
    InvAlwaysHolds(trace, actions, info, i);
    assert t in trace[i].pending;       // from Inv: phase ⇔ pending
    assert Step(trace[i], trace[i + 1], info, actions[i]);
    match actions[i] {
      case Plan(t2) =>
        // StepPlan requires t2 !in pending; t IS in pending, so t2 != t.
        assert t2 != t;
      case Claim(t2) =>
        // StepClaim requires phase[t2] == PNew; ours is PSuperseded so t2 != t.
        assert t2 != t;
      case Finish(t2, _) =>
        // StepFinish requires PWorking; ours is PSuperseded.
        assert t2 != t;
      case ReplanReset(t2) =>
        // StepReplanReset requires IsTerminal; PSuperseded isn't.
        assert t2 != t;
      case ReplanSupersedeClone(orig, c) =>
        // orig must not already be PSuperseded; c must not be in pending.
        assert orig != t;
        assert c !in trace[i].pending;
        assert c != t;
      case ReplanCascadeUp(_, ancestors) =>
        // Ancestors are terminal; PSuperseded isn't terminal so t isn't in ancestors.
        assert t !in ancestors;
      case Stutter =>
    }
    assert trace[i + 1].phase[t] == PSuperseded;
    R4_SupersededIsAbsorbing(trace, actions, info, i + 1, j, t);
  }
}

// R5: CloneInheritsDeps — by WellFormedInfo (structural).
lemma R5_CloneInheritsDeps(info: map<int, TaskInfo>, c: int)
  requires WellFormedInfo(info)
  requires c in info && info[c].replanOf >= 0
  ensures info[c].replanOf in info
  ensures info[c].deps == info[info[c].replanOf].deps
{
}

// R6: CloneCarriesReplanOf — direct from StepReplanSupersedeClone's
// precondition that info[c].replanOf == orig.
lemma R6_CloneCarriesReplanOf(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i].ReplanSupersedeClone?
  requires actions[i].c in info
  ensures info[actions[i].c].replanOf == actions[i].orig
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
  var orig := actions[i].orig;
  var c := actions[i].c;
  assert StepReplanSupersedeClone(trace[i], trace[i + 1], info, orig, c);
  // StepReplanSupersedeClone requires c in info && info[c].replanOf == orig.
}

// R7: CascadeUpResetsTerminalAncestors — every ancestor passed to the
// cascade ends up PNew in the next state.
lemma R7_CascadeUpResetsTerminalAncestors(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, a: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i].ReplanCascadeUp?
  requires a in actions[i].ancestors
  ensures a in trace[i + 1].phase && trace[i + 1].phase[a] == PNew
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
  match actions[i] {
    case ReplanCascadeUp(t, ancestors) =>
      assert StepReplanCascadeUp(trace[i], trace[i + 1], info, t, ancestors);
      assert a in ancestors;
      assert a in trace[i].phase;        // from precondition
      assert trace[i + 1].phase == MapResetMany(trace[i].phase, ancestors);
  }
}

// R8: CascadeUpSkipsNonTerminal — any task NOT in the cascade's
// `ancestors` set is unchanged (whether or not it's in deps^*).
lemma R8_CascadeUpSkipsNonTerminal(trace: seq<State>, actions: seq<Action>, info: map<int, TaskInfo>, i: int, t: int)
  requires ValidTrace(trace, actions, info)
  requires 0 <= i < |actions|
  requires actions[i].ReplanCascadeUp?
  requires t in trace[i].phase
  requires t !in actions[i].ancestors
  ensures t in trace[i + 1].phase && trace[i + 1].phase[t] == trace[i].phase[t]
{
  assert Step(trace[i], trace[i + 1], info, actions[i]);
  match actions[i] {
    case ReplanCascadeUp(_, ancestors) =>
      assert trace[i + 1].phase == MapResetMany(trace[i].phase, ancestors);
  }
}
