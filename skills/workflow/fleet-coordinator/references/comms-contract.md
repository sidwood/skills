# Operator communication contract

Your pane is read by scanning. The operator skims it to learn what the fleet
did and, above all, to spot anything being raised upward. Every report you
write — to the operator, to the orchestrator, or into your own pane — follows
this contract, because all three end up in front of the operator.

## Register: plain five-year-old language

A directive in its own right, not a side effect of using bullets.

- **Short, common words.** Say "stuck waiting for approval", not "blocked
  pending gate resolution"; "the check went red", not "the suite regressed".
- **One idea per bullet**, said the way you would say it out loud.
- **No jargon and no model-speak.** Phase names, flags, tool syntax, and
  internal identifiers stay out of the prose unless the reader used them first.
- **Technical precision lives in the linked files.** SHAs, ranges, gate tables,
  findings, and phases belong in the capture file, the fleet config, or an
  optional board projection — never in the chat bullets.
- **This applies regardless of which model writes the report.** A verbose model
  drifts into dense, precise prose by default; that drift is the failure this
  rule exists to catch. Every lane whose output the operator will read is held
  to the same register.

## Form

- **Bullets, always.** No narrative paragraphs, no preamble, no closing
  summary of what you just said.
- **Answer first.** The first bullet is the event and the action you took.
- **One fact per bullet.** A second sentence is a second bullet, or a file.
- **No recaps** of what you already reported this turn, and no narration of
  your own process.
- **Detail lives in files, linked.** Captures, prompts, gate output, and
  verdict records are paths you name, not text you paste.

## Volume

- **Quiet holds.** A routine dispatch, sweep, or land is one bullet, or
  silence. Silence is a valid report when nothing needs a person.
- **Interesting means more compression, not less.** A striking finding is
  exactly when prose creeps back in. Compress harder: what it is, what you did,
  one path to the evidence.

## ⚠️ means work is stopped, waiting on a person

Use it for exactly one thing: this stream cannot proceed until the operator (or
the orchestrator standing in for them) answers.

Use it when:

- A decision is theirs alone and the stream is stopped until they make it.
- A ruling needs overturning or the work goes the wrong way.
- Something is blocked and only they can unblock it.

Never use it for:

- A settle you are sweeping, a bounce you are dispatching, or an item you have
  landed.
- A finding or a red gate you are already handling.
- Emphasis, or progress, however dramatic.

Because escalations are the operator's reason for scanning your pane, mark
**every** escalation ⚠️ — an unmatched event, an exhausted bounce cap, a prompt
violation, a lost verdict — and mark nothing else. If you are handling it, it
is status, and status gets a plain bullet. Most reports carry zero ⚠️; a
decorative one tells a scanner the fleet has stopped when it has not.

## Decisions

- The ask goes **last**, in its own bullet, as a **bold ask**.
- Recommendation first, then the alternatives, each with its cost.
- One ask per bullet.

## Mechanics

- **en-GB spelling** in reports and commit messages, unless the project sets
  another locale.
- **Run `date` before writing any timestamp.** Never infer wall-clock time.
- **No attribution trailers** in any commit message.

## Shape of an escalation

```text
- ⚠️ <ticket>: <what is stuck, in plain words>.
- What I already tried: <one bullet>.
- Evidence: <path to the capture>.
- **Ask:** <decision>, recommend <option> because <one clause>.
```
