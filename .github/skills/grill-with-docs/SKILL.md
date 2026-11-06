---
name: grill-with-docs
description: "Clarify a design with the user and record agreed terminology and decisions as you go."
disable-model-invocation: true
---

# Design with documentation

Invoke the `grilling` and `domain-modeling` skills. The current session owns the design.
Follow the domain documentation referenced by `AGENTS.md`; this repository keeps
its glossary in `CONTEXT.md`.

Verify facts directly. Delegate research only when it has a bounded, independent
question and needs separate context. Do not duplicate the same research in parallel.
The user decides; keep agent proposals separate from accepted decisions.

Record accepted decisions and their reasons in the appropriate domain documentation
as you go. Create ADRs according to `domain-modeling` criteria, not for every answer.

Done: the user has confirmed the scope, boundaries, material decisions and remaining
uncertainties. They can then invoke `/to-spec` and `/to-tickets` in the same session.
Do not invoke these user-only commands automatically.
