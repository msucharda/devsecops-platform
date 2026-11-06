---
name: security-checkpoint
description: "Independently review a completed security or identity control design and its tests according to AGENTS.md."
---

# Security checkpoint

The [repository checkpoint rules](../../../docs/agents/repository-rules.md#security-checkpoint-během-implementace)
define the trigger and scope. This skill defines execution, not another review for every ticket.

1. Prepare a fixed snapshot of the change, including tests and new files. Use the selected
   base revision and record its SHA; do not automatically fetch and change a shared ref
   during another session's gate. For uncommitted changes, supply an immutable diff snapshot.
2. Include the assignment, accepted decisions and primary documentation links, including
   the version of every external API called or mocked by the change. Do not give the reviewer
   the implementer's rationale or conclusions.
3. Select a reviewer according to [model routing](../../../docs/agents/model-routing.md).
   Verify a different model family from the implementer and a fresh context.
4. Start one read-only review subagent. Use background execution only while doing independent
   work; otherwise wait directly. Use a completion notification rather than a model-driven
   polling loop. The reviewer must not delegate further.
5. Record the report and disposition of each finding: fixed with a regression test,
   rejected with evidence, or a follow-up for an unrelated pre-existing issue.
   Findings caused or worsened by the change must be resolved before completion.

## Review scope

- External API shapes against primary documentation, including variants and fixtures.
- Fail-open states: empty, unknown or unreadable values must not pass.
- Recovery from interruptions between state-changing steps and its regression tests.

For each finding, the reviewer returns severity, file and location, failure scenario,
evidence and a proposed fix. With no findings, state the areas verified.
The reviewer does not make fixes or publish changes.

## Result

`running` is not a pass. `failed` means a missing or incomplete report; report
the blocker and cause, and do not repeat the same failed attempt without new information.
`completed` requires a report and a disposition for every finding.

After a change to the reviewed security behavior, independently verify fixes and their effects
again. Changed conditions, contracts and recovery determine the scope, not the line count.
A newly completed control triggers a checkpoint according to the repository checkpoint rules.
Do not resubmit an unchanged snapshot with an evidenced completed checkpoint.
