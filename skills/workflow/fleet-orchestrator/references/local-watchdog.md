# Local issue-only watchdog

Use this when healthy monitoring must consume zero model tokens. The OS runs
ordinary Python, Herdr, and Git checks; `codex queue` is called only for an
actionable incident. An empty AI response is not a free check. Worker activity
and legitimate handoffs still consume their normal model usage.

## Bind and test

1. Read `scripts/fleet-watchdog.py --help` and `codex queue --help`. Bind the
   canonical fleet config, ignored state directory, existing orchestrator
   task UUID, monitor heartbeat, exact coordinator name, and optional board
   and operator-pause marker. Use absolute executable paths for the scheduler.
   This watches an existing fleet; it creates no checkout, pane, or task.
2. Run a dry check against current state. Investigate every reported incident;
   do not suppress a real fault merely to produce a green probe. Verify the
   existing settle monitor is healthy and no operator pause is active.
3. Test with isolated fixture state and a fake `codex` executable: repeated
   healthy checks must produce zero output and zero queue calls; one expired
   handoff must queue once; repeated identical faults stay silent; recovery
   followed by recurrence queues again; failed delivery retries with backoff.
   Test pending review events, a missing monitor, malformed state, a healthy
   long-running reviewer, and operator pause. Do not damage the live fleet to
   manufacture an incident.
4. Verify one explicitly labeled synthetic delivery to the existing task via
   `codex queue --thread TASK_UUID --message TEXT`. Transport acceptance is
   not proof the model has processed it; inspect the queued message or receipt
   at the next task turn. Never use a different task as an implicit test target.

## Schedule local code, not a model

On macOS, install one user LaunchAgent with `StartInterval` set to 30 seconds,
`RunAtLoad` enabled, and `ProgramArguments` invoking Python plus the watchdog's
explicit arguments. Use the configured project as `WorkingDirectory`, an
explicit PATH containing the installed BC tools, and local output/error files.
Leave `KeepAlive` off: this is a bounded one-shot check. A process lock protects
the incident ledger if a manual probe overlaps a scheduled run.

Record the exact job label and plist path in the project handover. Inspect an
existing matching job before installation; update that job rather than adding
a duplicate. Use `launchctl bootstrap` to load it and `launchctl print` to
verify the registered arguments, execution result, and subsequent run count.
On other systems, use the equivalent native scheduler with the same one-shot
contract. Do not use an AI automation to launch the local check.

Keep the settle monitor running: it sends routine implementation results to
the coordinator. The independent watchdog reads its heartbeat and durable
pending events, so a dead settle monitor or unattended review can trigger a
model turn without continuous model polling. Capture and ruling authority
remain with their existing owners.

After local coverage passes, pause the superseded Codex heartbeat through the
app automation tool. Preserve its identity/history as a paused record and
record the replacement; do not edit automation files directly. A scheduled
AI heartbeat must not be silently restored during takeover or app restart.

## Runtime contract

- Healthy/no-action checks make no Codex call and emit no stdout or stderr.
- Actionable events include overdue handoffs, startup gaps, monitor failure,
  unreadable inventory/state, checkout drift, pending judgment events, idle
  ready work, missing active lanes, and stale configured board output. A healthy long-running lane is not a fault
  merely because backlog count has not decreased.
- Persist notification attempts before external delivery. Retry failed queue
  delivery with bounded backoff; do not mark an incident delivered on failure.
- Successfully queued incidents stay deduplicated until observed recovery.
  A later recurrence is a new incident. Retain local evidence and do not use
  log chatter, timestamps, or changing durations as incident identity.
- Respect the operator's pause marker. No wake or recovery is permitted while
  paused; preserve existing history for the resumed run.
- This requires an awake host and a usable local Codex queue service. If queue
  delivery is unavailable, retain the issue and retry; do not claim the
  orchestrator was notified. OS service execution failures are visible in its
  job status and local logs and must be checked at adoption. A corrupt
  watchdog incident ledger disables delivery and preserves the damaged file
  rather than risking repeated model calls; inspect the job failure at
  adoption and repair it explicitly.
