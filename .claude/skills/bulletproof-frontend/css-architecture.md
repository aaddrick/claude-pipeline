# CSS Architecture Patterns

> **Design Values:** For specific spacing scales, typography sizes, color palettes, and component dimensions, see the `ui-design-fundamentals` skill. This file covers implementation patterns.

## Custom Properties Structure

Organize CSS variables by category. Pull actual values from your design system.

```css
:root {
  /* === SPACING === */
  /* See ui-design-fundamentals/grid-and-spacing.md for 8pt scale */
  --space-xs: 0.25rem;   /* 4px */
  --space-sm: 0.5rem;    /* 8px */
  --space-md: 1rem;      /* 16px */
  --space-lg: 1.5rem;    /* 24px */
  --space-xl: 2rem;      /* 32px */
  --space-2xl: 3rem;     /* 48px */
  --space-3xl: 4rem;     /* 64px */

  /* === TYPOGRAPHY === */
  /* See ui-design-fundamentals/typography.md for type scale */
  --font-sans: system-ui, -apple-system, sans-serif;
  --font-serif: Georgia, serif;
  --font-mono: ui-monospace, monospace;

  --text-xs: 0.75rem;
  --text-sm: 0.875rem;
  --text-base: 1rem;
  --text-lg: 1.125rem;
  --text-xl: 1.25rem;
  --text-2xl: 1.5rem;

  --font-normal: 400;
  --font-medium: 500;
  --font-semibold: 600;
  --font-bold: 700;

  --leading-tight: 1.25;
  --leading-normal: 1.5;
  --leading-relaxed: 1.625;

  /* === COLORS === */
  /* See ui-design-fundamentals/colors.md for palette guidance */
  --color-primary: #3b82f6;
  --color-primary-hover: #2563eb;

  --color-text: #111827;
  --color-text-muted: #6b7280;
  --color-surface: #ffffff;
  --color-border: #e5e7eb;

  --color-error: #dc2626;
  --color-warning: #d97706;
  --color-success: #16a34a;

  /* === BORDERS === */
  --radius-sm: 0.25rem;
  --radius-md: 0.5rem;
  --radius-lg: 0.75rem;
  --radius-full: 9999px;

  /* === SHADOWS === */
  /* See ui-design-fundamentals/shadows-and-depth.md for elevation */
  --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.05);
  --shadow-md: 0 4px 6px rgba(0, 0, 0, 0.1);
  --shadow-lg: 0 10px 15px rgba(0, 0, 0, 0.1);

  /* === TRANSITIONS === */
  --transition-fast: 150ms ease;
  --transition-base: 300ms ease;

  /* === Z-INDEX === */
  --z-dropdown: 100;
  --z-sticky: 200;
  --z-modal-backdrop: 400;
  --z-modal: 500;
  --z-tooltip: 600;
}
```

## Component Pattern (BEM)

```css
/* Block */
.card {
  /* Component-scoped variables for easy overrides */
  --card-padding: var(--space-lg);
  --card-radius: var(--radius-md);
  --card-shadow: var(--shadow-md);

  background: var(--color-surface);
  padding: var(--card-padding);
  border-radius: var(--card-radius);
  box-shadow: var(--card-shadow);
}

/* Modifier */
.card--compact {
  --card-padding: var(--space-md);
}

.card--elevated {
  --card-shadow: var(--shadow-lg);
}

/* Element (child) */
.card__header {
  margin-bottom: var(--space-md);
  padding-bottom: var(--space-md);
  border-bottom: 1px solid var(--color-border);
}

.card__title {
  font-size: var(--text-lg);
  font-weight: var(--font-semibold);
  line-height: var(--leading-tight);
}

.card__body {
  line-height: var(--leading-normal);
}

/* State */
.card.is-loading {
  opacity: 0.6;
  pointer-events: none;
}
```

## Layer Organization

```css
/* Define layer order (lowest to highest priority) */
@layer reset, base, layout, components, utilities;

@layer reset {
  *, *::before, *::after {
    box-sizing: border-box;
    margin: 0;
  }
}

@layer base {
  body {
    font-family: var(--font-sans);
    font-size: var(--text-base);
    line-height: var(--leading-normal);
    color: var(--color-text);
    background: var(--color-surface);
  }

  a {
    color: var(--color-primary);
    text-decoration: none;
  }

  a:hover {
    color: var(--color-primary-hover);
  }
}

@layer layout {
  .container { /* ... */ }
  .grid { /* ... */ }
}

@layer components {
  .card { /* ... */ }
  .btn { /* ... */ }
}

@layer utilities {
  .sr-only { /* ... */ }
  .hidden { display: none; }
}
```

## File Organization

