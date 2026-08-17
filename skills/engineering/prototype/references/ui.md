# UI Prototypes

Use a UI prototype when the uncertainty is about layout, information hierarchy,
or interaction design.

## Choose the Host

- Prefer mounting variants in an existing page so they encounter real
  navigation, data, density, and styling constraints.
- Create a clearly named prototype route only when no suitable host exists.
- Preserve existing data fetching and authorization; swap only the rendered
  subtree being evaluated.

## Build the Variants

1. Default to three variants and cap the set at five.
2. Make variants structurally different: change layout, information hierarchy,
   or the primary affordance rather than only color and copy.
3. Reuse the project's component library and styling system, but avoid a shared
   layout abstraction that forces the variants into the same design.
4. Keep the prototype read-only. Stub mutations unless mutation behavior is the
   question being tested.

## Compare Them

- Make variants switchable on one route through a stable URL parameter such as
  `?variant=A`.
- Add an unmistakable prototype switcher with previous and next controls, the
  current variant name, and keyboard navigation where appropriate.
- Do not intercept keyboard navigation while an input, text area, or editable
  element has focus.
- Ensure the switcher and losing variants cannot ship accidentally; follow the
  framework's development-only convention when one exists.

## Completion

- Record the selected direction and why it won.
- Treat combinations such as "the header from B with the navigation from C" as
  a valid result.
- Rewrite or harden the selected design under production constraints rather
  than promoting prototype code unchanged.
