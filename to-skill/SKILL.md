---
name: to-skill
description: Use when creating, writing, editing, or auditing an agent skill, authoring a SKILL.md, or packaging a capability into a skill folder.
---

# Writing Skills

Skill makes agent behave **same way every run** — same process, not same output.
**Predictability** is the goal; every rule below is a lever on it.

## Process

1. **Gather reqs** — task/domain? use cases (branches)? scripts or instructions? reference material?
2. **Watch baseline** — see how agent handles task *without* skill. Teach only what it gets wrong; the rest is no-op tokens (see Pitfalls).
3. **Draft** — `SKILL.md` (frontmatter + playbook body); reference files only for conditional content; scripts only for deterministic ops (validation, formatting).
4. **Verify** — cold-start test (fresh session picks it up from natural task, follows it) + checklist below.

## Folder structure

```text
skill-name/
  SKILL.md              # entry point (required)
  reference/            # conditional docs (optional)
  scripts/              # deterministic helpers (optional)
```

## Choose invocation first

Every skill pays one of two loads. Decide before writing.

- **Model-invoked** (keep `description`): agent triggers it. Costs **context load** — description sits in window every turn.
- **User-invoked** (`disable-model-invocation: true`): human triggers by name. Zero context load, but costs **cognitive load** — human must remember it.

Model-invoked only when agent must reach it alone. Else user-invoked, no context load. User-invoked skills pile up past memory -> add one *router* skill naming the rest.

## Write the description (triggers only)

Model-invoked: description is the whole routing layer.

- State **only when to trigger** — verbs, nouns, symptoms, contexts the user says. Never summarize workflow.
- **Why:** workflow in description -> agent follows it *instead of* reading body. Description said "review between tasks" -> one review; body wanted two. Strip process -> agent reads real thing.
- Lead with user's words. Third person. Max 1024 chars.

```text
# Vague -> never fires
description: Helps with documents.

# Summarizes workflow -> agent shortcuts, skips body
description: Use when working with PDFs — extract text, fill forms, then merge.

# Triggers only -> agent reads body for the how
description: Use when working with PDF files, or user mentions PDFs, forms, extraction.
```

## Template

```md
---
name: skill-name
description: Use when [triggers, symptoms, contexts user says].
---

# Skill Name

[One line: what agent predictably does, anchored on a leading word.]

## Workflow

[Numbered steps — playbook, not essay. Each ends on checkable, exhaustive completion criterion.]

## Rules

[Short, concrete, positive constraints.]

When [edge case], see [reference/topic.md](reference/topic.md).
```

## Progressive disclosure (conditional references)

Reference files **not** auto-loaded — agent decides to read them. Disclosure works only when pointer is *conditional*:

- **Defeats purpose:** "Step 1: read reference/spec.md" -> always loaded.
- **Real disclosure:** "If [edge case], see reference/spec.md" -> loaded only when needed.

Split to a reference file only when: body handles ~80% of invocations without it, content is edge-case/one-branch, exceeds ~100 lines. Most invocations need it -> keep inline (splitting adds indirection, no saving). Must-have pointer fires unreliably -> sharpen its *wording* before inlining.

## Leading words

Anchor behavior to a concept already in the model's pretraining (*tracer bullets*, *fog of war*, *baseline*). Repeat the **word**, not a sentence -> accumulates meaning, recruits priors free. Reuse an existing word before coining one; made-up terms recruit no priors, cost definition tokens.

## Steer positively

Name the target, not the ban. "Don't think of an elephant" -> elephant fills view; "write one-line comments" beats "never write verbose comments." Keep a prohibition only as a hard guardrail you can't phrase positively, paired with the positive target.

## Language

Prose in American English (color, center, behavior, license). Verbatim for anything the agent copies literally — code blocks, error strings, identifiers, API/CLI/config names stay as their source spells them (`colour`, `behaviour`, `Referer`). In `description`, match the words the user actually types even when British — triggers optimize for recall, not house style.

## Adding scripts

Add scripts for deterministic ops, code regenerated repeatedly, or errors needing explicit handling. Scripts save tokens, beat generated code on reliability. Never hardcode secrets — skills get shared; use env vars.

## Pitfalls

- **Vague descriptions never fire.** "Helpful utilities" says nothing.
- **No-ops cost tokens.** Agent already does it by default -> cut the line.
- **Monolithic bodies defeat disclosure** — split only truly conditional content.
- **Too many model-invoked skills bloat the router.** Every description loads all session. Merge overlapping skills; make rare ones user-invoked.

## Editing an existing skill

Auditing/trimming/debugging -> diagnose against the failure-mode catalog (sediment, no-op, sprawl, duplication, premature completion) in [reference/diagnosing-skills.md](reference/diagnosing-skills.md).

## Review checklist

- [ ] Invocation chosen deliberately (model- vs user-invoked)
- [ ] Description triggers-only, in user's words — no workflow summary
- [ ] Body a playbook (numbered steps, headings), under ~100 lines
- [ ] Steps end on checkable completion criteria
- [ ] Constraints positive, not prohibitions
- [ ] Prose American English; code, error strings, identifiers verbatim; triggers match user's words
- [ ] Reference files conditional, not required steps
- [ ] No secrets, API keys, or stale time-sensitive info
- [ ] Cold-start test passes
