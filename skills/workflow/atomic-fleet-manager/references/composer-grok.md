# The composer-grok pair

A lighter harness beside Atomic, for simple-tier issues. It uses only the
supported Cursor command-line agent (`agent`), so it spends Cursor
subscription compute and nothing else. Trialed on 2026-10-04 on two
issues; the QA agent approved both and judged the pairing trustworthy for
simple issues with checkable criteria, with train review behind it.

## What it is

One tab named for the issue, split in two:

- **Top pane, the writer:** `agent --model composer-2.5 -f`. It
  edits, runs the repository's checks and commits in a branch clone.
- **Bottom pane, the reviewer:** `agent --model grok-4.7-xhigh -f`,
  a different model line from the writer. It writes one report and edits
  nothing else.
- **You are the orchestrator.** You send the writer its round, then the
  reviewer its round, read each report and decide what comes next, for up
  to three rounds. The user can watch both agents work and read every
  prompt you send.
- One reviewer, not a quorum of three. The train's checks and the QA agent
  carry more of the weight than they do for an Atomic harness.

## When to use it

- The issue is `tier-simple` and its acceptance criteria can be checked
  without interpretation (a page state, a document, a config change).
- Do not use it where a criterion needs judgment about intent; in its trial
  it stated a command that did not exist and fixed a mistake in one file
  while leaving it in another.

## Open a pair

The agents cannot read the tracker, so write the issue to a brief file
first: title, then the description verbatim, then any notes of your own
under a heading that says they are yours.

```bash
scripts/pair.sh open --issue TUS-36 --brief /path/to/TUS-36.md
```

It checks the clearance and the load, makes the clone with `git bc-add`,
opens the tab, starts both agents (answering Cursor's trust question for
the new checkout) and sends the writer round 1. It prints `tab`,
`writer_pane`, `reviewer_pane`, `clone` and `base`. Report the launch once
the writer pane is `working`.

## The loop

`scripts/status.sh` shows the pair as one row, and `scripts/watch.sh`
fires each time both agents come to rest. Then:

```bash
scripts/pair.sh status --issue TUS-36     # ends with next=...
```

| `next=` | Do |
| --- | --- |
| `wait` | Nothing; an agent is working. |
| `review` | Read `round-N-writer.md`, then `scripts/pair.sh review --issue TUS-36`. |
| `write` | Read `round-N-review.md`, then `scripts/pair.sh write --issue TUS-36`. |
| `land` | Approved, tree clean, gate passed: put it on a train. |
| `hand over ...` | Three rounds used and still not approved: see below. |
| `read the writer's pane` / `read the reviewer's pane` | The agent stopped without its report or verdict. Read the pane and answer it inside the round: `scripts/pair.sh say --issue TUS-36 --to writer --note "..."`. A Cursor writer often ends its turn with its gate still running in the background; tell it to poll the log to the end. |
| `reopen ...` | An agent has left its pane. Close the tab and run the command it names; the round files carry the history. |

Read the report before sending the next prompt: you are the one deciding,
and the reviewer's word is not yours. `--note "..."` adds your own
sentence to a prompt, for a ruling or a correction; `write --note` also
sends the writer back after an approval you do not accept.

## Prompts and files

Cursor folds a typed prompt longer than about 500 characters into
`[Pasted text]`, which cannot be read in the pane. So each prompt is two
or three sentences naming files, and the standing rules live in the clone.
`pair.sh` prints `chars=` for each prompt and warns when a note pushes it
over.

Everything is in `<clone>/.atomic/pair/`:

- `brief.md`: the work definition.
- `writer-rules.md`, `reviewer-rules.md`: the standing rules, including
  the landing gate as the writer's last step when the seed has one.
- `round-N-writer-prompt.md`, `round-N-review-prompt.md`: exactly what was
  typed into each pane.
- `round-N-writer.md`: the writer's report. `gate-N.log`: its gate run.
- `round-N-review.md`: the reviewer's findings, ending `VERDICT: APPROVED`
  or `VERDICT: CHANGES_REQUESTED`.
- `pair.env`: the panes, the clone, the base and the models.

Copy the directory somewhere safe before removing the clone if you want
the review record kept.

## Rounds and the handover

Three writer rounds. After the third review still requests changes,
`status` says to hand over: gate the clone, land it, and give QA
`round-3-review.md` as the open findings, the same as an Atomic run that
ends `handover` ([landing-train.md](landing-train.md)). One more round is
allowed only when that review leaves a P0 or P1 open:
`scripts/pair.sh write --issue TUS-36 --max-rounds 4`.

## Landing

Exactly as for an Atomic harness: stack in the staging clone, run the
gate, land, hand to the QA agent. Tell the QA agent the work came from
this pair, so it reads the diff with that in mind. `scripts/cleanup.sh`
closes the tab, which ends both agents.

## Things that go wrong

- **A pair waits for you.** Nothing moves between rounds until you send
  the next prompt. That is why the limit is one pair at a time, and why
  `pair.sh open` refuses a second: other simple-tier work goes to the
  Atomic writers while a pair is open
  ([model-tiers.md](model-tiers.md)). If you will not be there, use the
  unattended loop below.
- **Commits rejected for a trailer.** Cursor adds `Co-authored-by: Cursor`
  to every commit while `attribution.attributeCommitsToAgent` is true in
  `~/.cursor/cli-config.json`, and the writer cannot leave it off. A
  repository whose hook rejects attribution trailers needs that setting
  false, or the writer finishes with everything staged and nothing
  committed.
- **A prompt that does not start the agent.** `pair.sh` waits for the pane
  to go `working` and fails if it does not; read the pane before sending
  anything else.
- **Another harness left the work unfinished.** Start a pair on its clone:
  `scripts/pair.sh open --issue ID --clone DIR --brief FILE --note "..."`.
  The work stays; say in the note what state it is in.

## The unattended loop

`scripts/launch-composer-grok.sh --issue ID --brief FILE` runs the same
two models headless in one pane: writer, reviewer, up to three rounds,
with no prompts from you. Use it only when no fleet manager session will
be there for the handoffs.

- State is in `<clone>/.atomic/composer-grok/`: `result.md` (outcome,
  commits), `round-N-review.md`, `round-N-writer.log`,
  `round-N.diff`.
- It ends `approved in round N`, `not approved after 3 rounds` (a
  handover) or `failed` (the writer or reviewer did not run, or the
  writer made no commit; read the log it names).
