# The composer-grok harness

A lighter harness beside Atomic, for simple-tier issues. It uses only the
supported Cursor command-line agent (`cursor-agent`), so it spends Cursor
subscription compute and nothing else. Trialed on 2026-10-04 on two
issues; the QA agent approved both and judged the pairing trustworthy for
simple issues with checkable criteria, with train review behind it.

## What it is

- **Writer:** Composer 2.5, which edits, runs the repository's checks and
  commits in a branch clone.
- **Reviewer:** Grok 4.7 at extra-high effort, read-only, as a separate
  process: a different model line from the writer.
- They alternate for up to three rounds. The run ends `approved in round
  N`, `not approved after 3 rounds`, or `failed`.
- One reviewer, not a quorum of three. The train's checks and the QA agent
  carry more of the weight than they do for an Atomic harness.

## When to use it

- The issue is `tier-simple` and its acceptance criteria can be checked
  without interpretation (a page state, a document, a config change).
- Do not use it where a criterion needs judgment about intent; in its trial
  it stated a command that did not exist and fixed a mistake in one file
  while leaving it in another.

## Launch

The harness cannot read the tracker, so write the issue to a brief file
first: title, then the description verbatim (a helper agent can do this).

```bash
scripts/launch-composer-grok.sh --issue TUS-36 --brief /path/to/TUS-36.md
```

It makes the clone with `git bc-add`, opens a tab named for the issue and
runs `scripts/composer-grok.sh` there. It prints `tab`, `pane`, `clone`,
`base`, `writer` and `reviewer`. `scripts/status.sh` and `scripts/watch.sh`
see it like any other harness.

## Read the result

Everything is in `<clone>/.atomic/composer-grok/`:

- `result.md`: outcome, commits, whether the tree is clean.
- `round-N-review.md`: the reviewer's findings and verdict for each round.
- `round-N-writer.log`, `round-N.diff`: what the writer did.

`approved` means ready for a train. `blocked` in the status list means not
approved or failed: read `result.md` and the last review, then either start
an Atomic follow-up run in the same clone with the findings as the
objective, or report it.

Copy the state directory somewhere safe before removing the clone if you
want the review record kept.

## Landing

Exactly as for an Atomic harness: stack in the staging clone, run the
checks, land, hand to the QA agent. Tell the QA agent the work came from
this harness, so it reads the diff with that in mind.
