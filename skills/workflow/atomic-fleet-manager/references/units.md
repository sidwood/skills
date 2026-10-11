# Units: several issues in one harness

A unit is two or more tracker issues given to one harness as one piece of
work: one brief, one clone, one train, one QA review. Each issue still
gets its own commits and its own verdict.

## When to use it

- The issues edit the same files or the same component, so separate
  harnesses would conflict or wait on each other.
- A backlog of small defects keeps arriving one at a time, and each one
  costs a full launch, review, train and QA cycle.
- The user asks for one harness at a time.

Evidence, Casefile Crafter, 2026-10-08: eight M1 defects ran as one unit
with one fix pass. Nine tickets closed in 11 hours, about 1.2 hours a
ticket against about 2.5 when each ran alone. Four review rounds drew 11
findings; the one QA review drew two on the unit's own criteria.

## Grouping

- Together: issues that share a file, a component or a service, and the
  journey test that exercises them, which goes last in the same unit.
- Alone: security work, and complex work that shares nothing.
- Last of all: a restyle of pages that earlier units change.
- Order units by their blockers, and write one line per unit saying why
  it is grouped as it is. Show the user the table before the first launch.
- The panel must suit the hardest issue in the unit, whatever the other
  labels say. Record each departure from the tracker's labels.

## The brief file

The harness cannot read several tickets from the tracker, so the brief is
a file in the seed, `<seed>/.atomic/fleet/briefs/<unit>.md`, built from
three parts kept as separate files and joined:

1. **Head**, yours: how the unit runs, then your decisions.
2. **Pre-launch read**, a helper's: each ticket checked against the code
   at the seed commit, without running anything. It lists the open
   choices, the claims in the tickets that are wrong at that commit, and
   the other cases of any class a ticket is one case of.
3. **Tickets**, verbatim from the tracker, with every acceptance
   criterion.

Write the head after the read, so every open choice it lists is settled
by a decision. Append the same decisions to each ticket in the tracker.

The head's standing rules:

- Each ticket's criteria are the contract for that issue; where a decision
  differs from a ticket's words, the decision wins.
- Each issue in its own commit or commits, never two issues in one.
- For every new test, show it failing on the unfixed code. For every guard
  test, show it failing on a deliberate new instance of its class.
- If one issue still has open findings late in the run, leave the others
  alone and say which issue is not done.
- The harness cannot change the tracker: anything a ticket asks to be
  noted goes in the final report.
- A final report per issue: commits, each criterion and whether it holds,
  the failing-first evidence, and what was found and not fixed.
- What the next unit will edit, so this one keeps its changes to those
  files small.
- What the reviewers should probe.

## Launching

```bash
scripts/clear.sh --issue M2-U1 ...
scripts/launch.sh --issue M2-U1 --tracker none \
  --policy <seed>/.atomic/fleet/policy-m2.jsonc --tier complex \
  --writer anthropic/claude-opus-5-5:xhigh \
  --objective "Work M2 unit 1: two tracker issues as one unit of work. The brief is the file <path>. It is part of this objective ..."
```

- `--issue` is the unit's key: it names the tab and the clearance. With
  `--tracker none` the clone is named from the objective's first words.
- Read every ticket's state and relations fresh before `clear.sh`, as for
  any first launch. `clear.sh` wants a `--blocker` state for every ticket
  id named in `--execution-order`, so name only blockers outside the unit.
- Double quotes inside `--objective` become single quotes.
- The objective points at the brief, repeats the commit rules, and carries
  the writer's fallback sequence
  ([model-tiers.md](model-tiers.md#when-a-writers-provider-runs-out)).
- A panel or round limit that differs from the shared policy goes in a
  policy file kept in the project and passed with `--policy`. Do not edit
  the shared policy for one unit or one milestone.
- `--resolve-only` still opens a tab and writes a row in `launched.tsv`.
  Close the tab and remove the row afterwards.
- After the run id is confirmed, set every ticket in the unit to started.

## Landing and review

- One train for the whole unit. Check the commit messages on the train
  before pushing, as for any train.
- One QA review, with a handover file: the range, the contract and where
  the decisions are, the commits by issue, what the harness's reviewers
  found in each round, what the writer reported and did not fix, and the
  rule for where a new finding goes.
- Copy the writer's final report and evidence matrix out of the clone's
  `.atomic/` before cleanup. Leave the clone in place until the QA verdict
  is in, so the QA agent can read the reviewers' probes.
- A run that stops at its round limit with a finding open still lands as a
  train. Hand it to QA with the open finding stated; QA finishes it in its
  own clone and that fix is its own train.
- A fix pass for QA's findings runs in the unit's clone with
  `launch.sh --checkout`. It lands on its harness's approval and the gate
  and is not sent back to QA ([qa-agent.md](qa-agent.md)).
- A fix that is a test only, in code the next unit works in, can go into
  the next unit's brief as its first commit, by itself. It still lands on
  a harness's approval and the gate, it costs no harness of its own, and
  the next unit is written against the stronger test. The ticket stays in
  review until that unit lands. Do not carry a product fix this way.

## Two units at once

One harness at a time is the default for a milestone run as units. A second
one, or a unit in the cloud lane ([cloud-lane.md](cloud-lane.md)), needs
the user's word and these checks:

- The pre-launch read of the second unit has an overlap section that names
  every file it shares with the first, the hunk in each, and one plain
  line: can run beside it, yes, yes with care, or no.
- No shared file is best. A shared file is acceptable when the edits are
  far apart and each brief names the other's lines. Have the unit with the
  smaller edit make it as its first commit.
- Each brief lists the other unit's files as not to be edited.
- Whichever lands second is rebased onto the first by the train. Expect to
  resolve a conflict in an append-only file such as a spelling list; tell
  one unit to add in the middle of it.
- Suites with fixed ports cannot run twice at once. Both objectives say to
  use the fleet's locked script, and both gates and your trains queue.
- `clear.sh` counts issues, so the second unit needs `--user-exception`
  with the user's own words.
- Two local harnesses at most. Three is where the machine failed before.

## Between one unit and the next

A brief written while the unit before it was running is out of date by
the time it launches. Before the launch:

- Add a section saying what the unit before landed in the files this one
  edits: new helpers and where they are called, new settings, new guard
  tests and what they forbid, the newest migration, new documents.
- Read the tickets again. The QA agent adds notes to the next unit's
  tickets from its review; put them in the brief's ticket text.
- Correct each state the brief quotes for a blocker or a neighbor.

## Keeping count

Keep one progress file in the project, `<seed>/.atomic/fleet/<milestone>-progress.md`:

- The table of units: issues, why they are grouped, writer, reviewers and
  status. Print it in every update on the milestone.
- The rules agreed for the milestone, and each departure from the tracker.
- One row of measures per closed unit: review rounds, reviewer findings,
  QA findings on the unit's own criteria, tickets QA filed outside them,
  and hours from launch to done. These are the evidence when the user
  later asks whether a change of model or effort paid off.

## Writing decisions onto a ticket

- A ticket is read by people and agents who do not have the brief. Write each decision so it stands alone: never "the cut line above" or "as listed above". Spell the cut line and the order out.
- Append with a patch that does not resend the description. A tracker may re-parse the whole description on any save and rewrite markdown it did not write: bullets, ticket ids turned into links, and bold lost around an id in brackets. Keep ticket ids out of bold headings.
- Have the helper re-fetch and confirm the first 200 characters and the tail after every append.
