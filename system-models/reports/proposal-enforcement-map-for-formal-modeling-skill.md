# Proposal: ship an enforcement-map checker as part of the `formal-modeling` skill

> **Audience:** maintainer of [`formal-modeling`](https://github.com/in8finity/claude-plugin) (and its sibling `formal-debugger`).
> **From:** observed drift in a real project (`hashharness-pm`) that uses the skill heavily.
> **TL;DR:** model+report alone don't catch a specific class of bug. A small data artifact + checker, generated alongside the model, would. Concrete shape and cost below.

## What broke (the motivating case)

`hashharness-pm` ships ten Alloy modules and six Dafny ports verifying ~67 invariants over a planning-board protocol. Two reconciliation reports (`planning-reconciliation.md`, `planning-enforcement.md`) crossed-checked each verified property against (a) the code that enforces it, (b) the skill prose that documents it, and (c) the integration tests that exercise it. Both reports were prose, written by inspection (LLM-assisted, with grep along the way).

A real-world user reported four enforcement gaps, of which one was a **model-level miss the audit had explicitly claimed didn't exist**: the `StickyChainCoherence` property says "every state-mutating subcommand refuses operations from a different sticky context." The audit row read:

> Sticky chains stay bound to one agent context | `store.check_sticky_eligibility`; refusal exit 10 across `executing` / `heartbeat` / `report` / `finished`

In reality:

| Subcommand | Actual implementation when the audit was written |
|---|---|
| `executing.py` | Full `check_sticky_eligibility` call ✓ |
| `report.py` | Partial check (own binding only, no chain walk) ✗ |
| `finished.py` | Partial check (same) ✗ |
| `heartbeat.py` | **No check at all** ✗ |

The model never knew. The report said the property was enforced. The code didn't enforce it across all four sites. The audit was written prose, and prose can lie about code without anything noticing — including when the prose is LLM-written.

The other reported issues were category mismatches (defaults, friction, ergonomics, integration) that no amount of formal modeling would have caught — but the sticky-asymmetry one was inside the skill's stated value proposition. That's the gap this proposal addresses.

## The proposed addition

Have the `formal-modeling` skill maintain (or generate, or just consume) a single per-project data artifact that maps each verified property to the mechanical evidence of its enforcement, and ship a checker that **fails if any claimed evidence is missing**.

The reconciliation report becomes a *render* of the artifact, not a hand-written narrative. The checker is the audit. CI runs the checker on every commit; the prose-drift class closes.

This is small enough to live as an additional subcommand of the existing `verify.sh` runner — say `verify.sh --check-enforcement system-models/enforcement.yaml` — or as a sibling script. It does not replace the existing model verification; it sits alongside it.

## Concrete artifact shape

```yaml
# system-models/enforcement.yaml — one entry per verified property
- id: sticky_chain_coherence
  description: Sticky-bound tasks reject operations from the wrong context_id
  models:
    - {file: planning.als,                  asserts: [StickyChainCoherence, StickyBindingOnlyAtClaim]}
    - {file: planning_sticky_rebinding.als, asserts: [SR1, SR2, SR3, SR4, SR5]}
  code_gates:
    - {file: skills/pm/scripts/executing.py,  must_call: store.check_sticky_eligibility, must_exit: 10}
    - {file: skills/pm/scripts/report.py,     must_call: store.check_sticky_eligibility, must_exit: 10}
    - {file: skills/pm/scripts/finished.py,   must_call: store.check_sticky_eligibility, must_exit: 10}
    - {file: skills/pm/scripts/heartbeat.py,  must_call: store.check_sticky_eligibility, must_exit: 10}
  skill_texts:
    - {file: skills/pm/executing/SKILL.md, must_mention: ["sticky", "exit 10"]}
  tests: [G8, G46s, G47, G48]
```

Per-entry checker semantics:

| Field | Check |
|---|---|
| `models[i].asserts` | Grep each named assertion in the .als file; verify it parses + has a paired `check`. (The existing `verify.sh` already runs the model — this just confirms the named assertion still exists.) |
| `code_gates[i].must_call` | AST-parse the file (Python `ast` module); assert the named function is referenced from at least one call expression. |
| `code_gates[i].must_exit` | Grep the file for `return <N>` or `sys.exit(N)`. |
| `skill_texts[i].must_mention` | grep each phrase as substring. |
| `tests[i]` | grep `tests/**/test_*.py` (or a configurable glob) for `def <test>_` |

Output: per-property green / red table, plus exit non-zero if any check fails. Easily wired to CI.

A property passes only when **every** line of its entry passes. A property without an entry — but with a `check` in the model — is flagged as "model claim, no enforcement evidence on file." A code path that imports the skill but isn't covered by any entry is also flaggable (optional second pass).

## Why this fits the `formal-modeling` skill specifically

1. The skill already produces models AND reconciliation reports. The artifact is the missing intermediate datum the report should have been built from.
2. The skill's existing convention "Alloy first, port to Dafny when stable" is preserved — the artifact references both formalisms naturally.
3. The skill is LLM-driven; LLMs write prose that drifts from code; this is structurally inverted by a checker that runs every commit.
4. CI integration is a single bash invocation. No new dependency surface beyond what `verify.sh` already needs (Python 3 + grep).

## Cost

- Checker script: ~250 LoC Python (AST + grep + YAML loader + render).
- Skill-side: ~50 lines added to the skill's procedure documenting "build the enforcement map alongside the model, not after."
- Existing-project migration cost: ~30–50 lines of YAML per verified property. For `hashharness-pm`'s 41 currently-tracked properties, that's a one-shot ~half-day backfill.

## What this still won't catch

- **Wrong predicates in the model.** If the model says "X" but X isn't the property the user cares about, the checker can't help — that's a modeling-quality problem.
- **Defaults / value judgments.** Whether `--cascade-up` should be the default or `--no-cascade` should be is a product call, not an invariant.
- **Friction / ergonomics / integration.** Sub-agent permission shapes, env propagation, body construction by orchestrator LLMs — all outside the protocol layer formal modeling addresses.

These remain exactly as today. The proposal closes the "claim doesn't match implementation" class, which is the class formal modeling currently *appears to* close but doesn't structurally.

## Stretch: generate the reconciliation report from the artifact

Once the artifact exists, the reconciliation report becomes a render. The skill could ship a `--emit-report markdown` mode that produces the same narrative table as today, but every cell is sourced from the YAML — so when the YAML changes (new property, new gate, new test), the report regenerates without prose drift.

That makes "the model says X is enforced at Y; here's the evidence" a single fact in one place, instead of three: (model assertion) + (code call site) + (audit prose claiming both exist).

## Recommendation

Add the enforcement map + checker as a subcommand of the formal-modeling skill's existing tooling, with a small section in the skill's prose documenting "while building / extending the model, also extend `enforcement.yaml`." Existing projects can adopt incrementally; new projects start with the discipline.

I'm happy to prototype the checker against `hashharness-pm`'s 41 properties and submit it as a starting point if that's useful.
