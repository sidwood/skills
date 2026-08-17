# Test Quality

A durable test reads as a behavioral specification and survives internal
refactoring.

## Prefer

- Public interfaces and observable outcomes.
- Test names in repository domain language.
- One coherent behavior per test.
- Whole meaningful results when they make failures easier to diagnose.
- Independent expected values from requirements or worked examples.

```typescript
test("a customer can check out a valid cart", async () => {
  const cart = createCartWith([{ price: 10 }, { price: 5 }]);

  const result = await checkout(cart, approvedPaymentMethod);

  expect(result).toEqual({ status: "confirmed", total: 15 });
});
```

## Avoid

- Tests of private methods or internal collaborator calls.
- Assertions on implementation-specific call counts or ordering unless that
  ordering is itself part of the public contract.
- Verification through a side channel when the public interface can expose the
  result.
- Expected values calculated with the same algorithm as the implementation.
- Snapshots whose size or volatility hides the decision being asserted.

```typescript
test("calculates the cart total", () => {
  const items = [{ price: 10 }, { price: 5 }];
  const expected = items.reduce((sum, item) => sum + item.price, 0);

  expect(calculateTotal(items)).toBe(expected);
});
```

The example is tautological because the assertion repeats the implementation's
likely algorithm. Use the independent literal `15` instead.
