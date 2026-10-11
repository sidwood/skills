# Model tiers: three dials per launch

Each tracker issue carries one label from the single-select group
`Model tier`. The label is the issue's **review tier**, and it also says
which writers suit the issue. A launch sets three dials:

- `--tier`: the review tier, from the label. The shared policy
  (`~/.config/atomic/goal-select.jsonc`, in dotfiles) defines each tier's
  panel, reviewer models, quorum and round cap, and pins the model that
  re-verifies findings (`reverify_model` under `defaults`). Left unset,
  re-verification runs on the launching session's model, which can be the
  writer's own line.
- `--writer`: the writer model with effort, chosen from the label's list
  by its weights.
- The orchestrator, from the policy's `defaults` unless `--orchestrator`
  says otherwise. Sol at medium coordinates well and costs little.

| Label | Review panel | Writers and weights (2026-10-06, weights revised the same day) |
| --- | --- | --- |
| `tier-complex` | two seats on Astra, completion with evidence and risk; both approve (three seats until 2026-10-09: the third kept raising what the other two raised) | `openai/gpt-6.1-sol:xhigh` 70, `anthropic/claude-opus-5-5:high` 30 (Sol raised from high on 2026-10-09, after a milestone's trial showed cleaner units) |
| `tier-standard` | completion-and-evidence on Sol, risk on Astra; both approve | `xai/grok-4.7:xhigh` 60, `kimi-coding/k3:max` 40 |
| `tier-simple` | one reviewer on Sol; it alone approves | `composer-grok` 50, `zai/glm-5.3:max` 30, `kimi-coding/k3:max` 20 |

Every tier caps review at three rounds, with one extra round granted only
when round three leaves a P0 or P1 open. At the cap the run ends
`handover`, not `needs_human`: it lands like an approved run and QA
finishes it in one pass or escalates (see [landing-train.md](landing-train.md)).

The label description in the tracker is the authority (it starts
`Writers: <model> <weight>, ...`); this table records what it said when
the scheme was set up. Changing a tier's writers is one edit to the label;
changing a tier's reviewers is one edit to the shared policy. A running
run takes such an edit from its next turn: it resolves a turn's models,
the panel included, when the turn starts, so the review that ends a turn
already under way still runs the old panel. Say that when you report the
change.

## Choosing the writer for a launch

1. A writer or policy file the user names for that issue or batch wins.
2. A standing override for a time window comes next (see below).
3. Otherwise read the issue's tier label and choose one of the writers its
   description lists, as the next section describes.
4. No tier label: classify the issue with the rubric, add the label, and
   tell the user which tier you chose and why in the launch report.
5. A follow-up run after review findings keeps the issue's tier unless the
   findings show the writer was out of its depth; then move the issue up
   one tier and say so.

`composer-grok` is not an Atomic writer: it is the separate Cursor pair
in [composer-grok.md](composer-grok.md), opened with
`scripts/pair.sh open`. Its shape is already the simple tier
(one writer, one reviewer, three rounds). Use it only for simple-tier
issues whose criteria are checkable without interpretation.

**One pair at a time.** The weights stand while no pair is open. As soon
as one is, from `pair.sh open` until its issue is Done and its tab is
closed, every other simple-tier issue goes to the label's Atomic writers
in their own proportion: with `composer-grok` 50, `zai/glm-5.3:max` 30 and
`kimi-coding/k3:max` 20, that is GLM 60 and Kimi 40. `pair.sh open`
refuses a second pair.

### A second account as one more writer for small units

When the owner has a second provider account under its own Atomic profile, it can carry small units too: a project policy file for that profile (simple tier, a reviewer of another model line) and `launch.sh --agent-dir <that profile> --policy <file> --tier simple --writer <model>`. Preview it once with `--resolve-only`.

- It is a launch choice, not the last link of the fallback chain. A run reads one profile, and a profile holds only its own logins, so a writer that falls through its chain under the first profile cannot land on the second account by itself. Continue such a unit with `--checkout <clone>` under the other profile.
- Order the writers by what each has left: the allowance that expires soonest first.

### A fix pass on a unit another lane wrote

When QA sends findings back on a unit written and reviewed elsewhere (a cloud lane's writer and reviewer, say), the fix pass need not follow the small-unit chain: give it the strongest writer the project's compute allows and one reviewer of another model line at a lower effort. Casefile Crafter's rule (the owner, 2026-10-11): Sol 6.1 at xhigh writes, one Astra 6 reviewer at high checks, through a project policy file whose simple tier names that reviewer (`templates/policy-cloud-fix.jsonc`). Neither model has seen the work before, so the review is fresh, and the fix still lands on harness approval and the gate with no second QA review.

## The one rule no weighting overrides

A model line never reviews its own work: the writer and every reviewer on
the tier's panel must be different model lines (Sol writing for Astra
reviewers is fine; Sol writing for the simple tier's Sol reviewer is not,
and the launcher and the workflow both refuse it). When the user wants
one model used as much as possible, launch it as writer in some harnesses
and as reviewer in others. Do not write a new preset to get around this.

## When a writer's provider runs out

A provider's usage window can close in the middle of a run. Ask the user
once for a standing fallback sequence and keep it in the project's notes.
One user's sequence, as an example:

- `xai/grok-4.7:xhigh`, then `kimi-coding/k3:max`, then `zai/glm-5.3:max`,
  then `anthropic/claude-sonnet-5-5:max`.
- `anthropic/claude-opus-5-5:xhigh`, then `openai/gpt-6.1-sol:xhigh`.
- No fallback for the provider with plenty of usage.

How to apply it:

- Put the sequence in the shared policy as `writer_fallbacks`, keyed by
  the writer's model line (`provider/model`, no effort), each value the
  ordered list of models it moves to. The goal-select workflow walks it:
  when a writer's model fails, the turn continues in a stage named
  `orchestrator-<turn>-continued-<n>` on the next model that is not on
  the turn's review panel and does not re-verify it. With none left the
  run ends failed and resumable, and names what it refused and why.
- So a step that is legal on one tier is refused on another without any
  per-launch care: Opus falling back to Sol runs where every reviewer is
  Astra and stops where a reviewer is Sol.
- Do not put "continue with `<next model>`" in an objective any more, and
  do not steer a run to another writer by message: an orchestrator told
  to jump to a reviewer's line closes its own run for a person.
- Why the workflow does this and not the runtime: a delegated agent tries
  its model, then its own declared fallbacks, then the launching
  session's model (`docs/subagents/reference.md`), and the subagent tool
  takes no fallback list for a single call. Left alone, a failed writer
  lands on the orchestrator's model, silently, and its task is reported
  completed. Casefile Crafter, 2026-10-09: a Grok writer out of credits
  and a Kimi writer past its usage window both became Sol writers on a
  panel where Sol reviews.
- The workflow reads which model wrote from the agents' own transcripts
  after each orchestrator stage, and records it in the ledger
  (`delegations`, `writer_moves`) and the receipt. "Wrote" means an
  accepted `edit` or `write` call; a change made only through the shell
  is not seen.
- A writer that wrote on a line that judges the turn closes the run
  `needs_human` before any reviewer starts, and a resume checks again.
  Change the panel (the policy is read again) or start a new run; the
  closure stays for the same panel even if the writing is reverted.
- A writer whose outcome cannot be read (a torn transcript, a task still
  running when its stage returned) also closes the run for a person.
  Resuming it is the acknowledgment.
- One case the gate cannot prevent: a fallback whose provider has no
  login at all is started on the orchestrator's model. The audit catches
  it after the stage. Check the chain's providers are logged in before a
  launch whose writer has a chain.
- Pin `reverify_model` in the policy's `defaults` to a line that never
  writes. Unset, findings are re-verified on the launching session's
  model. A project policy with a `defaults` block of its own does not
  inherit the shared pin.
- Reading a transcript yourself: a delegated writer's is at
  `~/.atomic/agent/sessions/--<clone path with dashes>--/<session>/<task>/run-0/session.jsonl`,
  and every assistant turn carries its model. An agent launched with
  `context: "fork"` is different: its transcript is a file beside the
  stage's own, named in its first line by `parentSession`, and it opens
  with a copy of the parent's turns. Count only from its `session_info`
  entry (`subagent-<agent>-<id>`). The stage's `subagent` tool results
  say what was asked and recorded: `taskRecords[].model` and `.thinking`.
- Do not take the writer's model from a receipt written before this
  change: those named the model that was asked for.
- Test a fallback model once before relying on it:
  `atomic -ne -p "Say hello" --model <id>` from a scratch directory.
- Run both of the workflow's test files in the preflight for any runtime
  upgrade: two of them fail if the runtime stops passing the fallback
  gate through to delegated agents.

## Choosing among a tier's policies

A weight is the share of that tier's launches the preset should get over
time. It is a target to steer by, not a dice roll: you decide each launch
and keep the running mix near the weights.

Decide in this order:

1. **Fit.** Some issues call for one preset whatever the mix:
   - `opus-fable` is for the hardest complex issues only: several
     complex triggers at once (for example a lifecycle change with a
     migration and concurrency), a design left open by the issue, or a
     complex issue that has already bounced twice on `sol-astra`.
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
`opus-astra` for complex work until 17:00 today". Apply an override for
exactly the window given, then return to the label's policies without
being asked. Do not edit a label description for a temporary override; edit
it when the user changes the standing mix.

A writer whose usage window is short (a provider that gives about an hour
of writing in every five) is used one unit at a time: give it the first
unit of its tier to launch, give any unit of that tier running beside it
the tier's next writer, and never run two writers on it at once, or both
drain the window and fall back together. Size its unit to the window. Note
when its writer started, and launch its next unit once the last is done
and the window has reset; a launch into a spent window only falls back.
When the user wants an allowance used up before it expires, this is the
way to keep every window busy without overloading one.

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
