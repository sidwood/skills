---
name: tdd
description: Use when the user requests test-driven development, test-first implementation, red-green-refactor, or an integration-test-led development workflow. Do not invoke merely because a task includes tests.
license: LICENSE
---

# Test-Driven Development

Drive one thin behavior slice through red, green, and refactor before starting
the next.

## Engineering Authority

Read repository instructions, applicable ADRs, and any testing corpus or
engineering provider explicitly selected by the repository or user. Those rules
govern test levels, file layout, databases, harnesses, mocks, and commands. A
connected provider is not authoritative merely because it is available.

## Choose the Behavioral Seam

Test through the most stable public boundary that can observe and diagnose the
behavior. Prefer an existing seam. Do not add a port, dependency-injection seam,
or abstraction solely to make a mock convenient.

Infer the seam from repository guidance, the specification, and existing tests.
Ask the user only when competing seams would materially change architecture,
coverage, or cost.

## Red-Green-Refactor

1. **Red:** select the next narrow behavior, write one test through the chosen
   seam, and run it. Confirm it fails for the missing or incorrect behavior, not
   because the test or environment is broken.
2. **Green:** write only enough production code to satisfy that behavior. Run the
   focused test, then the repository checks needed to catch nearby regressions.
3. **Refactor:** improve names, duplication, interfaces, and locality while the
   suite stays green. Add no new behavior during this step.
4. Repeat with the next tracer-bullet slice, letting each completed cycle inform
   the next test.

For examples of independent expectations and behavior-focused assertions, read
[test quality](references/test-quality.md). When a dependency needs substitution,
read [mocking guidance](references/mocking.md).

## Rules

- Expected values come from a specification, worked example, invariant, or
  known-good literal rather than recomputing the implementation's algorithm.
- Tests assert observable behavior through the selected interface, not private
  methods or incidental call sequences.
- Work vertically: one test, its minimal implementation, and its refactor. Do
  not write an imagined horizontal suite before learning from implementation.
- For a bug, begin with a regression test that reproduces the exact failure at
  the correct seam.
- Keep every cycle green before starting the next behavior.
