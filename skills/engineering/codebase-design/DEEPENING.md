# Deepening

Use these dependency categories when deepening a cluster of shallow modules.
Repository-specific architecture and testing rules remain authoritative.

## Dependency categories

1. **In-process**: pure computation or memory. Consolidate when it improves
   locality and test through the resulting interface.
2. **Local-substitutable**: dependencies with a faithful local stand-in, such as
   an in-memory filesystem or embedded database. Keep the seam internal unless
   repository guidance requires otherwise.
3. **Remote but owned**: a service controlled by the same organization. When a
   seam is demonstrated, define an application-shaped port and use transport
   adapters without leaking transport concerns inward.
4. **True external**: an independently changing third-party system. Isolate it
   behind an application-shaped collaborator when volatility, failure behavior,
   or test setup justifies the seam.

## Seam discipline

- A hypothetical replacement is not evidence for a seam.
- Shape a port around what the application needs, not the technology's surface.
- Keep test-only seams internal when callers do not need them.
- Preserve compile-time or framework boundaries mandated by the repository.

## Testing strategy

- Add behavior tests at the deepened module's stable interface.
- Remove an old test only when the new coverage makes it redundant and failure
  diagnosis remains at least as clear.
- Preserve focused unit, layer, integration, and end-to-end tests when they
  protect distinct behavior or repository guidance requires them.
- Assert observable outcomes rather than incidental internal state.
