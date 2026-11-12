---
name: improve-codebase-architecture
description: Use when reviewing a codebase for architectural friction, deepening opportunities, tightly coupled modules, poor test seams, or changes that would improve locality and agent navigation.
license: LICENSE
---

# Improve Codebase Architecture

Find evidence-backed opportunities to deepen modules, present them visually,
and help the user explore the strongest candidate.

## Workflow

Load each skill this workflow names through the Skill tool if your harness has
one, otherwise by reading its `SKILL.md`.

### 1. Establish constraints and scope

Load the `codebase-design` skill and follow its engineering-authority discovery
before reviewing the architecture. Guidance may resolve from a local corpus or
from the knowledge provider selected by the repository or harness, such as
Surface or Brain Cylinder. Do not choose or combine providers based only on
availability. Read the applicable domain glossary and ADRs. These sources govern
the review; the shared glossary must not rename or override precise repository
terms.

If the user names a module, subsystem, or pain point, use that scope. Otherwise,
inspect enough commit history to identify recently active areas. Favor code
likely to change again; deepening dormant code rarely earns its cost.

### 2. Explore

Use a subagent with a fresh context window to inspect the scoped code when
available, and give it the scope from step 1 and the friction signs below.
Look for experienced friction rather than applying a mechanical checklist:

- Understanding one concept requires moving among many shallow modules.
- Callers must know nearly as much as the implementation.
- Business rules or failure handling leak across a seam.
- Tight coupling defeats locality.
- Important behavior is hard to test through stable interfaces.
- Repository architecture or dependency-direction rules are being bypassed.

Apply the deletion test to suspected pass-through modules. Classify each
candidate's dependencies using `codebase-design`'s
[DEEPENING.md](../codebase-design/DEEPENING.md).

### 3. Present a visual report

Write a self-contained HTML report to the operating system's temporary
directory (`$TMPDIR`, else `/tmp`; `%TEMP%` on Windows) as
`architecture-review-<timestamp>.html`, then open it for the user.
Follow [HTML-REPORT.md](HTML-REPORT.md).

For each candidate include:

- Files and modules involved.
- The observed friction and supporting evidence.
- A plain-language direction, without designing the final interface.
- Benefits stated through locality, leverage, and testability.
- A before-and-after diagram.
- A strength badge: `Strong`, `Worth exploring`, or `Speculative`.
- Any conflict with a repository instruction or ADR.

Finish with one top recommendation and ask which candidate the user wants to
explore.

### 4. Explore the selected candidate

Load the `grilling` skill to resolve constraints, dependencies, seam placement,
the shape of the deepened module, and the tests that should survive.

Load the `domain-modeling` skill whenever the discussion changes domain
terminology or produces an ADR-worthy decision. Load the `codebase-design` skill
and follow `DESIGN-IT-TWICE.md` when alternative interfaces would expose useful
tradeoffs.

Finish with a user-approved direction that complies with repository guidance;
do not implement it unless the user asks.
