---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
license: LICENSE
---

Implement the work described by the user in the spec or tickets.

If the user passes a ticket reference, fetch it from the issue tracker and state its title before starting. If the reference is ambiguous, ask.

Use the `tdd` skill where possible, at pre-agreed seams. Load it through the Skill tool if your harness has one, otherwise by reading its `SKILL.md`.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

Once done, review the work with the `code-review` skill, loaded the same way.

Commit your work to the current branch.
