# Fleet config (`fleet.json`)

One machine-readable file per project owns every binding and all live ticket
state. Its default path is `<seed>/temp/fleet/fleet.json`, under a gitignored
`temp/` directory. The skill never hardcodes what this file owns. Verified
live values (current seed tip, agent status) always come from git and Herdr,
not from this file.

The CLI resolves the file in this order: `--config`, `FLEET_CONFIG`,
`$FLEET_STATE_DIR/fleet.json`, then
`$FLEET_SEED/temp/fleet/fleet.json`. The fallbacks are lookup only; they do not
create a fleet config. Mutating commands hold an exclusive lock at
`<fleet.json>.lock` while reading and writing it.

Capture tails go to `FLEET_CAPTURES_DIR` when set, otherwise to `captures/`
beside the resolved config. Each file is written atomically before parsing.

After creating or adopting a config, run `fleet recipes sync`, then
`fleet recipes check`. The sync command installs the exact machine-readable
[recipe catalog](../assets/recipe-catalog.json), repairs launch arguments and
fallback order, preserves every valid usage-pool state and recipe `enabled`
switch, and leaves additional project recipes untouched. Dispatch refuses to
start while the canonical catalog is missing or drifted.

## Schema

```jsonc
{
  "seed": "/abs/path/to/seed-repo",
  "seedDefaultBranch": "main",
  "session": "herdr-session-name",
  "user": "name pasted into prompts with deployment context",
  "deploymentContext": "Target environment, who uses it, what P0-P2 means here. Pasted into every prompt.",

  // `fleet recipes sync` installs these sections from the skill's canonical
  // assets/recipe-catalog.json. Do not hand-copy or trim the catalog. Disable
  // an unused recipe with `enabled: false`; keep its definition present.
  "recipeCatalogVersion": 1,
  "usagePools": { "...canonical pools...": { "state": "available | spent" } },
  "recipes": { "...canonical recipes...": { "enabled": true } },

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
      "dispatchCounters": { "impl": 1, "review": 2 },
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
          "name": "t094-1-<hash>-impl-1",
          "role": "impl",
          "dispatchNumber": 1,
          "requestedRecipe": "grok-xhigh",
          "recipe": "grok-xhigh-cursor",
          "dispatchState": "reserved | tab-created | started | prompting | active | captured | closed | resolved",
          "tabId": "herdr tab id",
          "paneId": "herdr pane id",
          "promptFile": "/abs/path/to/seed-repo/temp/fleet/prompts/t094-1-impl.txt",
          "reservedAt": "ISO-8601",
          "envPreparedAt": "ISO-8601 when envPreStep completed",
          "promptAttemptedAt": "ISO-8601",
          "dispatchedAt": "ISO-8601"
        }
      },
      "events": [{ "at": "ISO-8601", "eventId": "t094-1-<hash>-impl-1@7", "agent": "t094-1-<hash>-impl-1", "kind": "review-ready", "tip": "…", "capturePath": "/abs/path/to/seed-repo/temp/fleet/captures/…", "closedAt": "ISO-8601" }]
    }
  ]
}
```

## Recipe availability and fallback policy

The catalog file is authoritative for exact keys, CLI kinds, arguments, pools,
and fallback order. This table is only its human-readable route summary.

| Requested recipe | Ordered route before operator alert |
|---|---|
| `grok-xhigh` | `grok-xhigh-cursor`, `glm-53` |
| `grok-high` | `glm-53`, `grok-high-cursor` |
| `glm-53` | `grok-high`, `grok-high-cursor` |
| `grok-high-cursor` | `grok-high`, `glm-53` |
| `fable-max` | operator alert; no successor configured |
| `opus-max` / `sol-max` | the other recipe |
| `opus-xhigh` / `sol-xhigh` | the other recipe |
| `opus-medium` / `sol-medium` | the other recipe |
| `composer-2.5` | `glm-53`, `grok-high` |

- `enabled: false` removes one recipe from both primary and fallback
  selection without deleting how to launch it. Set it back to `true` to
  re-enable it.
- `usagePools.<name>.state: spent` removes every recipe charged to that
  quota window. Restore `available` only when that real window or credit pool
  is usable again.
- A coordinator marks a pool `spent` only when the captured output
  conclusively says the usage window or credits are exhausted. Reset offers,
  remaining-usage notices, authentication failures, startup failures,
  timeouts, and ambiguous errors do not prove exhaustion; retain the evidence
  and raise an operator alert.
- On conclusive exhaustion, preserve the transcript before teardown, close
  and reconcile the exact failed lane, mark the pool spent, then dispatch a
  fresh lane with the first enabled, available entry in the requested
  recipe's ordered `fallbacks` list. `fleet capture --event-id --close` does
  this automatically for recognized hard-cap output and records the failed
  and replacement recipes together.
- Fallback lists are deliberately flat and non-recursive. Each primary lists
  its complete allowed route, which prevents reciprocal Opus/Sol policies
  from looping.
