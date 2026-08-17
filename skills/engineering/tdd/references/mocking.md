# Mocking

Repository testing guidance overrides these defaults.

## Default Boundary

Prefer real internal collaborators and substitute dependencies at genuine system
boundaries such as third-party APIs, time, randomness, filesystem access, or
independently volatile infrastructure. Use the repository's test database and
isolation conventions when testing persistence.

Mocking is not evidence that production needs a new port. Introduce a seam only
when it also improves production design or when repository guidance recognizes
test substitution as a demonstrated need.

## Keep Substitutes Narrow

- Shape the substitute around the operation the application needs.
- Return one explicit result per test rather than embedding conditional behavior
  in a generic mock.
- Assert the caller-visible outcome instead of asserting that the substitute was
  called, unless the interaction is the contract.
- Keep time, randomness, and failure behavior deterministic.

```typescript
const paymentGateway = {
  charge: async () => ({ paymentId: "payment-123", status: "approved" }),
};

const result = await checkout(cart, paymentGateway);

expect(result.status).toBe("confirmed");
```

Prefer a fake, stub, test server, or provider override when it exercises more of
the real contract without making the test slow or unreliable.
