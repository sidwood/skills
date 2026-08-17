---
name: commit-message
description: Use when the user wants to commit, is writing, amending, or rewording a commit message, or asks how to format, structure, or word a commit message.
---

# Commit Messages

Write an imperative subject plus optional body, held to the 50/72 rule.

## Workflow

1. Subject: capitalized, imperative mood, ≤ 50 characters. It completes "If applied, this commit will __" — "Add feature", "Fix bug", "Remove deprecated method", never "Added"/"Fixes"/"Removing".
2. Self-explanatory change? Subject only, no body.
3. Else: blank line, then body wrapped at 72 characters explaining why, not what — the diff already shows what. Flag non-obvious consequences.
4. Body lists: hyphen or asterisk + single space, blank line between bullets, hanging indent on wraps.

Done when the subject is an imperative ≤ 50 chars and any body is why-focused, blank-line-separated, and wrapped at 72.

## Template

```text
Capitalized imperative subject, 50 chars or less

Body explaining why, not what. Wrap at 72 characters. The blank line
separating subject from body is critical — tools like rebase confuse
the two run together.

- Hyphen or asterisk bullet, followed by a single space
- Blank line between bullets, hanging indent for wrapped lines
```

## Rules

- Imperative mood matches git's own messages (`git merge`, `git revert`).
- 72-character body wrap → clean `git log` on 80-column terminals.
