---
name: domain-modeling
description: "Sharpen domain terminology and record accepted decisions in context documentation and ADRs."
---

# Domain model

Follow the [domain documentation](../../../docs/agents/domain.md).
This repository keeps its glossary in `CONTEXT.md`; use `CONTEXT-MAP.md` for multiple
contexts. Preserve the existing structure rather than creating a second glossary.

Compare terms used during design with the glossary. Verify discrepancies in the code
and raise them as questions for the user; do not record an unapproved proposal as an
accepted decision. Clarify ambiguous terms through concrete scenarios.

Record newly agreed terms as you go. Use the [context format](CONTEXT-FORMAT.md)
for a new context. The glossary describes the domain, not an implementation plan
or progress notes.

Propose an ADR when a decision is costly to change, surprising without context
and based on an actual comparison of alternatives. Use the [ADR format](ADR-FORMAT.md).
When an accepted decision changes, preserve its history and explicitly state the new
status, decision source and replacement. An agent preference does not authorize an ADR change.

Done: recorded terms and decisions match what the user confirmed, and their status
is unambiguous. Do not automatically delegate research or implementation.
