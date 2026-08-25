# Fleet config (`fleet.json`)

One machine-readable file per project owns every binding and all live ticket
state. The skill never hardcodes what this file owns. Verified live values
(current seed tip, agent status) always come from git and Herdr, not from
this file.

## Schema

```jsonc
{
  "seed": "/abs/path/to/seed-repo",
  "seedDefaultBranch": "main",
  "session": "herdr-session-name",
  "user": "name pasted into prompts with deployment context",
  "deploymentContext": "Target environment, who uses it, what P0-P2 means here. Pasted into every prompt.",

  // Recipes are keyed by MODEL TIER, one entry per backend+effort — never
  // per instance. A recipe can launch any number of concurrent agents;
  // uniqueness lives in the agent NAME chosen at dispatch, derived from the
  // ticket and role: T094.1 implementer -> t094-1-impl, its reviewer ->
  // t094-1-review (Herdr names: [a-z][a-z0-9_-]{0,31}, no dots). Ticket-
  // scoped names also make transcripts self-describing.
  "recipes": {
    "composer-2.5": { "kind": "cursor", "args": ["--model", "composer-2.5", "-f"] },
    "grok-xhigh":   { "kind": "grok",   "args": ["--model", "grok-4.6", "--reasoning-effort", "xhigh", "--always-approve"] },
    "opus-max":     { "kind": "claude", "args": ["--dangerously-skip-permissions", "--model", "opus", "--effort", "max"] },
    "sol-max":      { "kind": "codex",  "args": ["--dangerously-bypass-approvals-and-sandbox", "-m", "gpt-5.6-sol", "-c", "model_reasoning_effort=max"] }
  },

  "implementerLadder": ["composer-2.5", "grok-high", "grok-xhigh"],
  "pairings": "Which reviewer tiers may review which implementer tiers (no family reviews its own work).",

  "gate": {
    "bootstrap": ["commands that stand up test infrastructure"],
    "suites": [
      { "prefix": "apps/api/", "commands": ["npm test --workspace=api"] },
      { "prefix": "", "commands": ["npm test"] }
    ]
  },

  "postLandChecks": ["commands run on the seed after a successful fast-forward merge"],
  "landPolicy": "verdict table parameters",
  "bounceCap": 2,
  "deferredTag": "(B)",

  "streams": [
    {
      "ticket": "T094.1",
      "title": "card title for prompts",
      "branch": "fleet/t094-1",
      "checkout": "/abs/path/to/clone",
      "implRecipe": "grok-xhigh",
      "reviewRecipe": "opus-max",
      "phase": "implementing | review-N | bounce-N | verdict-pending | approved | landed | hold",
      "bounceCount": 0,
      "baseTip": "seed tip the branch is based on",
      "tip": "current branch tip",
      "preFixTip": "branch tip before bounce fix commits (re-review range base)",
      "reviewRange": "git range string for the active review",
      "problem": "problem statement from the ticket card",
      "acceptanceCriteria": ["done criterion as checklist items"],
      "scopeOut": [{ "tag": "(B)", "target": "T100", "description": "deferred area" }],
      "inScopeSummary": "short scope line for reviewer prompts",
      "doNotHunt": ["explicit out-of-scope hunt list for reviewers"],
      "skippedSuites": [{ "suite": "e2e", "claim": "implementer claim for skipped gate suite" }],
      "deferredTag": "optional per-stream override of top-level deferredTag",
      "rulings": [{ "id": "slug", "text": "verbatim user ruling, pasted into every later prompt" }],
      "deferrals": [{ "sev": "P3", "tag": "(B)", "loc": "file:line", "title": "deferred finding" }],
      "verdicts": [{ "pass": 1, "tip": "…", "approve": false, "findings": [{ "sev": "P2", "tag": "(A)", "loc": "file:line", "title": "…" }] }],
      "approvedTip": "clone tip approved for landing",
      "landedAt": "ISO-8601 timestamp when landed",
      "landRange": "baseTip..landTip recorded at land",
      "agents": {
        "impl": {
          "name": "t094-1-impl",
          "role": "impl",
          "tabId": "herdr tab id",
          "paneId": "herdr pane id",
          "promptFile": "/path/to/prompt.txt",
          "dispatchedAt": "ISO-8601"
        }
      },
      "events": [{ "at": "ISO-8601", "agent": "t094-1-impl", "kind": "review-ready", "tip": "…" }]
    }
  ]
}
```

## Migration from an instance-keyed recipes table

Older configs key recipes by instance name (`grok-xhigh-implementer`,
`grok-xhigh-implementer-2`, `opus-max-reviewer-2`, …). Collapse duplicates to
one tier-keyed entry each and switch dispatch to derived instance names.
Migrate only when no agent is live under the old names.
