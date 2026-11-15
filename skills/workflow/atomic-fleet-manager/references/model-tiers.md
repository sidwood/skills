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
- `--writer`: the writer model with effort, from the tier's presets below.
- The orchestrator, from the policy's `defaults` unless `--orchestrator`
  says otherwise: Sonnet 5.5 at medium since 2026-11-10, when Sid's OpenAI
  subscription lapsed and Sol went with it.

## The presets (Sid, 2026-11-10)

Each row is a writer, its one reviewer and the QA seat for that work. The
tier label decides the tier; the writer comes from this table, not from a
`Writers:` list in a label's description. No OpenAI model appears anywhere.

| Tier | Harness | Writer | Reviewer (one) | QA |
| --- | --- | --- | --- | --- |
| simple | `agent` | Composer 2.5 | Grok 4.7 xhigh | none, see below |
| simple | `atomic` | Sonnet 5.5 xhigh | Opus 5.5 high | none, see below |
| simple | `atomic-work` | Sonnet 5.5 xhigh | Opus 5.5 high | none, see below |
| standard | `agent` | Grok 4.7 xhigh | Opus 5.5 high | Fable 5.2 medium |
| standard | `atomic` | GLM 5.3 max | Opus 5.5 high | Fable 5.2 medium |
| standard | `atomic` | Grok 4.7 xhigh | Opus 5.5 high | Fable 5.2 medium |
| standard | `atomic` | Opus 5.5 xhigh | Sonnet 5.5 max | Fable 5.2 medium |
| standard | `atomic-work` | Opus 5.5 xhigh | Sonnet 5.5 max | Fable 5.2 medium |
| complex | `agent` | Opus 5.5 xhigh | Grok 4.7 xhigh | Fable 5.2 medium |
| complex | `atomic` | Opus 5.5 xhigh | Sonnet 5.5 max | Fable 5.2 medium |
| complex | `atomic` | Fable 5.2 xhigh | Opus 5.5 high | Sonnet 5.5 max |
| complex | `atomic-work` | Opus 5.5 xhigh | Sonnet 5.5 max | Fable 5.2 medium |

- **Harnesses.** `atomic` is an Atomic harness on the default profile;
  `atomic-work` is one on the second account (`--agent-dir
  ~/.atomic-work/agent`). `agent` is the Cursor pair
  ([composer-grok.md](composer-grok.md)), only for a fleet manager that
  runs its units on the Cursor `agent` CLI; `scripts/pair.sh open
  --writer <model> --reviewer <model>` takes that row's Cursor model names
  (`composer-2.5`, `grok-4.7-xhigh`, `claude-opus-5-5-high` to review,
  `claude-opus-5-5-xhigh` to write).
- **Effort for review and QA (Sid, 2026-11-12, on Anthropic's
  recommendation).** An Opus 5.5 reviewer runs at high, not xhigh. A QA
  seat on Opus 5.5 runs at high and one on Fable 5.2 at medium. Writers
  keep their effort. A reviewer or QA seat already at work finishes it,
  then restarts at the new level as soon as it is idle. CCFM alone edits
  these settings in the shared skill and the shared policy.
- **Policy files.** A tier holds one reviewer, so each reviewer has its
  own file: [templates/policy-presets.jsonc](../templates/policy-presets.jsonc)
  for every row Opus reviews (it matches the shared policy in dotfiles),
  and [templates/policy-presets-opus-writer.jsonc](../templates/policy-presets-opus-writer.jsonc)
  for every row Opus writes. Copy both into the project and pass the one
  that matches the row.
- **UI/UX work is complex** whatever its size.
- **QA.** A simple unit is not handed to the QA seat unless its train also
  carries standard or complex work; then QA takes the whole train. Standard
  and complex units always go to QA. A unit Fable wrote goes to a Sonnet
  5.5 max QA seat, since Fable 5.2 does not judge its own line
  ([qa-agent.md](qa-agent.md)).
- **Fable 5.2 as an Atomic writer** needs Atomic 0.9.76 or newer: earlier
  releases present themselves as a Claude Code too old for it, and the
  request is refused. goal-select was ported to 0.9.76 on 2026-11-10 and
  the dotfiles pin it there. Runs paused under 0.9.32 cannot be resumed;
  launch them again.
