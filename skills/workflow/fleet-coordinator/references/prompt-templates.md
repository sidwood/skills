# Prompt templates

Fill every {{PLACEHOLDER}} from the fleet config, the ticket card, and git
before dispatch. Refuse to send a prompt that still contains `<` or `{{`.
All three templates open with the config's `deploymentContext` block.

## Implementer handover

```text
{{TICKET}} — {{TITLE}}

Repository seed: {{SEED_PATH}} @ {{SEED_TIP}} (do not touch the seed)
Working copy: {{CLONE_PATH}}
Branch: {{BRANCH}} (created from seed tip)

DEPLOYMENT CONTEXT ({{USER}}, non-negotiable): {{DEPLOYMENT_CONTEXT}}

PROBLEM
{{PROBLEM_FROM_CARD}}

SCOPE IN
{{ACCEPTANCE_CRITERIA_AS_CHECKLIST}}

SCOPE OUT (do not touch — deferred)
{{SCOPE_OUT_TAGS_WITH_TARGET_TICKETS}}

RULINGS (paste verbatim, all that apply to this ticket)
{{RULINGS}}

PROCESS
- Test-first per behavior: red before green; never weaken tests to pass.
- One concern per commit; run the repository lint before every commit and
  stage any rewrites into the same commit.
- Follow the repository's agent instructions and house style.
- Gate for this slice: {{GATE_COMMANDS_FOR_DIFF_REACH}}. State explicitly in
  REVIEW-READY which suites were out of the diff's reach and why.

Output REVIEW-READY with: tip SHA, gate table, deferral notes. Do not land;
the reviewer approves first.
```

## Scoped review (first pass and re-review)

```text
You are an independent, read-only code reviewer. Find concrete defects and
ship risks; do not edit application source, commit, merge, or open pull
requests.

HANDOFF
Repository: {{SEED_PATH}}
Working copy: {{CLONE_PATH}} on branch {{BRANCH}}
Review range: {{RANGE}}
  First pass: {{SEED_TIP}}..{{BRANCH_TIP}} — the only full-range pass.
  Re-review: {{PRE_FIX_TIP}}..{{BRANCH_TIP}} — the bounce fix commits ONLY;
  the prior range stands reviewed. A new finding on unchanged code joins the
  deferral list and must not affect the APPROVE line.
Task and intent: {{TICKET}} — {{TITLE}}. IN SCOPE: {{IN_SCOPE_SUMMARY}}.

DEPLOYMENT CONTEXT ({{USER}}, non-negotiable): {{DEPLOYMENT_CONTEXT}}

SCOPE RULE ({{USER}}, non-negotiable):
Only findings tagged (A) in-scope may cause APPROVE: no.
Tag every finding:
  (A) {{TICKET}} land scope — blocks APPROVE if P0–P2
  {{DEFERRED_TAG}} → {{TARGET_TICKET}} — informational ONLY; never APPROVE: no
  (D) P3 style/docs — does not block APPROVE: yes

Explicit OUT OF SCOPE (do not hunt, do not bounce):
{{DO_NOT_HUNT_LIST}}

RULINGS (standing, from the user)
{{RULINGS}}

Required verification: {{GATE_COMMANDS}}. The implementer skipped
{{SKIPPED_SUITES_WITH_CLAIMS}} — verify each claim against the diff; run the
suite if the claim does not hold and treat an unverified claim as a finding.

RESPONSE
Findings first (P0–P3, path:line, scope tag). Deferred-tag items under
"Deferred" — they must not affect the APPROVE line.

End with exactly one of:
APPROVE: yes
APPROVE: no

APPROVE: no ONLY when a P0–P2 finding is tagged (A). Deferred-tag findings
alone → APPROVE: yes (list under Deferred).
```

## Bounce (fix-only)

```text
{{TICKET}} bounce — review {{N}} @ {{REVIEWED_TIP}}: APPROVE: no.
Bounce {{COUNT}} of at most {{CAP}}. The next review verifies this fix and
its regressions only.

FIX ONLY ({{TICKET}} land scope):
{{FINDINGS_VERBATIM_WITH_SEVERITY_TAG_AND_LOCATION}}

DO NOT FIX (standing deferrals — unchanged):
{{DEFERRALS_AND_RULINGS}}

{{SEED_MOVED_NOTE_IF_ANY}}

After the fix: rerun the gate per the handover; one concern per commit.
Output REVIEW-READY with: new tip SHA, the SHA of the rebased pre-fix tip,
gate table, unchanged deferral list.
```
