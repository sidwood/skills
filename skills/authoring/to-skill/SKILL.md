---
name: to-skill
description: Use when creating, writing, editing, or auditing an agent skill, authoring a SKILL.md, or packaging a capability into a skill folder.
---

# Writing Skills

A skill makes an agent follow the **same process**, not produce the same output.
**Predictability** is the goal; every instruction should improve it.

## Process

1. **Gather requirements** — establish the task, branches, invocation mode,
   permissions, reference material, and whether deterministic scripts are useful.
2. **Watch the baseline** — observe how an agent handles the task without the
   skill. Teach only what it gets wrong; everything else is no-op context.
3. **Draft** — write the smallest playbook that preserves the user's scope and
   choices. Add optional resources only when they materially improve execution.
4. **Validate** — check structure and metadata, execute changed scripts, and
   verify observable behavior rather than headings or generated wording.
5. **Forward-test** — when complexity or risk warrants it, use a fresh evaluator
   in an isolated workspace without revealing the expected answer or suspected
   defect. Finish when realistic requests produce the intended process.

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

Create no optional directory until it has a concrete file and purpose. A skill
does not need its own README, changelog, or installation guide unless packaging
requires one.

## Choose invocation first

Every skill pays one of two loads. Decide before writing and preserve an
existing skill's policy unless the user asks to change it.

- **Model-invoked**: natural-language requests matching `description` may load
  the skill. Omit `disable-model-invocation`; when `agents/openai.yaml` exists,
  set Codex's `allow_implicit_invocation: true`.
- **User-invoked**: the human must explicitly select or name the skill. Set
  `disable-model-invocation: true` in `SKILL.md` frontmatter and set Codex's
  `agents/openai.yaml` policy to `allow_implicit_invocation: false`.

Model-invoked only when the agent must reach the skill by itself. Otherwise use
explicit invocation and accept the cognitive cost of remembering its name.
When explicit skills become hard to remember, add one router skill.

## Write the description

For model-invoked skills, `description` is the routing layer.

- State only when to trigger: the verbs, nouns, symptoms, and contexts the user
  supplies. Put workflow in the body so the agent reads the real instructions.
- Lead with the user's words, write in the third person, and stay under 1,024
  characters. Add exclusions only when they prevent likely misrouting.

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

Reference files are not auto-loaded. Point to one only when its branch applies:

- **Always loaded:** “Step 1: read `references/spec.md`.”
- **Conditional:** “For database migrations, read `references/schema.md`.”

Split content when the body handles about 80% of invocations without it and the
remainder is a genuine branch or substantial example. Keep common instructions
inline. Sharpen an unreliable pointer before abandoning progressive disclosure.

## Resources

- Add scripts for repeated deterministic operations, generated code, validation,
  or failures needing explicit handling. Use environment variables for secrets
  and execute every new or changed script.
- Add assets only when files are copied or adapted into the output. Assets are
  not instructions and should not be loaded unless inspection is necessary.
- Add `agents/openai.yaml` only for actual interface metadata, dependencies, or
  invocation policy. Preserve unrelated fields when editing it.

## Scope and language

- Preserve the user's chosen product, assignment, permissions, and external
  side-effect boundaries. One example or past failure is not a universal rule.
- Match specificity to risk: fixed sequences for fragile operations; outcomes
  and decision criteria when several approaches are reasonable.
- Anchor behavior with familiar leading words such as *baseline* or *tracer
  bullets*. Reuse an existing term before inventing one.
- Steer positively. Retain prohibitions only for hard guardrails and pair them
  with the intended behavior.
- Write prose in American English. Preserve source spelling in code, identifiers,
  commands, error strings, and user-facing trigger words.

## Editing and validation

When editing, preserve existing metadata, dependencies, policies, scripts,
references, and assets unless the requested change makes one obsolete. For an
audit, use the failure-mode catalog in
[references/diagnosing-skills.md](references/diagnosing-skills.md).

Run the repository's skill validator when available. Confirm that names match
folders, descriptions discriminate, reference links resolve, explicit-only
metadata agrees across harnesses, optional directories are non-empty, and no
scaffold placeholders or secrets remain.

## Review checklist

- [ ] Invocation chosen deliberately and encoded for every target harness
- [ ] Description contains triggers, not a workflow summary
- [ ] Body is a concise playbook with checkable completion criteria
- [ ] User intent, scope, permissions, and existing resources are preserved
- [ ] Conditional material lives behind precise `references/` pointers
- [ ] Scripts execute successfully and assets have a concrete consumer
- [ ] Constraints are positive, specific, and free of no-op advice
- [ ] Metadata, links, secrets, and stale placeholders are validated
- [ ] Cold-start testing verifies observable behavior without evaluator priming
