---
name: prd-review
description: Review a previously committed PRD GitHub issue — verify every user story has been implemented correctly and perform a QA pass on the code base for conventions, idiom, cleanliness, tests, and production readiness. Use when the user wants to review a PRD implementation, audit a delivered feature, sign off on a PRD, or mentions "PRD review".
---

# PRD Review

Review the implementation of a previously committed PRD. Verify every user story has been met and perform a quality assurance pass on the code that delivered it.

Be thorough but fair. Flag real issues, not style preferences.

## Process

### 1. Locate the PRD

Ask the user for the PRD GitHub issue number (or URL). Fetch it if it isn't already in context:

```bash
gh issue view <number> --comments
```

### 2. Discover the implementation

Identify the work that delivered the PRD so the review is grounded in real changes, not speculation:

- Sub-issues linked to the PRD (blocked-by / tracking dependencies produced by `to-issues`)
- Pull requests that reference the PRD or its sub-issues — e.g. `gh pr list --search "<prd-number> in:body" --state merged`
- The diffs of those merged PRs

If you cannot find any linked implementation, stop and ask the user to point you at it.

### 3. Explore the codebase

Read the modules and tests touched by the implementation. Check `UBIQUITOUS_LANGUAGE.md` and `AGENTS.md` (or equivalent conventions docs) so you judge idiom and style against the project's own bar — not your defaults.

### 4. Verify each user story

Build a checklist from the PRD's **User Stories** section. For each story:

- Locate the behavior that fulfills it (test, endpoint, UI flow, CLI command, job)
- Confirm the behavior is actually delivered — not just scaffolded or stubbed
- Note gaps, partial implementations, or regressions introduced elsewhere

Work from behavior, not implementation details. If you can't tell whether a story is delivered, that itself is a finding.

### 5. Quality assurance pass

Over the changed surface, evaluate:

- **Conventions** — does new code follow patterns already established in this repo (layout, naming, error shapes, logging, test structure)?
- **Idiomatic** — does it use the language and framework naturally, or fight them?
- **Clean** — readable, well-named, appropriately deep modules, no dead code, no leaky abstractions
- **Tested** — tests exist at the right layer, cover real behavior (not internals), and exercise edge cases and failure modes
- **Production ready** — error handling, input validation, authz/authn, logging, observability, backwards compatibility, migrations, rollout/rollback safety, resource limits

### 6. Be thorough but fair

Flag:

- User stories not delivered, partially delivered, or regressed
- Bugs, race conditions, unsafe defaults, missing validation or authorization
- Missing tests for non-trivial behavior or failure modes
- Clear violations of conventions already established in this repo
- Missing handling for realistic failure modes (timeouts, partial writes, bad input)

Do NOT flag:

- Style preferences the repo itself is inconsistent about
- Your personal naming, formatting, or abstraction tastes
- Speculative "what if" scenarios with no grounded risk
- Rewrites of working code for aesthetic reasons

For every finding, separate **must-fix** (blocks acceptance) from **nice-to-have** (optional follow-up).

### 7. Post the review

Post the review as a comment on the PRD issue:

```bash
gh issue comment <prd-number> --body-file <path-to-review.md>
```

Use this template:

<review-template>
## PRD Review

**PRD:** #<prd-number>
**Implementation:** #<pr-numbers>

### User story coverage

| # | Story (short) | Status | Evidence |
|---|---------------|--------|----------|
| 1 | ...           | Done / Partial / Missing | <PR, test name, or behavior> |
| 2 | ...           | ...                       | ... |

### Must-fix

- [ ] <concise, behavior-framed finding> — why it blocks acceptance
- [ ] ...

### Nice-to-have

- [ ] <optional follow-up> — why it's worth doing but not blocking
- [ ] ...

### Not flagged (intentionally)

Brief note on style or preference items you deliberately chose not to raise, so reviewers can see your bar.

### Verdict

Accept / Accept with must-fix follow-ups / Needs rework
</review-template>

### 8. File follow-up issues

Ask the user which findings they want tracked as issues. For each one, file a GitHub issue that references the PRD. Follow the `bug-report` skill's rules — describe behavior, use domain language, no file paths or line numbers.

## Rules

- Ground every finding in the diff or a user story — never vibes
- Describe behaviors, not code — "the import flow silently drops malformed rows" not "`handleRow()` swallows the exception"
- Respect the repo's existing conventions over your personal preferences
- If you can't tell whether a story is delivered, say so — that's a finding, not a guess
- A review that finds nothing is suspicious; one that finds everything is noise
