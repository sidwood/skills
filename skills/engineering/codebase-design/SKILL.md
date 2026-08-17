---
name: codebase-design
description: Use when designing or improving a module interface, finding deepening opportunities, deciding where a seam belongs, or making code more testable or easier for agents to navigate.
---

# Codebase Design

Design deep modules: substantial behavior behind a small interface at a clean
seam. Optimize for leverage for callers, locality for maintainers, and
testability through stable behavior.

## Engineering authority

Before making structural recommendations:

1. Read repository instructions, ADRs, and any engineering corpus they
   explicitly reference. When the current repository contains that corpus,
   read the applicable pages locally.
2. Identify any engineering-knowledge provider selected by the repository or
   current harness context. This may be a local corpus, a companion knowledge
   skill, or an MCP service such as Surface or Brain Cylinder. Use its documented
   discovery and provenance process; never guess tool names or schemas.
3. Ground only the architecture, dependency, lifecycle, state-flow, and testing
   decisions that the task could affect.
4. On a knowledge **gap**, use repository evidence and engineering judgment for
   the unresolved decision and identify it as judgment. On a selected
   provider's **failure**, report the failed grounding and pause any
   recommendation that could contradict the missing guidance.

Never choose a provider merely because it is connected. Do not infer work or
personal context from a machine name or filesystem path. When multiple providers
are available, follow the repository's explicit selection; if it supplies none,
ask which knowledge domain applies before querying. Never combine providers
unless the user explicitly requests it.

When no provider or external corpus is selected, continue from repository
instructions, ADRs, code evidence, and engineering judgment. Do not require
external grounding for a purely local interface question that cannot be
affected by broader conventions.

Treat the resulting guidance as constraints. Use its established terms where
they are more precise; framework roles such as controller, service, repository,
API, layer, and boundary retain their defined meanings.

## Glossary

Use this vocabulary when discussing the corresponding architectural concept:

- **Module**: anything with an interface and an implementation, from a function
  to a package or tier-spanning slice.
- **Interface**: everything callers must know to use a module correctly,
  including types, invariants, ordering, errors, configuration, and performance.
- **Implementation**: the behavior hidden inside a module.
- **Depth**: leverage at the interface. A deep module offers substantial
  behavior through a small interface; a shallow module's interface approaches
  the complexity of its implementation.
- **Seam**: a place where behavior can be changed without editing the caller.
- **Adapter**: a concrete participant that satisfies an interface at a seam.
- **Leverage**: capability callers receive per unit of interface they learn.
- **Locality**: change, bugs, knowledge, and verification concentrated in one
  place.

Do not replace a repository's precise domain or framework vocabulary merely to
use this glossary. A NestJS service remains a service; an HTTP API remains an
API; and a documented module boundary remains a boundary.

An architectural interface is not necessarily a language-level `interface`.
Qualify the former as a **module interface** when the distinction matters. Keep
the repository's conventions for TypeScript interface names, injection tokens,
abstract-class ports, and other concrete constructs.

## Principles

- **Depth belongs to the interface.** Internal composition does not make a
  module shallow when callers see a small, stable surface.
- **Apply the deletion test.** If deleting a module makes complexity vanish, it
  was likely pass-through indirection. If the complexity spreads into callers,
  the module was providing locality.
- **Treat the interface as a primary test surface.** Test behavior through the
  most stable seam that diagnoses failures well, while retaining focused unit
  or layer tests required by repository guidance.
- **Require evidence for a seam.** Multiple production implementations are
  evidence, but so are independent volatility, multiple transports, or a test
  substitute that materially enables important coverage.
- **Accept dependencies explicitly.** Prefer repository-standard dependency
  injection or parameters over constructing external dependencies deep inside
  behavior.
- **Make effects observable.** Return useful results and expose consequential
  side effects through explicit collaborators or contracts.

## Evaluating depth

Ask:

- Can callers learn fewer operations or parameters?
- Can invariants and ordering constraints move behind the interface?
- Does the proposed seam reflect demonstrated variation or isolation needs?
- Would tests survive an internal refactor?
- Does the design preserve repository-enforced dependency direction?

For a concrete deepening, read [DEEPENING.md](DEEPENING.md). For alternative
interfaces, read [DESIGN-IT-TWICE.md](DESIGN-IT-TWICE.md).
