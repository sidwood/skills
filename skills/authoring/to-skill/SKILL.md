---
name: to-skill
description: Use when creating, writing, editing, or auditing an agent skill, authoring a SKILL.md, or packaging a capability into a skill folder.
---

# Writing Skills

Skills make agents follow the **same process**, not produce the same output.
**Predictability** is the goal; every instruction should improve it.

## Process

1. **Gather requirements** — establish task, branches, invocation mode,
   permissions, references, and need for deterministic scripts.
2. **Watch the baseline** — observe behavior without the skill. Teach only what
   fails; everything else is no-op context.
3. **Draft** — write the smallest playbook preserving user scope and choices.
   Add resources only when they materially improve execution.
4. **Validate** — check structure and metadata, run changed scripts, and verify
   observable behavior rather than headings or generated wording.
5. **Forward-test** — when complexity or risk warrants it, use a fresh evaluator
   in an isolated workspace without the expected answer or suspected defect.
   Finish when realistic requests follow the intended process.

## Folder structure

```text
skill-name/
  SKILL.md              # entry point (required)
  agents/               # harness metadata and invocation policy (optional)
    openai.yaml
  scripts/              # deterministic helpers (optional)
  references/           # conditional documentation (optional)
  assets/               # templates or output resources (optional)
```

Create optional directories only for concrete files with a purpose. Add no
README, changelog, or installation guide unless packaging requires one.

## Choose invocation first

Choose one load before writing. Preserve existing policy unless asked to change
it.

- **Model-invoked**: matching natural-language requests may load the skill.
  Omit `disable-model-invocation`; if `agents/openai.yaml` exists, set
  `allow_implicit_invocation: true`.
- **User-invoked**: users must select or name the skill. Set
  `disable-model-invocation: true` in `SKILL.md` frontmatter and set Codex's
  `agents/openai.yaml` policy to `allow_implicit_invocation: false`.

Use model invocation only when agents must find the skill alone; otherwise use
explicit invocation. If explicit skills become hard to remember, add a router.

## Write the description

For model-invoked skills, `description` is the routing layer.

- State trigger verbs, nouns, symptoms, and contexts only; keep workflow in the
  body.
- Lead with user language, write in third person, stay under 1,024 characters,
  and add exclusions only to prevent likely misrouting.

```text
# Vague
description: Helps with documents.

# Summarizes workflow
description: Use with PDFs — extract text, fill forms, then merge.

# Triggers only
description: Use when working with PDF files, forms, or extraction.
```

## Template

```md
---
name: skill-name
description: Use when [triggers, symptoms, or contexts the user supplies].
---

# Skill Name

[One line describing the predictable outcome, anchored on a leading word.]

## Workflow

[Numbered steps ending in checkable, exhaustive completion criteria.]

## Rules

[Short, concrete, positive constraints.]

When [edge case], see [references/topic.md](references/topic.md).
```

## Progressive disclosure

References are not auto-loaded. Point to one only when its branch applies:

- **Always loaded:** “Step 1: read `references/spec.md`.”
- **Conditional:** “For database migrations, read `references/schema.md`.”

Split when the body handles about 80% of invocations and the remainder is a real
branch or substantial example. Keep common instructions inline. Sharpen an
unreliable pointer before abandoning disclosure.

## Resources

- Add scripts for repeated deterministic work, generation, validation, or
  explicit failure handling. Use environment variables for secrets; execute
  every new or changed script.
- Add assets only for files copied or adapted into output. Assets are not
  instructions; load them only when inspection is necessary.
- Add `agents/openai.yaml` only for interface metadata, dependencies, or
  invocation policy. Preserve unrelated fields when editing it.

## Scope and language

- Preserve chosen product, assignment, permissions, and side-effect boundaries.
  One example or failure is not a universal rule.
- Match specificity to risk: fixed sequences for fragile operations; outcomes
  and decision criteria when several approaches are reasonable.
- Anchor behavior with familiar leading words such as *baseline* or *tracer
  bullets*; reuse terms before inventing them.
- Steer positively. Keep prohibitions only for hard guardrails and pair them
  with intended behavior.
- Use American English prose. Preserve source spelling in code, identifiers,
  commands, errors, and trigger words.

## Editing and validation

Preserve existing metadata, dependencies, policies, scripts, references, and
assets unless the requested change makes one obsolete. For audits, use
[references/diagnosing-skills.md](references/diagnosing-skills.md).

Run the repository validator when available. Confirm names match folders,
descriptions discriminate, reference links resolve, explicit-only metadata
agrees across harnesses, optional directories are non-empty, and no placeholders
or secrets remain.

## Review checklist

- [ ] Invocation deliberately chosen and encoded for every target harness
- [ ] Description contains triggers, not workflow
- [ ] Concise playbook has checkable completion criteria
- [ ] User intent, scope, permissions, and existing resources preserved
- [ ] Conditional material lives behind precise `references/` pointers
- [ ] Scripts execute successfully and assets have concrete consumers
- [ ] Constraints are positive, specific, and free of no-op advice
- [ ] Metadata, links, secrets, and placeholders validated
- [ ] Cold-start test verifies behavior without evaluator priming
