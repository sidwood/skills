---
name: research
description: Use when the user asks to investigate a question against authoritative sources, gather documentation or API facts, or capture cited findings for later work.
license: LICENSE
---

# Research

Produce traceable findings grounded in the sources that own the facts.

## Workflow

1. Define the question from the request and current context. Ask only when a
   missing choice would materially change the investigation.
2. When background agents are available, delegate independent reading so other
   work can continue. Start each with a fresh context window and pass it the
   question, steps 3, 4 and 6, and the Rules, which it cannot otherwise see.
   Otherwise, research inline.
3. Prefer primary sources: official documentation, specifications, source code,
   standards, papers, and first-party APIs. Use secondary sources to discover
   primary material or to capture clearly attributed perspectives.
   - When the question is how installed software behaves, read the installed
     source. READMEs drift from code defaults.
   - Also check the live state of the real installs (status commands, logs and
     a live call). A config can look healthy while the running process is
     broken, and validating a plan against a broken baseline gives a wrong
     verdict.
4. Trace each material claim to a source and cite it beside the finding it
   supports. Distinguish source-backed facts from inferences.
5. If the user requested a durable artifact, or an established repository
   workflow requires one, save a single Markdown file where the repository
   keeps research notes. If no convention exists, use `research/<topic>.md` and
   report the path. Otherwise, return the findings directly without changing
   the repository.
6. State unresolved questions, source limitations, and the date when facts are
   time-sensitive.

## Rules

- Follow repository instructions and any identified project knowledge authority.
- Do not treat a connected knowledge provider as authoritative unless the
  repository or user identifies it as relevant.
- Keep quotations short; summarize when exact wording is unnecessary.
- Never fabricate a citation or imply that an inaccessible source was checked.
- Before stating that something does NOT happen, check every code path that
  could do it, including one-time migrations, init and setup steps, hooks and
  background jobs. A guard on one hook is not proof, and negative claims are
  the ones most often wrong.
- When asked to validate a claim, open with the verdict (holds, partly holds,
  or doesn't hold), then cover what holds, what doesn't, and anything already
  broken in the live setup.
