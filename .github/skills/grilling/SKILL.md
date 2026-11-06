---
name: grilling
description: "Stress-test a design through questions about decisions, dependencies and concrete scenarios."
---

# Grilling

Follow a decision tree: each decision unlocks the questions that depend on it.
The current session leads the interview and keeps verified facts, proposals,
accepted decisions and open questions distinct.

Choose a question whose prerequisites are already known. Ask it through the available
question tool, give a recommendation with its reason and wait for the answer.
One question must not hide several independent decisions. Do not reopen an accepted
decision without new evidence or a changed requirement.

Look up facts from the code and environment directly rather than asking the user.
Use a subagent only for bounded, independent research that needs separate context.
Do not delegate individual lookups or a single continuous code trace.
Do not base further decisions on an unverified fact.

Focus on scope, failure modes, measurable goals and costly assumptions.
Use concrete scenarios instead of demanding exhaustive hypothetical branching.

Done: the user has confirmed a shared understanding, material branches are resolved
and remaining uncertainties are explicit. Do not start implementation without a request.
