# Model tiers and policy selection

Each tracker issue carries one label from the single-select group
`Model tier`. The label says how strong a writer the issue needs; the
label's description names the goal-select policy preset to launch with.
Changing a tier's policy is one edit to that label's description, with no
change to any issue.

| Label | Meaning | Policies and weights at first use (2026-10-04) |
| --- | --- | --- |
| `tier-frontier` | Needs the strongest writer | `sol-astra` 95, `opus-fable` 5 |
| `tier-standard` | A cheaper writer with strong reviewers is enough | `grok-astra` 60, `kimi-opus` 40 |
| `tier-simple` | A cheaper writer and standard reviewers | `glm-astra` 50, `kimi-astra` 40, `composer-grok` 10 |

The label description in the tracker is the authority (it starts
`Policies: <preset> <weight>, ...`); this table records what it said when
the scheme was set up.

## Choosing the policy for a launch

1. A policy the user names for that issue or batch wins.
2. A standing override for a time window comes next (see below).
3. Otherwise read the issue's tier label and choose one of the presets its
   description lists, as the next section describes.
4. No tier label: classify the issue with the rubric, add the label, and
   tell the user which tier you chose and why in the launch report.
5. A follow-up run after review findings keeps the issue's tier unless the
   findings show the writer was out of its depth; then move the issue up
   one tier and say so.

`composer-grok` is not an Atomic preset: it is the separate Cursor-based
harness in [composer-grok.md](composer-grok.md), launched with
`scripts/launch-composer-grok.sh`. Use it only for simple-tier issues whose
criteria are checkable without interpretation.

## The one rule no weighting overrides

A model line never reviews its own work: the writer and every reviewer in
a preset must be different model lines (`opus-astra` and `kimi-opus` are
fine; a preset with one model on both sides is not). When the user wants
one model used as much as possible, launch it as writer in some harnesses
and as reviewer in others. Do not write a new preset to get around this.

## Choosing among a tier's policies

A weight is the share of that tier's launches the preset should get over
time. It is a target to steer by, not a dice roll: you decide each launch
and keep the running mix near the weights.

Decide in this order:

1. **Fit.** Some issues call for one preset whatever the mix:
   - `opus-fable` is for the hardest frontier issues only: several
     frontier triggers at once (for example a lifecycle change with a
     migration and concurrency), a design left open by the issue, or a
     frontier issue that has already bounced twice on `sol-astra`.
   - In the standard tier, prefer the preset with the stronger reviewers
     when the risk is in judgment (accessibility behavior, user-facing
     copy, anything security-adjacent), and the other when the risk is in
     volume (wide but mechanical changes, journey tests).
2. **Evidence.** Keep a tally per preset of reviewer rounds, QA findings
   and elapsed time. Shift launches toward the preset that is landing
   clean, and tell the user when the evidence disagrees with the weights.
3. **Spread.** When launching several issues at once, spread them across
   providers so one provider's rate limit does not stall the batch.
4. **Mix.** With nothing else to separate them, pick the preset that is
   furthest below its weight in the tally.

State the preset and the reason for each issue in the launch report, for
example "TUS-88: `grok-astra` (wide, mechanical; Grok is under its share)".

Compute budgets move, so expect standing overrides: the user may say "use
`opus-astra` for frontier work until 17:00 today". Apply an override for
exactly the window given, then return to the label's policies without
being asked. Do not edit a label description for a temporary override; edit
it when the user changes the standing mix.

## Rubric

Judge the hardest part of the issue, not its size in points.

**Frontier** when any of these holds:

- concurrency, locking, ordering or race conditions
- a lifecycle or state-machine change, or a schema migration with design
  choices
- idempotency, charging, entitlement or anything counted at most once
- security: authentication, authorization, CSRF, sanitizing untrusted input
- a refactor across a whole module, or the first implementation of a
  pattern later issues will copy
- a new interaction model (keyboard navigation of a graph, focus rules,
  live regions) or computed layout
- the issue states an outcome and leaves the design open

**Simple** when all of these hold:

- one layer (a page, a component, a mapper, an endpoint over existing data)
- exact values, copy or an existing pattern to follow
- no migration, no concurrency, no charging, no security surface
- failure would be visible in a screenshot or a unit test

**Standard** for the rest: well specified but wide or full-stack, pages that
wire several existing pieces together, and journey tests.

When torn between two tiers, pick the higher one for work other issues
depend on and the lower one for leaf work.

## Keeping tiers true

- Re-read the tier when a ruling changes an issue's scope.
- A reviewer's findings are evidence: repeated findings of the same kind on
  one tier are a reason to raise that kind of issue, and to tell the user.
- Manual work that no harness can do (for example a screen-reader pass by a
  person) gets no tier label.
