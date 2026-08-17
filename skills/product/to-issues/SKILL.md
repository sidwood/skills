---
name: to-issues
description: Use when the user wants to turn a PRD, specification, plan, issue, or settled conversation into independently grabbable GitHub issues or implementation tickets.
license: LICENSE
---

# To Issues

Break agreed work into tracer-bullet GitHub issues with explicit blocking edges.

## Process

### 1. Gather the source

Use the source already in context: a PRD, specification, plan, issue, or settled
conversation. If the user provides an issue number or URL, fetch its complete
body and comments.

Ask for source material only when the current context cannot define the work.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, inspect the affected area to
understand its architecture and integration layers. Use repository domain
vocabulary and respect relevant ADRs.

Look for preparatory refactoring that would make the change easier. Put that
work first only when it creates a useful seam or reduces risk for later slices.

### 3. Draft vertical slices

Break the source work into **tracer bullet** issues. Each issue is a thin
vertical slice that cuts through all integration layers end-to-end rather than
a horizontal slice of one layer.

Size each slice to fit in one fresh agent context window.

Slices may be `HITL` or `AFK`. HITL means a single supervised agentic loop: an
agent can do the work end-to-end, but the user should remain available because
the slice establishes product, domain, or architecture decisions that later
work depends on. Do not mark a slice HITL merely because it is difficult or
needs normal code review. AFK slices can be implemented and merged without
user attention beyond normal review. Prefer AFK where product and domain
decisions are already clear.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
- Every slice fits in one fresh context window
</vertical-slice-rules>

#### Wide refactors

A wide refactor is one mechanical change whose blast radius prevents any
vertical slice from landing green by itself. Sequence it as expand-contract:

1. **Expand:** introduce the new form beside the old one without breaking callers.
2. **Migrate:** move callers in batches sized by package, directory, or another
   coherent boundary. Each batch is blocked by the expansion.
3. **Contract:** remove the old form after every migration batch is complete.

If individual migration batches cannot stay green, keep the dependency
sequence but use an integration branch established for the effort. Add a final
integrate-and-verify issue blocked by every batch, and state clearly that green
is guaranteed only there.

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **What it delivers**: the end-to-end behavior made possible by the slice
- **Source coverage**: user stories, requirements, or decisions it addresses

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?

Iterate until the user approves the breakdown.

### 5. Create the GitHub issues

For each approved slice, create a GitHub issue using `gh issue create`. Use the
issue body template below.

Create issues in dependency order (blockers first) so you can reference real issue numbers in the "Blocked by" field.

Every issue MUST be labeled with either `hitl` or `afk` to match its Type. Pass the label via `gh issue create --label hitl` or `gh issue create --label afk`.

Before creating the first issue, ensure both labels exist in the repo. If either is missing, create it:

```bash
gh label create hitl --description "Requires supervised agentic loop" --color B60205 || true
gh label create afk  --description "Can be implemented without human interaction" --color 0E8A16 || true
```

<issue-template>
## Parent

<source issue reference, when one exists; otherwise omit this section>

## What to build

A concise description of this vertical slice. Describe end-to-end behavior,
not a layer-by-layer implementation list. Reference the source rather than
duplicating it.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Blocked by

- Blocked by #<issue-number> (if any)

Or "None - can start immediately" if no blockers.

## Source coverage

Reference user stories, requirements, plan sections, or decisions:

- User story 3
- Implementation decision: <name>

</issue-template>

### 6. Link native issue dependencies

In addition to the "Blocked by" section in the body text, register every dependency as a native GitHub issue dependency. This makes the blocker relationship appear in GitHub's UI and API, not just as prose.

The `gh` CLI does not yet have first-class flags for this, so use `gh api` against the REST endpoint. The endpoint requires the blocker's **database ID** (globally unique integer), not its issue number.

For each slice that is blocked by one or more other slices, run:

```bash
BLOCKER_ID=$(gh api "repos/<owner>/<repo>/issues/<blocker-number>" --jq .id)
gh api \
  --method POST \
  -H "Accept: application/vnd.github+json" \
  "repos/<owner>/<repo>/issues/<blocked-number>/dependencies/blocked_by" \
  -f "issue_id=$BLOCKER_ID"
```

Repeat for every `blocked-by` relationship. If a slice has multiple blockers, make one call per blocker.

After linking, verify with:

```bash
gh api "repos/<owner>/<repo>/issues/<blocked-number>/dependencies/blocked_by" \
  --jq '.[].number'
```

The listed numbers should match the "Blocked by" entries in the issue body.

Do not close or modify the source issue.
