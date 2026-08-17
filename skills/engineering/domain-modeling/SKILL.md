---
name: domain-modeling
description: Build and sharpen a project's domain model. Use when discussing codebase terminology, writing or editing a CONTEXT.md, or recording or editing an ADR.
---

# Domain Modeling

Actively build and sharpen the project's domain model while designing. Challenge
terms, invent edge-case scenarios, and update the glossary and decisions as they
crystallize. Merely reading `CONTEXT.md` for vocabulary does not invoke this
skill; use it when changing the model.

## File structure

Most repositories have a single context:

```text
/
├── CONTEXT.md
├── docs/
│   └── adrs/
│       ├── 0001-event-sourced-orders.md
│       └── 0002-postgres-for-write-model.md
└── src/
```

If a root `CONTEXT-MAP.md` exists, it identifies multiple contexts and points to
their glossaries and context-specific ADRs.

First locate any repository-owned domain-language and decision-record
conventions. Preserve their names, locations, formats, lifecycle, and validation
workflow. If competing sources claim authority, surface the conflict instead of
choosing one or creating another.

Create files only when there is something to record. Create `CONTEXT.md` when
the first term is resolved. When the repository has no ADR convention, create
`docs/adrs/` only when the first ADR is needed and use
[ADR-FORMAT.md](ADR-FORMAT.md) as the personal default.

## During the session

### Challenge the glossary

Call out conflicts with `CONTEXT.md` immediately. When language is vague or
overloaded, recommend one precise canonical term.

### Test concrete scenarios

Invent edge cases that force precise distinctions between concepts. When the
user describes behavior, compare it with the code and surface contradictions.

### Update the glossary inline

Record a resolved term immediately using
[CONTEXT-FORMAT.md](CONTEXT-FORMAT.md). `CONTEXT.md` is a domain glossary, not a
specification, scratchpad, or record of implementation details.

### Offer ADRs sparingly

Offer an ADR only when the decision is all three:

1. **Hard to reverse**: changing it later would be costly.
2. **Surprising without context**: a future reader would question it.
3. **A real tradeoff**: meaningful alternatives existed.

If any condition is absent, skip the ADR. Use [ADR-FORMAT.md](ADR-FORMAT.md).
