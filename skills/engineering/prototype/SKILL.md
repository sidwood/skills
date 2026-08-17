---
name: prototype
description: Use when the user wants to test whether logic or a state model feels right, compare substantially different UI directions, or answer a design question with throwaway code.
license: LICENSE
---

# Prototype

Build the smallest throwaway artifact that can answer one design question.

## Workflow

1. State the question and what observable result would answer it. If the user is
   unavailable and the question is ambiguous, infer the narrowest useful
   interpretation and label the assumption in the prototype.
2. Choose one mode:
   - For business logic, state transitions, data shapes, or API behavior, read
     [the logic prototype guide](references/logic.md).
   - For layout, information hierarchy, or interaction design, read
     [the UI prototype guide](references/ui.md).
3. Follow the repository's language, task runner, routing, and styling
   conventions. Keep the prototype close to the code it informs and name it so
   readers cannot mistake it for production code.
4. Make it trivial to run and expose the state or variation being evaluated.
5. Hand over the artifact, its run command or URL, the question it answers, and
   any important limitations.
6. When the question is settled, record the verdict in the relevant issue,
   specification, ADR, or repository note. Fold validated decisions into
   production code only when requested.
7. Preserve the prototype on a separate branch only when the user requests it
   or the repository establishes that convention. Do not create or switch
   branches, commit, or rewrite history merely because this skill was invoked.

## Prototype Constraints

- Keep state in memory unless persistence is the question being tested.
- Use scratch data and reversible operations; never mutate production data.
- Skip production abstractions, defensive completeness, and tests unless one of
  them is the subject of the experiment.
- Keep enough error handling to make the prototype usable and its limitations
  visible.
- Treat the result as evidence for a decision, not as production-ready code.
