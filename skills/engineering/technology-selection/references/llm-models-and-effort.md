# Choosing LLM models and effort levels

Use when picking a model, reasoning effort, or speed tier for an agent, a
subagent route, or a scheduled job. A model/effort setting is a technology
choice: recommend it from evidence, never from impression. If no evidence was
checked, say so before giving a view.

## Procedure

1. Read the vendor's per-model effort guidance for the exact model generation.
   Guidance does not carry across generations: an older family's "start at the
   top level for coding" can sit beside a newer family's "sweep from the
   default" in the same document.
2. Read the launch effort-sweep charts as score and cost per attempt at every
   level. Find:
   - the knee, where one more level stops paying for its cost;
   - any level that scores below the one beneath it, since more effort is not
     monotonic (longer runs time out or make out-of-scope edits);
   - the crossover, where a larger model at lower effort beats a smaller model
     at higher effort for equal or lower cost. Past it, escalate to the larger
     model instead of raising effort.
3. Weight the benchmark class that matches the workload: agentic coding
   (terminal and IDE task suites) for coding agents, knowledge-work Elo for
   research and writing. A small model can sit near parity on knowledge work
   and far behind on agentic coding, where extra turns erase its price
   advantage.
4. Add at least one independent result (a third-party effort study or a
   real-repository test) and note its sample size. Cite third-party
   transcriptions of vendor charts as secondary.
5. Recommend one setting per tier with the numbers and links beside each
   claim. State that public benchmarks are not the user's codebase, and offer
   the decisive check: 5-10 of the user's real tasks run across the candidate
   settings.

## Rules

- Keep the cheapest tier to read-only work (lookups, summaries, extraction).
  Small models at default effort sometimes report code changes as done
  without running a check.
- On a subscription, effort spends the usage limit roughly in proportion to
  output tokens; on an API, compare cost per attempt, not price per token.
- Check that a speed tier is offered for the model before configuring it;
  harnesses may refuse the run rather than fall back.
- When correcting an earlier recommendation that the evidence does not
  support, say which call was wrong and why.
- Before adding a premium tier (a model priced above the vendor's flagship),
  compare it head to head with the current flagship on independent boards and
  read the vendor's model-choice guide. A newer flagship generation can beat
  an older premium model at a fraction of the price; then the premium tier
  only burns limits (some plans cap premium models separately).
- Never wire in an unreleased model. Configure a placeholder on the current
  best model, record the swap condition ("replace when its benchmarks beat
  X"), and re-check when it ships.
- Give the highest effort its own verification tier (independent review,
  fact-checking, high-stakes research) when the sweep shows it helps
  knowledge work but not coding, rather than raising the coding tier's
  effort.

## Orchestrator (parent) choice

- The parent picks routes, briefs workers, judges their claims and
  synthesises; a parent weaker than the workers it checks accepts their
  mistakes. Run the flagship there, never a model weaker than the default
  worker tier.
- Set its effort at the knee, not the top: the parent runs on every turn, so
  a level that doubles time per task doubles every reply's latency, which
  matters most on chat and messaging surfaces.
- Vendor measurements to weigh (Anthropic, Claude 5.5 family): an Opus
  orchestrator with Sonnet subagents scored about the same as Opus alone at
  about a third less cost; a premium-model orchestrator or a premium
  "advisor" cost 1.2-2.1x for no measurable gain
  (https://platform.claude.com/docs/en/about-claude/models/optimizing-for-cost-and-intelligence).