- If no listed candidate is enabled and available, dispatch stops with an
  operator alert. `fable-max`, `sol-high`, `opus-high`, and directly requested
  `grok-xhigh-cursor` have no invented fallback, because none was specified.
- Availability edits affect future dispatches only. They never kill or
  silently replace an active lane. Each lane records both `requestedRecipe`
  and the recipe actually selected.
- `envPreStep` is trusted project configuration run in the new pane before
  agent startup. GLM 5.3 uses it to load the lane-specific environment; a
  failure stops dispatch rather than falling through as if quota were spent.

`dispatchCounters` is per stream and per role. Missing counters start at zero,
so existing configs migrate lazily. A real dispatch reserves the new number
and agent record before creating a tab, then records each external boundary:
`tab-created`, `started`, `prompting`, and `active`. `promptAttemptedAt` is
written before prompt submission. This lets recovery distinguish an unused
reservation from a prompt that may have been accepted. A dry run calculates
the next name without changing the config. The dispatch number identifies a
Herdr lane and is independent of the `review-N` pass number.

Capture adds `capturedAt`, `captureKind`, and, when supplied,
`captureEventId`. Teardown adds `closedAt`. Exceptional lost-output resolution
adds `resolvedAt` and `resolutionReason`. These timestamps and the current
`dispatchState` form the lane's recovery trail. `captured` still owns an open
tab; no next dispatch on the ticket is allowed until every recorded lane is
`closed` or `resolved`.

Keep rendered prompt files beside the other ignored runtime state, under
`<seed>/temp/fleet/prompts/`, unless the project explicitly chooses another
ignored path.

A parse failure adds `lastCaptureFailure` with its timestamp, event ID, error,
and saved capture path, but no acknowledgement event. The raised error names
that path. A later successful capture clears the failure record.

When that saved output contains a recognized, conclusive hard-cap signal and
capture was called with `--event-id --close`, the CLI records a
`resolved-invalid-output` event with `resolutionClass: "capacity"`, closes the
failed tab, marks its selected recipe's pool `spent`, and immediately invokes
dispatch for the same role and prompt. The replacement resolves from the
stream's original requested recipe, so later capacity failures continue along
the same flat route. The event records `replacementAgent` and
`replacementRecipe`; an interruption before that record is complete is a
`CAPACITY-STALL` at the next orchestrator self-evaluation.

When a monitor supplies an event ID, treat it as an opaque idempotency key and
persist it on the same `events[]` entry as the captured result. That atomic
write is durable processing proof; the monitor sweeps only after the exact
event carries `closedAt` or `teardownResolvedAt`, its exact correlated agent
record is `closed` or `resolved`, or it is a `resolved-lost-output` event. New
closes copy `closedAt` onto both the record and event so later role-slot reuse
cannot erase the proof. Retrying a captured event ID returns success without
rereading Herdr or adding another verdict; adding `--close` resumes and
finishes teardown, and dispatch remains blocked until it does.
Herdr's already-missing-tab result is idempotent success. A reused ID that
names a different agent, or any ID recorded more than once across streams, is
invalid. The transcript tail is saved under the captures directory before
parsing, so malformed output remains available even when no event can be
recorded. Retry that exact event with `--capture-file <saved-transcript>` when
the live agent and pane no longer retain the output; this explicit recovery
path requires `--event-id` and records the original evidence path.

Only after both agent and pane reads fail, `fleet resolve-event` records a
`resolved-lost-output` event with the exact event ID, agent, timestamp, and
operator-supplied reason. If a saved capture exists but is unusable evidence
(for example, an authentication failure with no verdict), pass its exact path
as `--capture-file`; this records `resolved-invalid-output` with the parse
error, evidence path, and reason. Omitting the path or supplying a different
file remains an error. Both forms let the monitor sweep the event without
pretending a capture or verdict exists, move the stream to `hold`, preserve an
existing recoverable `resumePhase`, and record `holdReason`; re-dispatching the
lost or invalid role restores the right phase.

If the exact capture event already exists but its tab identity or close cannot
be recovered, the same command instead records `teardownResolvedAt` and
`teardownResolutionReason` on that event. It marks only an exactly correlated
current record `resolved` and leaves the already-captured workflow phase
unchanged. This is durable closure proof without claiming the tab was closed.
Repeating either resolution is idempotent; assigning an ID to another agent or
duplicating an ID across streams fails.

The operator must establish that both reads failed before running
`resolve-event`; the command records the supplied resolution but does not
probe Herdr itself.

## Migration from an instance-keyed recipes table

Older configs key recipes by instance name (`grok-xhigh-implementer`,
`grok-xhigh-implementer-2`, `opus-max-reviewer-2`, …). Collapse duplicates to
one tier-keyed entry each and switch dispatch to derived instance names.
Migrate only when no agent is live under the old names.
