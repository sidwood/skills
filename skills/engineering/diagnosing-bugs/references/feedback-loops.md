# Feedback-Loop Patterns

Choose the highest realistic seam that reproduces the exact symptom:

1. A failing test at a unit, integration, protocol, or end-to-end seam.
2. An HTTP or CLI command with fixture input and an explicit assertion.
3. A browser automation script that checks DOM, console, or network behavior.
4. A captured request, payload, event stream, trace, or data fixture replayed in
   isolation after secrets are removed.
5. A throwaway harness around the smallest runnable subsystem.
6. A property or fuzz loop with a fixed seed and recorded counterexample.
7. A bisection command that can be used by `git bisect run`.
8. A differential command comparing known-good and failing versions or settings.
9. A structured human-in-the-loop procedure using
   [`hitl-loop.template.sh`](../scripts/hitl-loop.template.sh) when no unattended
   signal is possible.

Tighten the chosen loop until practical:

- **Specific:** it asserts the user's symptom, not merely that execution failed.
- **Repeatable:** inputs, time, randomness, filesystem, and network are controlled
  enough to give a useful verdict.
- **Fast:** setup and unrelated work are removed so hypotheses can be tested
  repeatedly.
- **Agent-runnable:** it runs unattended where possible and structures any
  unavoidable human interaction.

For nondeterministic failures, loop or stress the trigger and report the measured
failure rate. A stable high failure rate can be a useful red signal even when a
single run is not deterministic.

## Resource lifecycle probes

- List the exact test inventory before using substring filters when suites can
  touch credentials or native state; a broad lifecycle filter can unexpectedly
  select a Keychain fixture. Prefer exact tests or explicit safe-module filters.
- Measure owned threads and open database descriptors immediately after repeated
  in-process shutdowns; process exit conceals detached workers and retained stores.
- Drive simultaneous starters through the production preparation path against a
  fresh disposable installation; testing only socket binding misses migration and
  backup races before singleton acquisition.
- Probe followers with a socket that accepts but never answers health; successful
  connection alone cannot prove safe reuse, and both connection and response waits
  need deadlines.
- Exercise canonical and short symlink paths separately; canonical lock identity
  can exceed Unix socket address limits when reused as the wire address.
