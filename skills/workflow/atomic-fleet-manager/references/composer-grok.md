# The pair

A lighter harness beside Atomic. `pair.sh` is the one way to open a
writer and a reviewer. It creates one Herdr pane, splits it down, and
runs one agent in each half. Trialed on 2026-10-04 on two issues with
Cursor's agent; the QA agent approved both and judged the pairing
trustworthy for simple issues with checkable criteria, with train review
behind it.

## What it is

Two hc terminals named for the issue (`fleet.name`), the reviewer below
the writer, in one GUI tab named for the issue:

- **The writer** (role `pair-writer`) edits, runs the repository's checks
  and commits in a branch clone. The default is Cursor's agent,
  `composer-2.5`.
- **The reviewer** (role `pair-reviewer`) is the other half of that pane.
  It writes one report and edits nothing else. The default is Cursor's
  agent, `grok-4.7-xhigh`, a different model family from the writer.
- **You are the orchestrator.** You send the writer its round, then the
  reviewer its round, read each report and decide what comes next, for up
  to three rounds. The user can watch both agents work and read every
  prompt you send.
- One reviewer, not a quorum of three. The train's checks and the QA agent
  carry more of the weight than they do for an Atomic harness. QA is
  never a third pane of this tab. It reviews work that has merged to the
  main branch, in a pane of its own ([qa-agent.md](qa-agent.md)).

## When to use it

Use the pair for a tier's `agent` row in
[model-tiers.md](model-tiers.md), or name another launcher. `--writer`
and `--reviewer` take `launcher:model`. A bare model name is still the
Cursor agent at `~/.local/bin/agent` (Homebrew's `agent` is Grok Build,
and this script does not call it).

| Spec | What starts |
| --- | --- |
| `composer-2.5`, `cursor:composer-2.5-fast` | Cursor agent, `--model` that name, `--force` |
| `claude-work:claude-opus-5-5` | `CLAUDE_CONFIG_DIR=~/.claude-work claude --dangerously-skip-permissions --model` that name. Never a default: only when the command names `claude-work`, because it spends the owner's own account. |
| `claude-glm` | `CLAUDE_CONFIG_DIR=~/.claude-glm` and `claude --dangerously-skip-permissions --model glm-5.3[1m]`, with the unknown-model window override set. |
| `grok`, `grok:grok-4.7` | The `grok` CLI, `--model grok-4.7` unless a model is given, `--trust`, permissions `bypassPermissions`. |

Cursor is ready when the screen says `Plan, search, build` or
`Add a follow-up`. Its trust chooser (`Trust this workspace`) is accepted
with the `a` key. Claude is ready when a line is `❯`. Its trust chooser
defaults to `No, exit`; the script sends Down, then Enter. Grok is ready
when a line is `❯`. Prompts are typed with `hc send`. Cursor folds a
prompt past about 500 characters.

| Tier | `--writer` | `--reviewer` | QA |
| --- | --- | --- | --- |
| simple | `composer-2.5` (the default) | `grok-4.7-xhigh` (the default) | none unless its train carries standard or complex work |
| standard | `grok-4.7-xhigh` | `claude-opus-5-5-high` | Fable 5.2 medium |
| complex, and all UI/UX work | `claude-opus-5-5-xhigh` | `grok-4.7-xhigh` | Fable 5.2 medium |

- With the Composer writer, keep to issues whose acceptance criteria can
  be checked without interpretation (a page state, a document, a config
  change). In its trial it stated a command that did not exist and fixed a
  mistake in one file while leaving it in another.
- `pair.sh` compares model family across launchers, so
  `cursor:grok-4.7-xhigh` and `grok` are refused together, and so are two
  Claude models.

## Open a pair

The agents cannot read the tracker, so write the issue to a brief file
first: title, then the description verbatim, then any notes of your own
under a heading that says they are yours.

```bash
scripts/pair.sh open --issue TUS-36 --brief /path/to/TUS-36.md
```

It checks the clearance and the load, makes the clone with `git bc-add`,
opens one pane and splits it, starts both agents (answering a trust
question for the new checkout) and sends the writer round 1 with
`hc send`. It prints `tab` (the GUI tab), `writer_pane` and
`reviewer_pane` (the two terminals' hc addresses), `clone` and `base`.
Report the launch once the writer is at its prompt. `--space` is the
fleet's GUI space when you cannot default it (`--workspace` is the old
name). `--max-pairs N` is how many pairs may be open at once (default
2, or `FLEET_MAX_PAIRS`). The load check is unchanged.

## The loop

