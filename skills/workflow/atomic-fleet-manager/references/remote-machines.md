# Work on another machine

A second machine takes harnesses while the fleet manager's own machine
keeps trains, landing and QA. Herdr Core reaches it as an hc machine
(`hc machine ls`); every step below goes through `hc`, so it costs no SSH
session of its own.

## Before the first unit

1. **Clear the machine for the project.** The user says yes to each
   machine for each project. Record it in the seed, one line per machine:

   ```text
   # .atomic/fleet/remote-machines.txt
   framework  Owner, 2026-10-25: the FD runs every new unit
   ```

   `remote-launch.sh` refuses a machine that is not listed. A project
   holding company or customer data needs the user's explicit yes for
   each machine, in their words, before anything runs there. Some
   machines are barred for some work outright; ask when unsure.
2. **Nothing secret crosses.** The scripts copy only the clearance, the
   brief, the objective and an issue text. Never copy a `.env` file, a key,
   a token or a login; `remote-launch.sh` refuses those names. A check that
   needs a secret runs on the fleet manager's machine, or the user puts
   the secret there themselves.
3. **Prove the gate there once.** Run the project's full gate on a clean
   clone of the default branch before any unit relies on the machine:
   - Set the environment up the way CI does, from the tracked `.example`
     files (read CI's setup script), not from memory. One empty variable
     written by hand failed every web unit test file in the first trial.
   - Install any browser the test runner lacks with the project's own
     runner (`playwright install firefox`); system libraries need the
     machine's owner.
   - Expect Linux differences: no Apple fonts, no Meta+ shortcuts, and
     tools that need the machine's owner to install. Check for `lsof`
     before the first run: a test helper that asks it who holds a port
     reads "nobody" when it is missing. On the `agents` VM that failed 150
     of 1,449 browser journeys (every mock-server journey, in all three
     browsers), and nothing else.
   - Check that Atomic's workflow loads there: goal-select imports an
     absolute path under the Mac's home (`/Users/<you>/.local/share/atomic`),
     which works on a Linux machine only where `/Users` links to `/home`.
     `ls` that path on the machine before the first launch.
   - Expect WebKit on Linux to fail drawing checks the Mac passes (on
     the `agents` VM: graph arrowhead sizes and contrast in the component
     suite). Run Chromium and Firefox there and keep WebKit on the Mac,
     as the Framework desktop already does with Chromium only.
   - Give the gate its own containers and ports, or check that no other
     fleet uses the same names (`postgres`, `redis`, 5432, 6379).
   - Run it in a named terminal and record the result before the first
     launch.

## Sharing a machine with other fleets

Several fleet managers may launch on one machine. Agree terms with each
of them by `hc send`, and write them down in both seeds.

| Shared | Rule |
|---|---|
| Atomic's workflow database | Each open Atomic terminal holds connections. Agree a ceiling (for example 240 of 300) and a cap of terminals per fleet; close terminals when runs end. `remote-launch.sh --max-terminals` holds your cap. |
| Gate slots | A lock directory per machine, a few slots, and a `.priority` folder for the fleet whose checks go first. |
| Load | Start nothing at or above about two thirds of the core count (`--max-load`); run checks at `nice 10`. |
| Containers and ports | Unique names and ports per fleet. |
| Provider windows | A key two fleets share (a rate window) needs a cap per fleet. |

## Launching

```bash
scripts/remote-launch.sh --on framework \
  --remote-seed /home/me/code/project --issue PRJ-12 \
  --file .atomic/fleet/briefs/prj-12-objective.txt=.atomic/fleet/briefs/prj-12-objective.txt \
  -- --tier standard --checkout /home/me/code/project.prj-12 \
     --objective "$(cat .atomic/fleet/briefs/prj-12-objective.txt)"
```

It checks the machine is cleared, connected, under your terminal cap and
under the load ceiling. It copies the issue's clearance and each `--file`,
then copies this skill's own `launch.sh` and its helpers to the machine,
so a stale copy of the skill there cannot change the launch. It runs that
`launch.sh` through `hc exec` and prints its lines, with the terminal's
full address (`framework/t9`). It names the GUI tab after the issue,
records the run in your launch log, and adds a line to the units file
(`.atomic/fleet/remote-units.txt`):

```text
PRJ-12 8ae31d92-... framework/t9 /home/me/code/project.prj-12
```

Paths after `--` are paths on that machine. A machine without the
tracker's sign-in takes `--tracker none`: copy the issue text there as a
read-only file with `--file` and name it in the objective.

The terminal joins the fleet's GUI space under that machine (the GUI
shows it in the machine's space of the same id). It keeps the bare
`herdr.space` label, so `status.sh` and `watch.sh` on your machine list
it with the rest. A terminal opened there by other means carries that
machine's space id instead: give it `fleet.project=<project>` (and
`fleet.name`, `fleet.role`) and the scripts find it by project.

## Watching

```bash
scripts/remote-watch.sh --units .atomic/fleet/remote-units.txt --auto-resume 3
```

Run it in the background beside `watch.sh`; its exit is the wake-up. It
asks each machine once a minute, with one `hc exec` per machine, for every
run's ledger status and the minutes since its Atomic sessions last wrote,
and reads each terminal through `hc`. It reports one line and exits:

- `ENDED`: the ledger left active, or a resumed run (marked `R` in the
  units file) wrote its orchestrator receipt.
- `STALLED`: the ledger says active, but the terminal has been at rest
  with no run in its BACKGROUND box for three checks.
- `QUIET`: the ledger says active, but nothing was written for
  `--quiet-min` minutes (default 20). A load spike can kill a stage
  without a word in the terminal.
- `GONE`: the terminal ended.
- `PAUSED`: Atomic paused or quit the run, and `--auto-resume` attempts
  are spent (or 0). Each attempt runs this skill's `resume.sh` on the
  machine, under the run's own id, and is logged beside the units file.

One copy runs per units file: a new one stops the old, so re-arm freely.
Remove a unit's line once it has landed.

## Bringing work home

```bash
scripts/remote-fetch.sh --on framework \
  --remote-clone /home/me/code/project.prj-12 --remote-seed /home/me/code/project
```

It bundles the clone's commits over the remote seed's default branch and
carries the bundle home through `hc`. It then resets a local clone beside
your seed to that head, making the clone if needed. It refuses a dirty
clone at either end, and a local clone with commits of its own. Then land
it as usual ([landing-train.md](landing-train.md)). Check the authors in
its summary line before a push.

## Cleaning up

After the work lands and QA approves: `hc kill framework/t9; hc rm
framework/t9`, then remove the remote clone there the way the project
removes clones (`hc exec --on framework -- git bc-rm <clone> -y`), and drop
its line from the units file.

## Lessons

- Wait by the clock, not by one long `sleep`: a laptop's sleep does not
  count while it is asleep, so a job set for 02:00 ran at 10:13.
- Never edit a script a harness is running; write `.new` and `mv` it
  over, because bash reads scripts as it goes.
- A password manager's SSH agent stops signing when its owner is away, so
  pushes and fetches over SSH fail at night. Use the HTTPS push URL with
  the GitHub CLI's credential helper, or `hc`.
- SSH control connections have a session limit, and fleets share it. Use
  `hc exec` and `hc file`, which use none of them.
- The GUI renames a new terminal's `where` label. Name the GUI tab
  (`herdr-app do tab.rename`) and find terminals by `fleet.name`.
