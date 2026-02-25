# Bulletproof Frontend — When to Use

**Invoke this skill (`/bulletproof-frontend`) before writing or modifying any CSS, HTML, or Blade template code.** Don't wait to be asked — if the task touches frontend, load the skill first.

## Trigger Conditions

- Writing new CSS rules or components
- Modifying existing stylesheets (`resources/css/`)
- Editing Blade templates (`resources/views/`)
- Adding or changing link styles, including `:visited`, `:hover`, `:focus` states
- Toggling element visibility and measuring dimensions afterward
- Reviewing frontend code for regressions
- Refactoring Tailwind utility classes to semantic CSS

## Common Pitfalls

These have caused real regressions in this project:

- **Adding classes to `<a>` tags** breaks `:not([class])` catch-all selectors — always add explicit `:visited` rules (reference.md #6)
- **Measuring DOM after unhiding** — `getBoundingClientRect()` returns 0 without a forced reflow (reference.md #7)
- **ID selectors on shared components** — `#id` rules in one stylesheet silently override `.class` rules in all others. Never use ID selectors for components that appear on multiple pages (css-architecture.md, Specificity Pitfalls)
- **Duplicate component styling** — style shared components in one place with class selectors; don't split across page-specific files with conflicting approaches (css-architecture.md, One Component One Source)
