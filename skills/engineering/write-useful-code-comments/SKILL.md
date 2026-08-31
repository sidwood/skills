---
name: write-useful-code-comments
description: Use when writing, reviewing, adding, removing, or cleaning up code comments, documentation comments, JSDoc, TSDoc, docstrings, or explanatory inline notes. Do not use for README, guides, or product documentation.
---

# Write Useful Code Comments

Explain context that correct, readable code cannot express.

## Workflow

1. Read declaration without comment. Inventory meaning already conveyed by
   names, types, signatures, structure, and control flow.
2. Identify missing context materially affecting correct use or maintenance:
   invariant, rationale, surprising distinction, external constraint,
   deliberate limit, or intentionally deferred behavior.
3. Improve names, types, or structure first when they can express that context.
4. Add a concise comment only for important context that remains.
5. Delete every comment sentence that paraphrases code.

Done when remaining comments are accurate, durable, and adjacent to the
code they qualify. Confirm by deleting each comment: if the declaration
still communicates the same meaning and constraints, leave it deleted.

## Rules

- Record intentional omissions or deferred rules maintainers could mistake for
  oversights.
- Comment length must remain below the code or concept it clarifies.
- Comments are maintained code: update or remove them when behavior changes.
- Public API docs describe semantic contracts, never restate parameters or
  return types.

## Examples

Keep:

```ts
// A Workspace slug selects a Workspace but never conveys authorization.
```

```python
def is_workspace_action_authorized() -> bool:
    """Coarse role gate; resource-specific eligibility is evaluated separately."""
```

```go
// The token must increase monotonically, but its representation is deliberately
// unspecified.
```

Remove:

```ts
// The ID of the Thought.
readonly thoughtId: ThoughtId;
```

```python
def is_workspace_action_authorized() -> bool:
    """Returns whether the action is authorized."""
```

```go
// AgentRole is the Agent Reader and Agent Contributor roles.
type AgentRole string
```
