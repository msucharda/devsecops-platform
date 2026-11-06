---
name: to-spec
description: "Turn an agreed design from the conversation into a verifiable spec and publish it to the issue tracker."
disable-model-invocation: true
---

# Spec from an agreed design

Use the existing conversation, domain documentation and verified evidence.
Do not repeat completed exploration or interviews. Look up only missing or changed
facts. Raise conflicts with accepted decisions with the user rather than resolving them
through assumptions.

1. Read the issue tracker and triage rules referenced by `AGENTS.md`, and the
   [handoff contract](../../../docs/agents/development.md#kontrakt-předání).
2. Identify seams and success criteria. Reuse approved seams; ask the user to confirm
   new or changed ones.
3. Write the spec using the template below. Describe each required behavior once.
   Scope determines the number of user stories, not a length target.
4. Publish the spec to the issue tracker. Use `ready-for-agent` only when no remaining
   decision blocks implementation; otherwise use the appropriate triage status
   and explicitly state the open question.

## Template

The literal headings below remain Czech for the published spec, as required by `AGENTS.md`.

- **Problém:** the user's original request verbatim, followed by the observable current limitation.
- **Řešení:** the required behavior from the user's perspective.
- **User stories a akceptační kritéria:** a complete, non-repetitive list;
  a verifiable outcome for each behavior, including material failure modes.
- **Přijatá rozhodnutí:** interfaces, contracts, constraints and ADR references.
  Label proposals and unverified claims separately.
- **Ověření:** agreed seams, existing test patterns and measurable limits.
- **Mimo rozsah:** explicitly excluded behavior.
- **Otevřené otázky:** remaining decisions, or the literal `Žádné`.

Do not overload the spec with file lists or implementation steps. An exact contract
or a prototype decision may include a short code excerpt when it is more precise than prose.

Done: the published spec distinguishes decisions from proposals, its criteria can be
verified without the conversation, and the user's approval or remaining approval blocker
is explicit. Publication alone is not approval. Do not start implementation or `/to-tickets`.