- Several rows for one tier and harness are alternatives: choose among them
  as [Choosing among a tier's presets](#choosing-among-a-tiers-presets)
  says.

Every tier caps review at three rounds, with one extra round granted only
when round three leaves a P0 or P1 open. At the cap the run ends
`handover`, not `needs_human`: it lands like an approved run and QA
finishes it in one pass or escalates (see [landing-train.md](landing-train.md)).

Changing a tier's writers or reviewers is an edit to the presets above
and to the policy files that carry them. A running run takes a policy
edit from its next turn: it resolves a turn's models,
the panel included, when the turn starts, so the review that ends a turn
already under way still runs the old panel. Say that when you report the
change.

## Choosing the writer for a launch

1. A writer or policy file the user names for that issue or batch wins.
2. A standing override for a time window comes next (see below).
3. Otherwise read the issue's tier label and choose one of that tier's
   presets for the harness, as the sections below describe.
4. No tier label: classify the issue with the rubric, add the label, and
   tell the user which tier you chose and why in the launch report.
5. A follow-up run after review findings keeps the issue's tier unless the
   findings show the writer was out of its depth; then move the issue up
   one tier and say so.

The `agent` rows are not Atomic writers: they are the separate Cursor pair
in [composer-grok.md](composer-grok.md), opened with `scripts/pair.sh
open` and the row's `--writer` and `--reviewer`. Its shape matches the
tiers (one writer, one reviewer, three rounds). When the writer or the
reviewer is not a Cursor `agent` model, do not use `pair.sh`. Open one
tab named for the issue and run one agent in each half
([launching.md](launching.md)).

**One pair at a time.** From `pair.sh open` until its issue is Done and
its terminals are closed, every other issue goes to the tier's Atomic rows.
`pair.sh open` refuses a second pair.

### A second account as one more writer for small units

When the owner has a second provider account under its own Atomic profile, it can carry small units too: a project policy file for that profile (simple tier, a reviewer of another model line) and `launch.sh --agent-dir <that profile> --policy <file> --tier simple --writer <model>`. Preview it once with `--resolve-only`.

- It is a launch choice, not the last link of the fallback chain. A run reads one profile, and a profile holds only its own logins, so a writer that falls through its chain under the first profile cannot land on the second account by itself. Continue such a unit with `--checkout <clone>` under the other profile.
- Order the writers by what each has left: the allowance that expires soonest first.

### A fix pass on a unit another lane wrote

When QA sends findings back on a unit written and reviewed elsewhere (a cloud lane's writer and reviewer, say), the fix pass need not follow the small-unit chain: give it the strongest writer the project's compute allows and one reviewer of another model line at a lower effort. Neither model should have seen the work before, so the review is fresh, and the fix still lands on harness approval and the gate with no second QA review. Casefile Crafter's rule of 2026-10-11 (Sol writes, Astra reviews, `templates/policy-cloud-fix.jsonc`) went with the OpenAI subscription: ask the owner for the pair before the next fix pass.

## The one rule no weighting overrides

A model line never reviews its own work: the writer and every reviewer on
the tier's panel must be different model lines (Opus writing for a Sonnet
reviewer is fine; Opus writing for an Opus reviewer is not, and the
launcher and the workflow both refuse it). When the user wants
one model used as much as possible, launch it as writer in some harnesses
and as reviewer in others. Do not write a new preset to get around this.

## When a writer's provider runs out

A provider's usage window can close in the middle of a run. Ask the user
once for a standing fallback sequence and keep it in the project's notes.
Sid's sequence (2026-11-06, carried into the 2026-11-10 presets):

- `zai/glm-5.3:max`, then `xai/grok-4.7:xhigh`, then
  `anthropic/claude-sonnet-5-5:xhigh`.
- `xai/grok-4.7:xhigh`, then `anthropic/claude-sonnet-5-5:xhigh`.
- No fallback named for an Anthropic writer.

How to apply it:

- Put the sequence in the shared policy as `writer_fallbacks`, keyed by
  the writer's model line (`provider/model`, no effort), each value the
  ordered list of models it moves to. The goal-select workflow walks it:
  when a writer's model fails, the turn continues in a stage named
  `orchestrator-<turn>-continued-<n>` on the next model that is not on
  the turn's review panel and does not re-verify it. With none left the
  run ends failed and resumable, and names what it refused and why.
- So a step that is legal on one tier is refused on another without any
  per-launch care: Grok falling back to Sonnet runs where Opus reviews and
  stops where Sonnet reviews.
- Do not put "continue with `<next model>`" in an objective any more, and
  do not steer a run to another writer by message: an orchestrator told
  to jump to a reviewer's line closes its own run for a person.
- Why the workflow does this and not the runtime: a delegated agent tries
  its model, then its own declared fallbacks, then the launching
  session's model (`docs/subagents/reference.md`), and the subagent tool
  takes no fallback list for a single call. Left alone, a failed writer
  lands on the orchestrator's model, silently, and its task is reported
  completed. Casefile Crafter, 2026-10-09: a Grok writer out of credits
  and another writer past its usage window both became Sol writers on a
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
- Reading a transcript yourself: since Atomic 0.9.76 every session is a
  flat `<time>_<id>.jsonl` file in `~/.atomic/agent/sessions/` (JSONL
  only because the dotfiles settings select it; Atomic's default is
  SQLite, which goal-select cannot audit). A delegated writer's
  transcript is named by `sessionFile` in its delivery record,
  `subagent-artifacts/<launch>_<agent>_<n>_meta.json`, and every
  assistant turn carries its model. An agent launched with
  `context: "fork"` names its parent in its header's `parentSessionId`
  and opens with a copy of the parent's turns. Count only from its `session_info`
  entry (`subagent-<agent>-<id>`). The stage's `subagent` tool results
  say what was asked and recorded: `taskRecords[].model` and `.thinking`.
- Do not take the writer's model from a receipt written before this
  change: those named the model that was asked for.
- Pause a provider whose window is known to be spent for days rather
  than leave it in the chains: every writer that falls to it fails at
  once and spends a step of its chain finding that out. Take it out of
  every `writer_fallbacks` list and every writer choice (shared policy,
  project policies, launch scripts, this skill's templates), keep the
  old chains beside them as comments, and record the date it comes back
  in the project's notes so it is restored on that date. Casefile
  Crafter, 2026-10-12: GLM and Grok were both out for the week, so
  writers went straight to Sonnet until Grok's window on 2026-10-16 and
  GLM's on 2026-10-17. The policy is read before every turn, so the
  pause applies to running work too.
- Retire a provider whose compute is gone for good the same way, with
  no comment left to restore it, and from the project's own rules,
  scripts, unit names and tracker labels as well. A run keeps reading the
  policy file it was launched with, by path: leave that file in place as
  a transition copy whose top-level `writer_model` names a live writer
  and whose fallbacks still catch the retired line, and delete it when
  those runs end. New launches use a clean policy.
- Test a fallback model once before relying on it:
  `atomic -ne -p "Say hello" --model <id>` from a scratch directory.
- Run both of the workflow's test files in the preflight for any runtime
  upgrade: they fail if the runtime stops passing the fallback gate
  through to delegated agents or changes the transcripts the audit reads.
  Since Atomic 0.9.65 a subagent on a named model no longer falls back
  onto the orchestrator's model by itself; the gate stays as a second
  guard.

## Choosing among a tier's presets

When the user gives a tier's presets weights, a weight is the share of
that tier's launches the preset should get over time. It is a target to
steer by, not a dice roll: you decide each launch and keep the running mix
near the weights. With no weights given, keep the mix even.

Decide in this order:

1. **Fit.** Some issues call for one preset whatever the mix:
   - In the standard tier, prefer the Opus writer when the risk is in
     judgment (accessibility behavior, user-facing copy, anything
     security-adjacent), and GLM or Grok when the risk is in volume (wide
     but mechanical changes, journey tests).
2. **Evidence.** Keep a tally per preset of reviewer rounds, QA findings
   and elapsed time. Shift launches toward the preset that is landing
   clean, and tell the user when the evidence disagrees with the weights.
3. **Spread.** When launching several issues at once, spread them across
   providers so one provider's rate limit does not stall the batch.
4. **Mix.** With nothing else to separate them, pick the preset that is
   furthest below its weight in the tally.

State the preset and the reason for each issue in the launch report, for
example "TUS-88: Grok writes, Opus reviews (wide, mechanical; Grok is under its share)".

Compute budgets move, so expect standing overrides: the user may say "use
the Opus writer for complex work until 17:00 today". Apply an override for
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
- any UI/UX work, whatever its size (Sid, 2026-11-10)
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
