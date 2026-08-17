---
name: diagnosing-bugs
description: Use when the user asks to diagnose or debug broken, failing, throwing, intermittent, or slow behavior. Do not use merely to document or file a bug report.
license: LICENSE
---

# Diagnosing Bugs

Turn a symptom into an evidenced root cause through the tightest practical
feedback loop.

## Scope

Determine whether the user requested diagnosis only or also authorized a fix.
A diagnosis request ends with the cause, evidence, limitations, and recommended
remedy. Modify production code only when fixing is part of the request.

Read repository instructions, applicable ADRs, domain context, and any engineering
authority explicitly selected by the repository or user. Redact secrets from
commands, output, logs, traces, screenshots, and saved artifacts.

## Workflow

1. **Build a signal.** Create one command or repeatable procedure that exercises
   the reported behavior and can distinguish failure from success. Read
   [feedback-loop patterns](references/feedback-loops.md) when the signal is not
   obvious.
2. **Reproduce and minimize.** Confirm the signal matches the user's exact
   symptom, then remove inputs, setup, callers, and configuration one at a time
   while it remains red. For intermittent failures, improve and measure the
   reproduction rate rather than demanding certainty.
3. **Form hypotheses.** Produce three to five ranked, falsifiable explanations.
   State the observation each predicts. Share the compact ranking with the user,
   but continue with the best-supported order when they are unavailable.
4. **Probe deliberately.** Change one variable at a time. Prefer debugger or
   runtime inspection, then narrowly targeted logs. Give temporary
   instrumentation a unique searchable marker.
5. **Prove the cause.** Show which observation confirms the winning hypothesis
   and which evidence rules out meaningful alternatives. Distinguish direct
   evidence from inference.
6. **Stop or fix according to scope.** For diagnosis-only work, report the cause
   without implementing. When a fix is authorized, turn the minimized case into
   a failing regression test at a valid behavioral seam, apply the narrow fix,
   and rerun both the regression test and original signal.
7. **Clean up.** Remove temporary instrumentation and throwaway artifacts created
   for this diagnosis unless the user or repository convention requires
   preserving them. Report any missing test seam as an architectural limitation
   rather than adding a false confidence test.

## When a Runnable Loop Is Impossible

Static analysis, types, traces, logs, or source history may still prove a cause.
Use them when they make hypotheses falsifiable, and state that the result lacks
a live reproduction. Otherwise, stop after listing what was tried and request
the smallest missing access, redacted artifact, or instrumentation permission.

## Completion

- The reported symptom, not a nearby failure, has been explained.
- The root cause is tied to evidence and important alternatives are addressed.
- An authorized fix passes both the regression test and original signal.
- Temporary diagnostics are removed and no secret appears in the handoff.
