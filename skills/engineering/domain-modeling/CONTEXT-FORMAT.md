# CONTEXT.md Format

`CONTEXT.md` is a glossary of the project's domain language. It gives humans
and agents the same words for the same concepts.

## Template

```markdown
# Domain Context

## Language

**Order**:
A customer's request to purchase one or more items.
_Avoid_: Purchase, transaction

**Invoice**:
A financial document generated after fulfillment.
_Avoid_: Bill, receipt

**Customer**:
A person or organization that places orders.
_Avoid_: Client, buyer, account
```

## Rules

- Pick the best term and list competing words under `_Avoid_`.
- Keep definitions to one or two sentences and define what a concept is.
- Include only domain-specific terms, not general programming concepts.
- Group terms under subheadings when natural clusters emerge.
- Keep implementation details, plans, and decisions out of the glossary.

## Multiple contexts

For a genuinely large repository with distinct domain contexts, place a
`CONTEXT.md` in each context and add a root `CONTEXT-MAP.md`:

```markdown
# Context Map

## Contexts

- [Ordering](./src/ordering/CONTEXT.md): receives and tracks customer orders
- [Billing](./src/billing/CONTEXT.md): generates invoices and processes payments

## Relationships

- Ordering emits `OrderPlaced`; Billing consumes it.
```

Do not create multiple contexts merely because the repository has multiple
directories or packages.
