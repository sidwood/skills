---
name: compress-a-skill
description: Use when authoring or editing a skill (or other context-window artefact) and you want to cut its token cost; when the user invokes /compress-a-skill or says "compress this skill", "tighten this skill", "reduce skill tokens".
disable-model-invocation: true
---

One-shot pass: shrink target skill tokens, preserve behaviour.

## Workflow

1. Read target artefact in full. Inventory behaviour-bearing elements: frontmatter triggers, numbered-step order, completion criteria, code blocks, error strings, leading words, headings with distinct behaviour.
2. Before prose compression, cut restatement — text another element already fully encodes — keeping only residue that adds execution behaviour. Two kinds: (a) body prose already in frontmatter (duplicate H1/name, `disable-model-invocation: true` restated as user-invoked/no auto-load, description repeated as summary); (b) cross-section duplication — a `## Rules` entry restating what numbered `## Workflow` steps already encode (step ordering, composition sequence, re-enumeration of steps). Collapse each to one canonical location; remove a rule only when a step fully encodes it, keeping any residual negative constraint, invariant, guardrail, failure path, or exception the steps omit.
3. Apply `../../workflow/compress` (§ Rules) to prose only.
4. Preserve every inventoried behaviour-bearing element unchanged. Compression edits wording, never process.
5. Produce full replacement plus before/after token count and % reduction.
6. Hand original + compressed pair to `../verify-compression`; claim predictability retained only after PASS.

Done when every inventoried element is present and unchanged in output and the token delta is reported.

## Rules

- `../../workflow/compress` is the transform source of truth; do not restate it.
- Keep original wording when a cut changes what the agent does.
- Keep an H1 when it names a leading word, required anchor, or differs meaningfully from frontmatter.
