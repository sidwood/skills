# Logic Prototypes

Use a logic prototype when the uncertainty is about business rules, state
transitions, a data shape, or an API surface.

## Shape

- Default to a single, self-contained HTML file when a shareable demonstration
  will help a non-developer explore the model.
- Use the project's language instead when its type system, runtime, or existing
  integration is part of the question.
- Isolate the decision-bearing logic from the demonstration shell. Prefer a
  pure reducer, explicit state machine, pure functions over plain data, or a
  small state-owning module with a clear interface.
- Keep domain logic free of DOM access, button handlers, and display concerns.

## Demonstration

1. Put the question and assumption at the top in domain language.
2. Render the full relevant state after every action as labeled fields rather
   than an unexplained data dump.
3. Provide free-play controls for every meaningful action.
4. Add guided scenarios for the happy path, awkward edge cases, and actions
   that should be rejected.
5. Reset each guided scenario to a known state so it is repeatable.

Keep labels understandable to a domain expert rather than mirroring internal
identifier names. The useful feedback is where observed behavior differs from
what the user expected.

## Completion

- Record the verdict and the cases that produced it.
- Identify the reducer, machine, type shape, or interface worth carrying into
  production work.
- Keep the demonstration shell marked as throwaway.
