# HTML Report

Render the architecture review as one self-contained HTML file in the operating
system's temporary directory. Tailwind and Mermaid may be loaded from CDNs.

## Structure

- Header: repository name, date, and a compact diagram legend.
- Candidate cards: one per deepening opportunity.
- Top recommendation: one candidate and one sentence explaining why.

Each candidate card contains:

- A short title naming the proposed deepening.
- A recommendation-strength badge and dependency-category badge.
- A monospaced file list.
- Side-by-side before and after diagrams.
- One sentence each for the problem and direction.
- Short wins expressed through locality, leverage, and testability.
- An ADR or repository-guidance warning when applicable.

## Diagram choices

- Use Mermaid flowcharts or sequences for dependencies and call flow.
- Use hand-built boxes and arrows when showing internals absorbed by one deep
  module.
- Use stacked bands for excessive layering.
- Use differently sized interface and implementation rectangles to show depth.
- Use a collapsed call graph to show behavior moving behind an interface.

Keep diagrams compact enough to compare without vertical scrolling. Vary the
diagram type to fit the evidence rather than forcing every candidate into one
template.

## Style

- Favor an editorial layout with generous whitespace.
- Use color sparingly: one accent, red for leakage, and amber for warnings.
- Keep prose concise and make diagrams carry the explanation.
- Use the `codebase-design` vocabulary for architectural concepts while
  preserving the repository's exact domain and framework terms.
- Prefer concrete claims such as “Pricing rules leak into three callers” over
  generic claims such as “This would be cleaner.”

The report is static apart from Mermaid rendering. Include no application logic
or unnecessary interaction.
