---
name: grilling
description: "Stress-test a design through questions about decisions, dependencies and concrete scenarios."
---

# Grilling

Follow a decision tree: each decision unlocks the questions that depend on it.
The current session leads the interview under `AGENTS.md`'s evidence and delegation rules.

Choose a question whose prerequisites are already known. Ask it through the available
question tool, give a recommendation with its reason and wait for the answer.
One question must not hide several independent decisions. Do not reopen an accepted
decision without new evidence or a changed requirement.

Look up facts from the code and environment rather than asking the user.
Resolve unverified prerequisites before basing further decisions on them.

Focus on scope, failure modes, measurable goals and costly assumptions.
Use concrete scenarios instead of demanding exhaustive hypothetical branching.

Done: the user has confirmed a shared understanding, material branches are resolved
and remaining uncertainties are explicit. Do not start implementation without a request.
