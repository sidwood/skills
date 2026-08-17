---
name: migrate-to-shoehorn
description: Use when the user invokes migrate-to-shoehorn or explicitly asks to migrate TypeScript test fixtures to @total-typescript/shoehorn.
license: LICENSE
disable-model-invocation: true
---

# Migrate to Shoehorn

Replace unsafe TypeScript test-fixture assertions with explicit Shoehorn
primitives while preserving each test's runtime data.

## Workflow

1. Scope the migration to TypeScript test files and inspect the repository's
   package manager, test commands, type-check command, and import conventions.
   Finish with a concrete candidate file list.
2. Find fixture assertions with `rg`, including ordinary `as Type` and
   deliberate `as unknown as Type` patterns. Inspect every match because not
   every assertion represents partial test data.
3. Add `@total-typescript/shoehorn` as a development dependency using the
   repository's existing package manager, unless it is already present.
4. Replace only test-fixture assertions using the matching primitive:

   | Existing intent | Replacement |
   | --- | --- |
   | Incomplete but compatible object | `fromPartial(value)` |
   | Deliberately invalid data for an error path | `fromAny(value)` |
   | Complete object whose exact shape should be checked | `fromExact(value)` |

5. Add or consolidate imports from `@total-typescript/shoehorn` according to
   local style. Finish when migrated files contain no redundant imports.
6. Run the repository's type check, focused tests for changed files, and
   required lint or validation commands. Recheck remaining assertions and
   explain any intentionally retained candidates.

## Rules

- Apply Shoehorn to test code, fixtures, and test helpers, not production code.
- Use `fromAny()` only when invalid runtime data is the point of the test.
- Preserve the exact runtime object; Shoehorn changes its static type but does
  not create omitted fields.
- Keep assertions that express a different TypeScript requirement.
- Complete the migration only when type checking and relevant tests pass.
