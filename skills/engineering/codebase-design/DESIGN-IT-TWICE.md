# Design It Twice

Use this process when the user wants alternative interfaces for a chosen
module. The first plausible design is unlikely to expose every tradeoff.

## Process

### 1. Frame the problem

Explain the constraints, callers, dependencies, repository rules, and the
behavior that belongs behind the seam. Include a small illustrative sketch only
when it makes a constraint concrete.

### 2. Generate alternatives

Use three or more parallel subagents when available. Give each the same facts
and a different design constraint, such as:

- Minimize the interface to one to three entry points.
- Maximize flexibility for demonstrated use cases.
- Optimize the most common caller.
- Preserve an existing framework or deployment seam.

Require each alternative to show:

1. The complete interface, including invariants, ordering, and errors.
2. A realistic usage example.
3. What the implementation hides.
4. Its dependency and adapter strategy.
5. Tradeoffs in depth, locality, and seam placement.

### 3. Compare and recommend

Present the designs sequentially, then compare them by depth, locality, seam
placement, correct-use ergonomics, and compliance with repository guidance.
Recommend the strongest design or a justified hybrid.
