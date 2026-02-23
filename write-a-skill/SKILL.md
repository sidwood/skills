---
name: write-a-skill
description: Write, create, or scaffold agent skills with SKILL.md, scripts, and reference files. Use when user wants to make a new skill, create a SKILL.md, or package a capability as a skill folder.
---

# Writing Skills

## Process

1. **Gather requirements** — ask the user:
   - What task or domain does the skill cover?
   - What use cases should it handle?
   - Does it need scripts or just instructions?
   - Any reference materials to include?

2. **Draft the skill** — create:
   - `SKILL.md` with frontmatter (`name`, `description`) and concise instructions
   - Sibling reference files only if content is conditionally needed (see below)
   - Utility scripts if operations are deterministic (validation, formatting)

3. **Review with user** — present draft, then verify against the checklist at the end of this file.

## Folder structure

```
skill-name/
  SKILL.md              # Entry point (required)
  reference/            # Conditional docs (optional)
  scripts/              # Deterministic helpers (optional)
```

## Template

```md
---
name: skill-name
description: [What it does]. Use when [verbs and nouns the user will actually say].
---

# Skill Name

## Workflow

[Numbered steps — a playbook, not an essay]

## Rules

[Short, concrete constraints]

If [specific edge case], see [reference/topic.md](reference/topic.md).
```

## Writing the description

The description is the **only** thing the agent reads every turn. It's the entire routing layer.

- Lead with trigger verbs and nouns users will actually say
- First sentence: what it does. Second sentence: "Use when [triggers]."
- Max 1024 chars. If it's vague, the skill never fires.

## Using reference files (progressive disclosure)

Reference files are **not** auto-loaded when a skill fires. The agent must actively decide to read them. This means progressive disclosure only works when references are **conditional**:

- **Defeats the purpose:** "Step 1: Read reference/spec.md" — agent always loads it.
- **Actual progressive disclosure:** "If you encounter [edge case], check reference/spec.md" — agent loads it only when needed.

Only split into reference files when:
- The body handles 80% of invocations without the reference
- The reference is for edge cases, not the main workflow
- Content exceeds ~100 lines and has distinct conditional domains

If most invocations need the content, keep it in SKILL.md. Splitting just to split adds indirection with no token savings.

## Adding scripts

Add scripts when the operation is deterministic, the same code would be regenerated repeatedly, or errors need explicit handling. Scripts save tokens and improve reliability vs. generated code.

## Pitfalls

- **Vague descriptions never fire.** "Helpful utilities" tells the agent nothing.
- **Monolithic bodies defeat progressive disclosure.** But only split when references are truly conditional.
- **Never put secrets in SKILL.md.** Reference env vars — skills get committed and shared.
- **Too many skills bloat the router.** Every description sits in context all session. Merge overlapping skills.

## Review checklist

- [ ] Description leads with trigger verbs/nouns the user will say
- [ ] SKILL.md body reads as a playbook (numbered steps, headings)
- [ ] Body stays under ~100 lines
- [ ] Reference files are framed conditionally, not as required steps
- [ ] No secrets, API keys, or sensitive URLs
- [ ] No time-sensitive info that will go stale
- [ ] Cold-start test: a fresh session picks it up from a natural task description
