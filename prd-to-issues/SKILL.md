---
name: prd-to-issues
description: Break a PRD into independently-grabbable GitHub issues using tracer-bullet vertical slices. Use when user wants to convert a PRD to issues, create implementation tickets, or break down a PRD into work items.
---

# PRD to Issues

Break a PRD into independently-grabbable GitHub issues using vertical slices (tracer bullets).

## Process

### 1. Locate the PRD

Ask the user for the PRD GitHub issue number (or URL).

If the PRD is not already in your context window, fetch it with `gh issue view <number>` (with comments).

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current state of the code.

### 3. Draft vertical slices

Break the PRD into **tracer bullet** issues. Each issue is a thin vertical slice that cuts through ALL integration layers end-to-end, NOT a horizontal slice of one layer.

Slices may be 'HITL' or 'AFK'. HITL slices require human interaction, such as an architectural decision or a design review. AFK slices can be implemented and merged without human interaction. Prefer AFK over HITL where possible.

<vertical-slice-rules>
- Each slice delivers a narrow but COMPLETE path through every layer (schema, API, UI, tests)
- A completed slice is demoable or verifiable on its own
- Prefer many thin slices over few thick ones
</vertical-slice-rules>

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each slice, show:

- **Title**: short descriptive name
- **Type**: HITL / AFK
- **Blocked by**: which other slices (if any) must complete first
- **User stories covered**: which user stories from the PRD this addresses

Ask the user:

- Does the granularity feel right? (too coarse / too fine)
- Are the dependency relationships correct?
- Should any slices be merged or split further?
- Are the correct slices marked as HITL and AFK?

Iterate until the user approves the breakdown.

### 5. Create the GitHub issues

For each approved slice, create a GitHub issue using `gh issue create`. Use the issue body template below.

Create issues in dependency order (blockers first) so you can reference real issue numbers in the "Blocked by" field.

<issue-template>
## Parent PRD

#<prd-issue-number>

## What to build

A concise description of this vertical slice. Describe the end-to-end behavior, not layer-by-layer implementation. Reference specific sections of the parent PRD rather than duplicating content.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

## Blocked by

- Blocked by #<issue-number> (if any)

Or "None - can start immediately" if no blockers.

## User stories addressed

Reference by number from the parent PRD:

- User story 3
- User story 7

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

Do NOT close or modify the parent PRD issue.
