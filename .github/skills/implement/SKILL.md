---
name: implement
description: "Implement agreed work with TDD and targeted validation; one owner completes the whole delivery."
---

# Implementation

Read the supplied ticket or spec and the relevant repository rules. Ask when
a reference is ambiguous; do not redesign an already approved scope.

## Ownership

- **Partial work:** the caller owns the whole delivery, for example `/implement-spec`.
  Implement the assigned behavior and validate it with targeted checks. Return the changes,
  results and unmet criteria; the caller owns final review, publication and handoff.
- **Standalone delivery:** the current session also owns completion. After implementation,
  run `code-review` and complete the delivery according to `AGENTS.md`.

Standalone delivery is the default. Partial work must follow from the delivery owner's
assignment; it does not waive tests, security checkpoints or the commit-bound gate
before pushing.

## Work

Invoke `tdd` at pre-agreed seams where behavior can be tested.
For documentation-only work, check consistency and links; use documentation contract
tests when they exist. Do not create tautological tests of words in the text.

Run the smallest relevant tests and typechecks for the change. The repository defines
mandatory final validation; do not automatically add a full local suite alongside CI.
Make changes directly, without another implementation agent.

Done for partial work: behavior and targeted validation are evidenced, with explicit limitations.
Done for a standalone delivery: the completion conditions in `AGENTS.md` are also satisfied.
