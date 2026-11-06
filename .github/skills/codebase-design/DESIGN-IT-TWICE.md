# Design It Twice

When the user wants to explore alternative interfaces for a chosen deepening candidate,
compare two designs directly in the current session. Based on "Design It Twice"
(Ousterhout): your first idea is unlikely to be the best. Independent agent designs
are optional and require an explicit user request, not just a request for alternatives.

Uses the vocabulary in [SKILL.md](SKILL.md): **module**, **interface**, **seam**, **adapter**, **leverage**.

## Process

### 1. Frame the problem space

Before drafting alternatives, explain the problem space for the chosen candidate:

- The constraints any new interface would need to satisfy
- The dependencies it would rely on, and which category they fall into (see [DEEPENING.md](DEEPENING.md))
- A rough illustrative code sketch to ground the constraints, not a proposal, just a way to make the constraints concrete

Use the agreed constraints in Step 2. Ask only when a missing decision prevents comparison.

### 2. Draft alternatives

Draft two materially different interfaces. If the user explicitly requested independent
agent designs, use at most two bounded design subagents with repository model routing.
Do not delegate the same designs again or allow further agent fan-out.

Use different design constraints from the following examples. For independent agents,
provide a bounded technical brief: source pointers, coupling, dependency category from
[DEEPENING.md](DEEPENING.md), and what sits behind the seam.

- Agent 1: "Minimize the interface: aim for 1–3 entry points max. Maximise leverage per entry point."
- Agent 2: "Maximise flexibility: support many use cases and extension."
- Agent 3: "Optimise for the most common caller: make the default case trivial."
- Agent 4 (if applicable): "Design around ports & adapters for cross-seam dependencies."

Use [SKILL.md](SKILL.md) vocabulary and the domain documentation from `AGENTS.md`
(`CONTEXT.md` here), including in any delegated brief.

Each design includes:

1. Interface (types, methods, params, plus invariants, ordering, error modes)
2. Usage example showing how callers use it
3. What the implementation hides behind the seam
4. Dependency strategy and adapters (see [DEEPENING.md](DEEPENING.md))
5. Trade-offs: where leverage is high, where it's thin

### 3. Present and compare

Present designs sequentially so the user can absorb each one, then compare them in prose. Contrast by **depth** (leverage at the interface), **locality** (where change concentrates), and **seam placement**.

After comparing, give your own recommendation: which design you think is strongest and why. If elements from different designs would combine well, propose a hybrid. Be opinionated: the user wants a strong read, not a menu.
