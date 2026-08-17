# Architecture Decision Records

Use this personal default only when a repository has no decision-record
convention. Existing repository guidance always wins.

ADRs are short records of significant technical choices: one problem, one
decision, and its consequences. Create `docs/adrs/` only when the first ADR is
actually needed.

Product behavior belongs in product requirements. Implementation slices belong
in tickets. Deployment values and operating procedures belong in a runbook when
they are facts rather than the decision itself.

## Shape

Use plain Markdown with no frontmatter and these sections in order:

```markdown
# NNNN: Imperative specific title

## Status

Proposed

## Context

Why this decision is needed now, including related ADRs.

## Decision

- The choice and its load-bearing constraints.

## Consequences

- Follow-on work, migrations, tests, documentation, and deferred non-decisions.
```

The filename is `docs/adrs/NNNN-kebab-slug.md`. Its zero-padded number must
match the title. List existing ADRs and choose one greater than the highest
number; never reuse a gap.

Titles are imperative and specific. A reader should understand the choice after
reading Context and Decision.

## Status

Keep Status limited to lifecycle:

- `Proposed`
- `Accepted`
- `Accepted. Amended by [NNNN](NNNN-follow-on.md).`
- `Superseded by [NNNN](NNNN-replacement.md)`

When several ADRs amend one decision, join number-only links with `and`. Put the
relationship on the earlier ADR; the new ADR remains `Proposed` or `Accepted`
and explains the relationship in Context or Decision.

## Scope and length

- Record one decision per ADR. Split diverging concerns.
- Prefer roughly 40–70 lines of prose, excluding clarifying diagrams.
- Allow extra detail when an exact safety, security, or concurrency contract is
  necessary to prevent catastrophic mistakes.
- Move audience-specific inventories, commands, and operational values into the
  appropriate runbook or specification.
- Use plain human language, declarative Decision bullets, and concise
  Consequences bullets.

Optional diagrams, short alternatives, or precise contract tables may follow
Decision when they materially clarify it.

## Qualification

Offer an ADR only when the decision is hard to reverse, surprising without its
rationale, and the result of a genuine tradeoff.

Good subjects include:

- Architectural shape and integration patterns.
- Ownership, scope, and explicit exclusions; what the system deliberately will
  not do can be as important as what it will do.
- Deliberate deviations from the obvious approach, so a later agent does not
  “correct” an intentional choice.
- Constraints invisible in code, such as compliance, partner contracts, or
  operational limits.
- Technology choices with high replacement cost. A choice that would require a
  substantial migration or months of work is more likely to merit an ADR than a
  library that can be swapped locally.
- Rejected alternatives only when their rejection is non-obvious or someone is
  likely to propose them again.

## Verification

Run the repository's ADR validator, Markdown checks, and linked review workflow
when they exist. Otherwise verify manually that:

- The path, filename, title number, and section order match this format.
- Status contains only lifecycle information and valid relative links.
- Context explains why the decision is needed now.
- Decision states one choice and its load-bearing constraints.
- Consequences record follow-ons and deferred non-decisions.
- Product behavior, implementation slicing, and operational facts remain in
  their proper authorities.
