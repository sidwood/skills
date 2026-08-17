---
name: to-spec
description: Turn decisions already made in the current conversation into a specification and publish it through the repository's established workflow without conducting a new requirements interview.
disable-model-invocation: true
license: LICENSE
---

# To Spec

Synthesize the decisions already reached into a durable specification.

## Workflow

1. Read the current conversation and inspect the affected code when needed.
   Follow repository instructions, domain vocabulary, ADRs, and any project
   knowledge authority explicitly identified by the repository or user.
2. Preserve settled decisions. Do not restart requirements discovery or ask the
   user to repeat information already available. Mark an essential unresolved
   fact as an open question rather than inventing an answer.
3. Identify the highest stable behavioral seams at which the change can be
   tested. Prefer existing seams and minimize new ones. If these seams were not
   already agreed, present them in one approval checkpoint before publishing.
4. Draft the specification using
   [the specification template](references/specification-template.md). Keep
   volatile file paths and implementation snippets out unless a prototype
   produced a compact snippet that expresses a decision more precisely than
   prose.
5. Publish to the destination explicitly named by the user or established by
   repository instructions. Otherwise, use an existing specifications
   directory, then a GitHub issue when the repository uses GitHub. Do not invent
   workflow labels; apply only labels established by the project. If neither
   destination exists, return the Markdown draft and ask where it should live
   before creating a new convention.
6. Report the published path or issue URL and any open questions recorded in
   the specification.

## Boundary

- Use `to-prd` when requirements still need discovery and interviewing.
- Use this skill when the conversation already contains the decisions and the
  remaining work is synthesis.
