---
name: technology-selection
description: Use when comparing, choosing, or migrating technologies.
---

# Technology Selection

Choose one evidence-backed default for the actual target system, with an
explicit condition that would reverse the decision.

## Workflow

1. Establish the decision frame. Classify the target as greenfield, incumbent,
   migration, or reusable guidance. Name the implementation target separately
   from repositories, products, and notes supplied only as comparative evidence.
2. Record architecture already decided, mandatory integrations, delivery and
   operational constraints, and the consumers of the decision. Ask only when a
   missing fact could change the recommendation.
3. Define only discriminating criteria. Consider committed architecture,
   correctness and type behavior, first-party ecosystem integration,
   maintenance, platform evolution, build and runtime cost, human and agent
   ergonomics, and switching cost where an incumbent exists.
4. Gather primary evidence from current official documentation, source code,
   package manifests, changelogs, and maintainer statements. Verify important
   seam claims through dependency inspection, generated output, or a focused
   spike when documentation is insufficient.
5. Separate general capability from project fit. Existing usage is evidence of
   costs and failure modes for a greenfield target; it becomes a consistency and
   migration constraint only for an incumbent target.
6. Reconcile disagreement by exposing the target assumptions and weighted
   criteria behind each recommendation. Do not average rankings or treat the
   latest recommendation as authoritative merely because it arrived last.
7. Recommend one default. State its strongest counterargument and the concrete
   condition that would reverse the choice. Give alternatives only when their
   tradeoffs materially affect the decision.
8. Record at the requested depth. A research answer may retain evidence and
   rationale; a durable decision note should contain the normative choice,
   rejected alternative when useful, and reversal condition without becoming a
   miniature research report.
9. Before writing durable guidance, find its canonical home and any conflicting
   decision. Revise or deprecate the old guidance and update required indexes or
   references rather than publishing two stable truths.
10. Verify completion: the target frame is explicit, decisive claims are
    sourced, one default and reversal condition exist, and written artifacts
    pass their repository's validation.

## Rules

- Weight ecosystem fit without misrepresenting it as general technical
  superiority.
- Treat developer familiarity as adoption-cost evidence, not an architecture
  decision by itself.
- Inspect helper implementations and dependencies before calling them
  framework-agnostic.
- Pair a prohibition with its selected behavior: “use X; do not introduce Y.”
- Preserve the user's requested granularity and distinguish sourced facts from
  engineering judgment.

For evidence weighting across greenfield and incumbent targets, read
[references/greenfield-vs-incumbent.md](references/greenfield-vs-incumbent.md).
