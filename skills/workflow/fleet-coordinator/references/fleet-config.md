# Fleet config (`fleet.json`)

One machine-readable file per project owns every binding and all live ticket
state. The skill never hardcodes what this file owns. Verified live values
(current seed tip, agent status) always come from git and Herdr, not from
this file.

## Schema

```jsonc
{
  "seed": "/abs/path/to/seed-repo",
  "session": "herdr-session-name",
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
    "bootstrap": "commands that stand up test infrastructure (ephemeral database, browser install)",
    "suites": "the commands CI runs, and which apply per diff reach"
  },

  "landPolicy": "verdict table parameters",
  "bounceCap": 2,

  "streams": [
    {
      "ticket": "T094.1",
      "branch": "…",
      "checkout": "/abs/path/to/clone",
      "implRecipe": "grok-xhigh",
      "reviewRecipe": "opus-max",
      "phase": "implementing | review-N | bounce-N | landed | hold",
      "bounceCount": 0,
      "baseTip": "seed tip the branch is based on",
      "tip": "current branch tip",
      "reviewRange": "…",
      "verdicts": [{ "pass": 1, "tip": "…", "approve": false, "findings": [{ "sev": "P2", "tag": "(A)", "loc": "file:line", "title": "…" }] }],
      "rulings": [{ "id": "slug", "text": "verbatim user ruling, pasted into every later prompt" }]
    }
  ]
}
```

## Migration from an instance-keyed recipes table

Older configs key recipes by instance name (`grok-xhigh-implementer`,
`grok-xhigh-implementer-2`, `opus-max-reviewer-2`, …). Collapse duplicates to
one tier-keyed entry each and switch dispatch to derived instance names.
Migrate only when no agent is live under the old names.
