---
name: grill-with-docs
description: "Clarify a design with the user and record agreed terminology and decisions as you go."
disable-model-invocation: true
---

# Design with documentation

Read the [development workflow](../../../docs/agents/development.md).
Invoke `grilling` for the interview and `domain-modeling` for terminology and decisions.

Record accepted decisions and their reasons in the appropriate domain documentation
as you go. Create ADRs according to `domain-modeling` criteria, not for every answer.

Done: the interview's completion criteria are met and accepted decisions are recorded.
The user can then invoke `/to-spec` and `/to-tickets` in the same session.
Do not invoke these user-only commands automatically.
