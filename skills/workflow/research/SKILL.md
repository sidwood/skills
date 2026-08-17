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
   work can continue. Otherwise, research inline.
3. Prefer primary sources: official documentation, specifications, source code,
   standards, papers, and first-party APIs. Use secondary sources to discover
   primary material or to capture clearly attributed perspectives.
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
