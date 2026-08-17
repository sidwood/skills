# Code-Smell Baseline

Use these as heuristics, never as automatic violations. Suppress a smell when
documented repository guidance endorses the design, and skip anything tooling
already enforces.

- **Mysterious name:** a symbol does not reveal what it represents. Rename it or
  clarify the underlying concept.
- **Duplicated code:** the same logic shape appears in multiple changed places.
  Consolidate the shared decision when doing so improves locality.
- **Feature envy:** behavior reaches into another object's data more than its
  own. Consider moving the behavior nearer the data.
- **Data clump:** the same fields or parameters repeatedly travel together.
  Consider naming the concept they form.
- **Primitive obsession:** a primitive stands in for a domain concept with
  invariants or behavior. Consider a domain type when it would reduce caller
  knowledge.
- **Repeated conditionals:** the same switch or conditional dispatch recurs.
  Consider centralizing the decision.
- **Shotgun surgery:** one logical change requires scattered edits. Consider a
  module that gathers the changing knowledge.
- **Divergent change:** one module changes for several unrelated reasons.
  Consider separating those responsibilities.
- **Speculative generality:** abstractions or extension points serve no current
  requirement. Remove them until evidence creates a need.
- **Message chain:** callers navigate through a long object chain. Consider
  hiding that navigation behind the owning module.
- **Middle man:** a module mostly delegates without hiding meaningful knowledge.
  Apply the deletion test before retaining it.
- **Refused bequest:** a subtype ignores much of the inherited contract.
  Composition may express the relationship more honestly.

Name the possible smell, quote the relevant change, and explain the concrete
maintenance or correctness cost. Do not report a smell based on shape alone.