```
resources/css/
├── app.css              # Main entry, imports all
├── base/
│   ├── reset.css        # CSS reset
│   ├── tokens.css       # Custom properties
│   └── typography.css   # Base typography
├── layout/
│   ├── container.css
│   └── grid.css
├── components/
│   ├── button.css
│   ├── card.css
│   ├── form.css
│   └── nav.css
└── utilities/
    └── helpers.css      # sr-only, hidden, etc.
```

## Progressive Enhancement

```css
/* Base experience */
.feature-box {
  padding: var(--space-lg);
  background: var(--color-surface);
  border: 1px solid var(--color-border);
}

/* Enhanced: backdrop blur */
@supports (backdrop-filter: blur(10px)) {
  .feature-box--glass {
    background: rgba(255, 255, 255, 0.8);
    backdrop-filter: blur(10px);
  }
}

/* Enhanced: container queries */
@supports (container-type: inline-size) {
  .card-container {
    container-type: inline-size;
  }

  @container (min-width: 400px) {
    .card { display: flex; }
  }
}

/* Enhanced: :has() selector */
@supports selector(:has(*)) {
  .form:has(:invalid) {
    border-color: var(--color-error);
  }
}
```

## Performance Guidelines

1. **Animate only transform and opacity**
   ```css
   /* Good */
   .card:hover { transform: translateY(-4px); }

   /* Avoid */
   .card:hover { top: -4px; margin-top: -4px; }
   ```

2. **Use will-change sparingly**
   ```css
   /* Only when needed, remove after animation */
   .animating { will-change: transform; }
   ```

3. **Keep selectors simple**
   ```css
   /* Good */
   .nav-link { }

   /* Avoid */
   nav > ul > li > a.nav-link { }
   ```

## Naming Conventions

| Type | Pattern | Example |
|------|---------|---------|
| Block | `.block` | `.card`, `.nav` |
| Element | `.block__element` | `.card__title` |
| Modifier | `.block--modifier` | `.card--featured` |
| State | `.block.is-state` | `.card.is-loading` |
| Utility | `.property-value` | `.text-center` |

## Grid Layout Pitfalls

### Never Use `auto` for Sidebar Columns

`auto` columns shrink to minimum content width, breaking layouts with container-query children.

```css
/* BAD: Sidebar shrinks to ~30px */
.layout {
    grid-template-columns: auto 1fr;
}

/* GOOD: Explicit or bounded width */
.layout {
    grid-template-columns: minmax(10rem, 14rem) 1fr;
}

/* ALSO GOOD: Fixed width */
.layout {
    grid-template-columns: 12rem 1fr;
}
```

### Always Define Mobile Layout

Only defining grid at desktop breakpoints leaves mobile layout implicit and often broken.

```css
/* BAD: Mobile gets implicit 1-column grid with auto sizing */
@media (min-width: 64rem) {
    .layout { grid-template-columns: 12rem 1fr; }
}

/* GOOD: Define both states explicitly */
.layout {
    display: flex;
    flex-direction: column;
    gap: var(--space-lg);
}

@media (min-width: 64rem) {
    .layout {
        display: grid;
        grid-template-columns: minmax(10rem, 14rem) 1fr;
    }
}
```

### Container Queries Need Explicit Column Widths

Children using `container-type: inline-size` need defined container width for `cqi` units.

```css
/* Child uses container query units */
.stat-card {
    container-type: inline-size;
}
.stat-card__value {
    font-size: clamp(4rem, 45cqi, 11rem);  /* 45% of container width */
}

/* Parent grid must provide explicit width, not auto */
.layout {
    grid-template-columns: 12rem 1fr;  /* NOT: auto 1fr */
}
```

### Prevent Grid Blowout

Grid children with wide content can expand the grid. Always set `min-width: 0`:

```css
.layout__main {
    min-width: 0;  /* Allows content to shrink */
    overflow: hidden;  /* Or clip overflow */
}
```

## Specificity Pitfalls

### Never Use ID Selectors for Shared Components

ID selectors (`#id`) have higher specificity than class selectors (`.class`). When the same component appears on multiple pages styled by different CSS files, an ID selector in one file silently overrides class-based rules in all others.

```css
/* BAD: ID selector overrides .class rules everywhere */
#popup {
    max-width: 350px;  /* Wins everywhere — impossible to override with classes */
}

/* GOOD: Class selector — same specificity, predictable cascade */
.popup {
    max-width: 350px;
}
```

### One Component, One Source of Truth

When a component is used across multiple pages, style it in **one place** using class selectors. Don't duplicate styling across page-specific CSS files with conflicting approaches.

```css
/* BAD: Same component styled differently in two files */
/* page-a.css */  #popup { left: var(--x); top: var(--y); }
/* page-b.css */  .popup { transform: translate(var(--x), var(--y)); }

/* GOOD: Shared class rules in one file, page-specific overrides clearly scoped */
/* shared */       .popup { left: var(--x); top: var(--y); }
/* page-specific */ .landing-page .popup { /* only differences */ }
