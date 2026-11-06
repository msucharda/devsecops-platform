---
name: implement
description: "Implement an assigned outcome with TDD and targeted validation; complete its PR or return partial work."
---

# Implementation

Read the supplied ticket or spec, the [development workflow](../../../docs/agents/development.md)
and the implementation rules reached through `AGENTS.md`. Ask when
a reference is ambiguous; do not redesign an already approved scope.

## Ownership

- **Partial work:** the caller explicitly retains review, publication and handoff.
  Implement the assigned behavior and validate it with targeted checks. Return the changes,
  results and unmet criteria; the caller owns final review, publication and handoff.
- **Standalone delivery:** the current session owns completion of its assigned outcome,
  including a lever lane. Run `code-review`, fix findings and complete its PR according
  to `AGENTS.md`; the coordinator retains spec-wide integration and acceptance.

Standalone delivery is the default. Partial work must follow from the delivery owner's
assignment; it does not waive tests, security checkpoints or the commit-bound gate
before pushing.

## Work

Invoke `tdd` at pre-agreed seams where behavior can be tested.
For documentation-only work, check consistency and links; use documentation contract
tests when they exist. Do not create tautological tests of words in the text.

Run the smallest relevant tests and typechecks for the change. The repository defines
mandatory final validation; do not automatically add a full local suite alongside CI.
Follow the development workflow's ownership and implementer limits.

Done for partial work: behavior and targeted validation are evidenced, with explicit limitations.
Done for a standalone delivery: the completion conditions in `AGENTS.md` are also satisfied.
