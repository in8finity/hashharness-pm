# system-models/

Formal models (`*.als`, `*.dfy`) plus the reconciliation reports under `reports/`.

## enforcement.yaml + check_enforcement.py

`enforcement.yaml` maps each verified property to the evidence that
enforces it: model assertions, code call sites, exit codes, skill-text
phrases, and golden tests. `check_enforcement.py` reads the YAML and
verifies every cited gate is actually present in the repo (AST parse
for code calls, grep for everything else). Run from repo root:

    python3 system-models/check_enforcement.py

Exit 0 if every entry passes, non-zero with a per-property red/green
table if anything has drifted. Wire into CI to catch the prose-claims-
something-the-code-no-longer-has class of bug. To add a new property:
append an entry to the YAML following the seed schema; first run will
tell you what's missing.

Seed file is one entry (`sticky_chain_coherence`). Backfilling the
remaining 40 properties is tracked as a follow-up.
