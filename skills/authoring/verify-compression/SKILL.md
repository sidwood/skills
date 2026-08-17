---
name: verify-compression
description: Use after compressing any artefact (skill, prompt, ruleset, doc) to confirm the compressed version behaves identically at lower token cost; when the user invokes /verify-compression or says "check predictability", "did compression change behavior", "verify the compressed version".
disable-model-invocation: true
---

# Verify Compression

Independent A/B judgement: does the compressed artefact drive the same behaviour as the original, at lower token cost?

## Workflow

1. Take the original and compressed versions as the pair under test, plus the inventory of behaviour-bearing elements (reuse the compressor's inventory if one was produced).
2. Judge independently — run the comparison as a fresh subagent (or separate model) so the compressor does not grade its own work.
3. Activation parity: confirm any triggering, routing, or conditional logic fires on the same inputs; flag every changed or dropped condition.
4. Behaviour parity: walk each instruction, step, rule, and completion criterion in the original; mark each retained or lost in the compressed version.
5. Fidelity: confirm exact-match elements — code blocks, error strings, quoted commands, and anchor terms — are byte-identical.
6. Token delta: report before/after token count (or a char/word proxy) and % reduction.
7. Verdict: PASS when behaviour is identical and tokens dropped; else FAIL with the exact elements to restore.

Done when every original behaviour-bearing element is marked retained or lost and a PASS/FAIL verdict plus token delta is returned.

When verifying a skill, behaviour-bearing elements are its frontmatter triggers, numbered steps, completion criteria, code blocks, error strings, and leading words.

## Rules

- Predictability is the bar: same activation, same process, same outputs, fewer tokens.
- One lost or altered behaviour-bearing element is a FAIL, however large the token saving.
- Judge the pair only; do not re-compress here. Restoring losses is `../compress-a-skill`'s job.
- Report the delta as measured evidence, not an estimate presented as fact.
