# The cloud lane: a unit written on other machines

A second lane beside the local harnesses. Remote coding agents (for example
Cursor cloud agents on Linux VMs, driven by another team of agents) write a
whole unit on a branch. Everything from the landing train onward stays
with the fleet manager.

Status: a trial. First used on Casefile Crafter, 2026-10-08, M2 unit 8.
Update this file with what the first handback shows.

## Why, and what it must not cost

- About 70% of a unit's time is writing and review. A second writer on
  other machines shortens a milestone and adds no load to this one.
- Treat the lane as a harness you do not run: a brief goes in; a branch and
  a report come out. Nothing changes for the local lane, the train, the
  gate, the QA review or how tickets close.

## What the remote agents can and cannot see

- They see the hosted repository and the tracker. They see nothing on this
  machine: no brief file under `.atomic/`, no local scripts, no local env
  files, and no document that the repo names only by a local path.
- So before the first unit, read the repo's own setup notes as a stranger
  would. Typical gaps: an env file that is ignored and has no template, no
  browser install step, a tool installed by a package manager the remote
  OS lacks, a standards wiki named by a path on the author's machine.
  Have the pre-launch read list them (its section 8 below), and tell the
  agents what to do instead.
- You probably cannot message them. Until you can, write the prompt and ask
  the user to relay it. Keep the relayed prompt to a few lines that point
  at the tracker, where the full instructions are.

## What to give them

- Whole units only, never part of one.
- A unit that shares no file with any unit running locally. Take the list
  from the pre-launch read's overlap section, not from the labels.
- Never payments, and never work whose security rests on the code being
  written. A page whose rules the API already enforces is acceptable.
- A unit is marked on its tickets with a label, `UNIT8` for unit 8.

## The brief, on the tracker

1. **Decisions** at the end of each ticket's description, as for any unit.
   Say that every default in the read stands except the ones you list,
   then list those, then the files that must not change.
2. **The pre-launch read** as comments on the ticket, split at section
   boundaries (a 50,000-character read made four comments). Have the helper
   write it to stand alone: repo-relative paths only. Add a section 8,
   "What a remote machine needs": versions, setup steps, the command for
   each suite, the variable names the suites need, what the commit hooks
   reject, and each instruction in the repo that points at something a
   remote machine lacks.
3. **The working agreement** as the newest comment: where the brief is,
   when they may start, the rules, how to hand over, what happens next.

The working agreement carries what no committed file says:

- Start only when the default branch holds a named commit subject, when
  the unit builds on work that is still landing. A subject survives a
  rebase; a hash does not.
- Branch as `unit/<key>`. Never push the default branch, never merge, no
  pull request.
- The commit rules, including the ones no hook checks (no tracker id in a
  message, no attribution of any kind). Attribution includes authorship:
  every commit is authored and committed under the repository owner's
  identity, never an agent's. `cloud-fetch.sh` prints the authors it
  finds; re-author a foreign commit before it goes anywhere, and check
  that the tree is unchanged.
- The suites to run before handing over, and which ones to skip and why.
- Have the diff reviewed by a model from a different family than the
  writer, and say which wrote and which reviewed.
- On the tracker, comment only. States, labels and descriptions are the
  fleet manager's.
- Hand over by pushing the finished tip to `unit/<key>` and then the same
  commit to `ready/<key>`, once, and by commenting a report on the ticket.

## Watching and landing

```bash
scripts/cloud-watch.sh --unit m2-u8        # background; exit is the wake-up
scripts/cloud-fetch.sh --unit m2-u8        # after READY
```

- `STARTED`: set the unit's tickets to started.
- `READY`: fetch. The script makes the clone `<seed>.cloud-<key>` and
  prints the base, the commits and a check of their messages. Have a helper
  read the report comment. Then stack, gate, land, hand to QA once and
  clean up, as for any clone. Reword a bad commit message in the staging
  clone before pushing.
- `MAIN_MOVED`: someone else pushed the default branch. Stop landing and
  find out who, before anything else.
- A hosting plan may not offer branch protection for a private repository.
  Then the rule against pushing the default branch exists only in the
  prompt, and `MAIN_MOVED` is the only alarm.
- A QA finding on the unit's own criteria goes back as a comment on the
  ticket; the fix comes back on `unit/<key>` and `ready/<key>` again. A
  small one can be fixed locally instead.
- After the unit is Done, ask for the two remote branches to be deleted.

## What the first handback showed

- The branch came back with clean commit messages and none of the files
  it was told not to touch, and stacked cleanly on two units that had
  landed since its base.
- The report came several minutes after the ready branch, not with it.
  Do not conclude from one look that none is coming: start the train, and
  read the ticket again before writing the QA handover.
- The landing gate failed four of the unit's own new browser tests, in
  WebKit only. A remote Linux machine cannot show how WebKit behaves on
  macOS: a click does not focus a button there, and Tab visits only text
  fields. Put such platform rules in the working agreement next time, with
  the repo's own example of each.
- A failure like that is quicker to fix here than to send back: the remote
  agents cannot reproduce it. Fix tests only, as one commit of your own on
  top of their branch, run the changed files in every browser, run the
  gate again, and tell QA that no reviewer has seen that commit.

## The user's editor may forward the remote ports onto this machine

Seen on the first trial. The user's desktop app for the cloud agents
forwarded the remote machine's ports to `127.0.0.1` here: the web and API
ports, and the database and cache ports too. They are the same fixed
ports the local suites use, and the forward comes and goes with the
remote agent's servers.

- A suite script that waits for its ports to be free then waits on the
  forward, and fails when its wait runs out.
- A suite that is already running is worse off: Chromium resolves
  `localhost` to `127.0.0.1`, so its requests reach the remote agent's
  server while other browsers reach the local one. The sign is a block of
  failures in one browser only, in cases that touch the API.
- A local tool that connects to `127.0.0.1` on the database port reaches
  the remote database.
- Find it with `lsof -nP -iTCP:<port> -sTCP:LISTEN`: the listener is the
  editor's helper process, on `127.0.0.1` only.
- The cure is the user's: stop the forwards and turn off automatic port
  forwarding in that app. Do not kill their app.
- Until then, watch the ports for a listener that is not one of yours, and
  treat any gate that overlapped one as suspect.

## Keeping count

Record the same measures as for a local unit (review rounds if they report
them, QA findings on the unit's own criteria, tickets QA filed, hours from
handover of the prompt to Done), plus the hours the unit waited on you.
They are the evidence for whether the lane is kept.

## If it is kept

- Move the standing part of the working agreement into one committed file
  in the repo, and close the setup gaps in the same change, so a unit's
  prompt shrinks to the label, the branch name and the commit to wait for.
- Keep the per-unit part on the tracker.
