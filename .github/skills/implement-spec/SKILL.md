---
name: implement-spec
description: "Implement an approved spec and its tickets directly in the current session on one branch."
disable-model-invocation: true
---

# Direct spec implementation

The current session owns the whole delivery. Use the assigned worktree and branch;
do not create a coordinating session, another branch or a separate implementer
for every ticket. The [development workflow](../../../docs/agents/development.md)
defines the process and responsibilities.

## Process

1. Read the spec, tickets and their dependencies, `AGENTS.md` and relevant ADRs.
   Verify that the branch includes the accepted design. If the design PR has not
   been accepted, report a blocker; do not start an unrequested stack.
2. Identify the work graph and how to verify the criteria. Reuse accepted decisions
   and seams; do not start another design round without a concrete discrepancy.
3. Select an unblocked ticket and invoke `implement` in **partial work** mode.
   Make the change directly. After targeted validation, record the satisfied criteria
   and continue with the next ticket.
4. Distinguish an implementation dependency within this delivery from an external blocker.
   An internal ticket can unblock another after implementation and validation on the same
   branch; this does not close its issue. An external dependency must actually be satisfied.
   Do not present "implemented locally" as an accepted delivery.
5. Check coverage of the whole spec. Run one final `code-review` of the integrated change.
   Fix findings yourself and verify the fixes and their effects according to that skill.
6. Complete the delivery according to `AGENTS.md`: commit, local gate and, when publication
   is requested, push and one PR. Tracker rules govern issue closure.
   Create a PR when explicitly requested or when it is the tracker's standard delivery
   mechanism. Merging requires a separate mandate.

## Delegation and blockers

Implementation is sequential by default. Parallel implementation requires explicit user
approval and must stay within the limits in `AGENTS.md`. This session owns routine integration
and fixes; a merger or repair implementer is not another automatic step.
Mandatory independent review and security checkpoints remain required.

When blocked, use the `blocked` status and a resumption condition according to `AGENTS.md`.
Do not create a model-driven polling loop. A STOP instruction requires new explicit permission
before resuming.

Done: acceptance criteria are evidenced and the completion conditions in `AGENTS.md`
are satisfied. An opened PR or partial local validation alone is insufficient.
