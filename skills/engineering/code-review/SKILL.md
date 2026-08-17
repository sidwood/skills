---
name: code-review
description: Use when the user asks to review a branch, pull request, working diff, or changes since a commit, branch, or tag. Do not use for final acceptance of an entire PRD; use prd-review.
license: LICENSE
---

# Code Review

Review a bounded diff independently against repository standards and the change's
originating specification.

## Workflow

1. **Pin the comparison.** For a branch or pull request, use the fixed point
   supplied by the user, its configured base, or the default branch, in that
   order, and review the three-dot merge-base diff. For working-tree changes,
   review tracked changes against `HEAD` and include untracked files explicitly.
   Resolve the comparison before reviewing, confirm it is non-empty, and record
   the commits and files in scope.
2. **Load the authorities.** Read repository instructions, applicable ADRs, and
   any engineering corpus or knowledge provider explicitly selected by the
   repository or user. A connected provider is not authoritative merely because
   it is available.
3. **Find the specification.** Check linked issues and pull requests, user-supplied
   paths, commit messages, and matching documents under the repository's normal
   specification locations. If none exists, perform the standards review and
   report that the specification axis was unavailable.
4. **Run two independent passes.** When delegation is available, run them in
   parallel reviewers with separate context; otherwise perform one complete pass
   at a time.
   - **Standards:** compare the diff with documented conventions and relevant
     surrounding code. Use [the code-smell baseline](references/code-smells.md)
     only as labeled heuristics. Repository guidance overrides it.
   - **Specification:** find missing or partial requirements, unintended scope,
     and behavior that appears to implement a requirement incorrectly. Cite the
     requirement supporting each finding.
5. **Validate every finding.** Inspect enough surrounding code and tests to rule
   out false positives. Run focused read-only checks when they materially improve
   confidence. Skip formatting and other issues already enforced by tooling.
6. **Report the axes separately.** Rank findings by severity within each axis.
   Give each actionable finding a precise file and line, supporting evidence,
   consequence, and concise recovery direction. End with the finding count and
   worst issue for each axis.

## Rules

- Review only the agreed diff, while reading surrounding code for context.
- Ground findings in repository guidance, a requirement, or demonstrable behavior.
- Distinguish documented violations from judgment calls.
- Do not modify files, post comments, approve reviews, or file issues unless the
  user separately asks for those actions.
- An empty review is valid when the evidence supports it; never manufacture a
  finding to appear thorough.