`scripts/status.sh` shows the pair as one row, and `scripts/watch.sh`
fires each time both agents come to rest. Not yet verified: whether hc
reports a Cursor agent's status at all. hc takes status from the OSC 7501
reports an agent emits; if Cursor's `agent` emits none, the pair's state
words mean nothing, so read both terminals (`hc read <t> --lines 0`)
before trusting them. Then:

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
| `read the writer's terminal` / `read the reviewer's terminal` | The agent stopped without its report or verdict. Read the terminal and answer it inside the round: `scripts/pair.sh say --issue TUS-36 --to writer --note "..."`. A Cursor writer often ends its turn with its gate still running in the background; tell it to poll the log to the end. |
| `reopen ...` | An agent has left its terminal. Close both terminals (`hc kill`, `hc rm`) and run the command it names; the round files carry the history. |

Read the report before sending the next prompt: you are the one deciding,
and the reviewer's word is not yours. `--note "..."` adds your own
sentence to a prompt, for a ruling or a correction; `write --note` also
sends the writer back after an approval you do not accept.

## Prompts and files

Cursor folds a typed prompt longer than about 500 characters into
`[Pasted text]`, which cannot be read in the terminal. So each prompt is two
or three sentences naming files, and the standing rules live in the clone.
`pair.sh` prints `chars=` for each prompt and warns when a note pushes it
over.

Everything is in `<clone>/.atomic/pair/`:

- `brief.md`: the work definition.
- `writer-rules.md`, `reviewer-rules.md`: the standing rules, including
  the landing gate as the writer's last step when the seed has one.
- `round-N-writer-prompt.md`, `round-N-review-prompt.md`: exactly what was
  typed into each terminal.
- `round-N-writer.md`: the writer's report. `gate-N.log`: its gate run.
- `round-N-review.md`: the reviewer's findings, ending `VERDICT: APPROVED`
  or `VERDICT: CHANGES_REQUESTED`.
- `pair.env`: the GUI tab, the two terminals, the clone, the base and
  the seats. A file written by an older `pair.sh` has no launcher
  fields; `write`, `review` and `status` still read it.

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
this pair, so it reads the diff with that in mind.
`scripts/cleanup.sh --terminal <t>` closes one terminal; close the other
with `hc kill <t>` and `hc rm <t>` (both addresses are in `pair.env`).

## Things that go wrong

- **A pair waits for you.** Nothing moves between rounds until you send
  the next prompt. The limit is 2 pairs unless you set `--max-pairs` or
  `FLEET_MAX_PAIRS`. At the limit, other work goes to the Atomic writers
  ([model-tiers.md](model-tiers.md)). If you will not be there, use the
  unattended loop below.
- **Commits rejected for a trailer.** The writer rules forbid every
  trailer, including `Co-Authored-By`, which Claude adds unless told not
  to. Cursor also adds `Co-authored-by: Cursor` while
  `attribution.attributeCommitsToAgent` is true in
  `~/.cursor/cli-config.json`. The commit hook rejects trailers. Never
  pass `--no-verify`. A rejected commit is rewritten without the trailer
  and committed again.
- **The reviewer never reports `working`.** `hc send` succeeding is
  delivery. `pair.sh review` does not fail when the terminal stays
  `unknown`. Read the terminal (`hc read <t>`) when the round file does
  not appear.
- **Another harness left the work unfinished.** Start a pair on its clone:
  `scripts/pair.sh open --issue ID --clone DIR --brief FILE --note "..."`.
  The work stays; say in the note what state it is in.

## The unattended loop

`scripts/launch-composer-grok.sh --issue ID --brief FILE` runs the same
two models headless in one terminal (role `composer-grok`): writer,
reviewer, up to three rounds, with no prompts from you. Use it only when
no fleet manager session will be there for the handoffs.

- State is in `<clone>/.atomic/composer-grok/`: `result.md` (outcome,
  commits, tokens), `round-N-review.md`, `round-N-writer.log`,
  `round-N.diff`.
- It ends `approved in round N`, `not approved after 3 rounds` (a
  handover) or `failed` (the writer or reviewer did not run, or the
  writer made no commit; read the log it names).
- Each turn streams its events to `round-N-writer.jsonl` or
  `round-N-reviewer.jsonl`, and once a minute the status line shows what
  the turn is doing: `running: <command> (Nm)`, `last: <action>`, or
  `silent Nm, no command running`, which reports the terminal blocked so
  the watcher fires. The driver reports its state through a `fleet.state`
  label on its terminal, which `status.sh` reads, since hc does not know
  it as an agent. `scripts/cursor-stream.py summary|text|usage FILE` reads
  a stream file by hand.
