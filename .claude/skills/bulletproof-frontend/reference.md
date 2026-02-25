# Bulletproof Frontend Design Reference

*Based on "Handcrafted CSS: More Bulletproof Web Design" by Dan Cederholm with Ethan Marcotte*

**CSS is king.** This reference covers bulletproof design principles and modern CSS features that eliminate the need for JavaScript and utility frameworks.

---

## Modern CSS Features

These powerful native capabilities reduce JavaScript dependency and make CSS more expressive.

### :has() — Parent/Sibling Selection

```css
/* Style parent based on child */
.card:has(img) { padding-top: 0; }
.form:has(:invalid) { border-color: var(--color-error); }
label:has(input:checked) { background: var(--color-primary-light); }

/* Style based on sibling */
.item:has(+ .item:hover) { opacity: 0.7; }
```

### CSS Nesting

```css
.card {
    padding: var(--space-md);

    & .card__title { font-size: var(--text-lg); }

    &:hover { box-shadow: var(--shadow-lg); }

    @media (min-width: 48rem) { padding: var(--space-lg); }

    &.card--featured { border-left: 4px solid var(--color-primary); }
}
```

### Container Queries

```css
.card-container {
    container-type: inline-size;
    container-name: card;
}

@container card (min-width: 400px) {
    .card { display: flex; gap: var(--space-md); }
}

/* Container query units: cqi, cqb, cqw, cqh */
.title { font-size: clamp(1rem, 5cqi, 2rem); }
```

### Cascade Layers

```css
@layer reset, base, components, utilities;

@layer reset { *, *::before, *::after { box-sizing: border-box; } }
@layer base { body { font-family: var(--font-family); } }
@layer components { .btn { padding: var(--space-sm) var(--space-md); } }
```

### Subgrid

```css
.grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
}

.card {
    display: grid;
    grid-template-rows: subgrid;
    grid-row: span 3;
}
```

### Dynamic Viewport Units

```css
/* dvh/dvw = dynamic, svh/svw = small, lvh/lvw = large */
.hero { min-height: 100dvh; }
.modal { max-height: 100svh; }
```

### Modern Color Functions

```css
:root {
    --brand: oklch(65% 0.25 250);
    --brand-light: color-mix(in oklch, var(--brand) 30%, white);
    --brand-dark: color-mix(in oklch, var(--brand) 70%, black);
    --brand-hover: oklch(from var(--brand) calc(l - 10%) c h);
}
```

### Scroll-Driven Animations

```css
.progress { animation: grow linear; animation-timeline: scroll(root); }
.fade-in { animation: fade linear both; animation-timeline: view(); }
```

### View Transitions

```css
/* Enable for MPA */
@view-transition { navigation: auto; }

/* Custom transition animations */
::view-transition-old(root) { animation: fade-out 0.3s ease-out; }
::view-transition-new(root) { animation: fade-in 0.3s ease-in; }

/* Named transitions for specific elements */
.card__image { view-transition-name: card-image; }
::view-transition-group(card-image) { animation-duration: 0.4s; }
```

```javascript
// SPA: Trigger transition for DOM updates
document.startViewTransition(() => updateDOM());
```

### Typography Enhancements

```css
h1, h2, h3 { text-wrap: balance; }
p { text-wrap: pretty; }
.article::first-letter { initial-letter: 3; }
```

### @supports for Progressive Enhancement

```css
@supports (grid-template-rows: subgrid) { /* enhanced styles */ }
@supports selector(:has(*)) { /* :has() styles */ }
```

---

## Chapter 1: Flexibility First — "What Happens If...?"

### The Bulletproof Mindset
Always ask these questions before finalizing any CSS:
- What happens if there's more (or less) content?
- What happens if text size increases/decreases?
- What happens if content is translated to a longer language?
- What happens if the container width changes?

### Float vs. Absolute Positioning

**Use Float when:**
- Content length varies
- Elements should be aware of each other
- You need elements to wrap naturally

**Use Absolute Positioning when:**
- Element has fixed/known dimensions (e.g., images, icons)
- You intentionally want overlap
- Positioning relative to a container edge

```css
/* AVOID: Absolute positioning with variable content */
.price {
  position: absolute;
  top: 7px;
  right: 7px; /* Will overlap if title is long */
}

/* BETTER: Float for flexible content */
.price {
  float: right;
}
.title {
  float: left;
  width: 75%; /* Prevents collision */
}
```

### Block-Level Clickable Areas (Fitts' Law)
Make entire rows clickable, not just text links:

```css
ul.list li a {
  display: block;
  padding: 7px;
  border-bottom: 1px solid #ccc;
}
```

### Containing Floats with Overflow
```css
.container {
  overflow: hidden; /* Self-clears floats */
}
```

---

## Chapter 2: Rounded Corners with border-radius

### Progressive Enhancement Pattern
```css
.box {
  /* Fallback for older browsers */
  background: #e2e1d4;

  /* Modern browsers get rounded corners */
  border-radius: 8px;
}
```

### Rounding Specific Corners
```css
.box {
  border-top-left-radius: 8px;
  border-top-right-radius: 8px;
  border-bottom-left-radius: 0;
  border-bottom-right-radius: 0;
}
```

### Rounded Form Elements
```css
input, textarea {
  padding: 5px;
  border: none;
  border-bottom: 1px solid #fff;
  border-right: 1px solid #fff;
  background: #e2e1d7 url(input-shadow.gif) repeat-x top left;
  border-radius: 5px;
}

input:focus, textarea:focus {
  background: #fff;
}
```

### Glossy Button with Rounded Corners
```css
.button {
  padding: 5px 14px;
  color: #fff;
  border: 1px solid #3792b3;
  background: #3792b3 url(glass-btn.png) repeat-x 0 50%;
  border-radius: 14px;
}

.button:hover {
  background-color: #a14141;
  border-color: #a14141;
}
```

---

## Chapter 3: Flexible Color with RGBA

### RGBA vs. Opacity

**opacity** affects the entire element and its children:
```css
/* BAD: Text becomes transparent too */
.overlay {
  background: #333;
  opacity: 0.7;
}
```

**RGBA** affects only the color specified:
```css
/* GOOD: Only background is transparent */
.overlay {
  background: rgba(0, 0, 0, 0.7);
}
```

### Fallback Pattern for RGBA
```css
.box {
  background: #333;                    /* Fallback */
  background: rgba(0, 0, 0, 0.7);      /* Modern browsers */
}
```

### RGBA for Hover States
```css
a:link, a:visited {
  color: #3792b3;
}

a:hover {
  color: rgba(55, 146, 179, 0.65); /* Same color, reduced opacity */
}
```

### RGBA for Text Blending
```css
/* Blend text into background */
.subtitle {
  color: rgba(0, 0, 0, 0.65); /* Semi-transparent black */
}
```

### Semi-Transparent Overlays
```css
.photo-overlay {
  position: absolute;
  bottom: 0;
  left: 0;
  width: 100%;
  padding: 10px;
  background: #333;                    /* Fallback */
  background: rgba(0, 0, 0, 0.7);      /* Overlay */
  color: #fff;
}
```

---

## Chapter 4: Progressive Enrichment Philosophy

### The Core Principle
**Websites don't need to look exactly the same in every browser.**

They need to be:
- Functional
- Readable
- Properly laid out

Visual enhancements (rounded corners, shadows, transparency) are *rewards* for capable browsers, not requirements.

### Decision Framework
1. **Check your stats** — What browsers are your users actually using?
2. **Identify critical vs. decorative** — Layout and readability are critical; visual polish is decorative
3. **Provide fallbacks** — Solid colors, square corners work fine as fallbacks

### text-shadow
```css
h1 {
  text-shadow: 2px 2px 4px rgba(0, 0, 0, 0.7);
  /* offset-x offset-y blur-radius color */
}

/* Inset/bevel effect */
.button {
  text-shadow: 0 1px 0 rgba(255, 255, 255, 0.8);
}
```

### box-shadow
```css
.card {
  box-shadow: 2px 2px 4px rgba(0, 0, 0, 0.3);
  /* offset-x offset-y blur-radius color */
}
```

### CSS Transitions
```css
a {
  color: #3792b3;
  transition: color 0.2s linear;
}

a:hover {
  color: rgba(55, 146, 179, 0.65);
}

/* Background fade */
.nav-item {
  background: transparent;
  transition: background-color 0.4s linear;
}

.nav-item:hover {
  background: rgba(0, 0, 0, 0.15);
}
```

---

## Chapter 5: Modular Float Management

### The .group Pattern (Modern Clearfix)
```css
/* Apply to any container with floated children */
.group::after {
  content: "";
  display: table;
  clear: both;
}
```

### Why .group instead of .clearfix
- **Semantic**: "group" describes what the container IS
- **Professional**: Doesn't alarm non-developers viewing markup
- **Reusable**: Apply anywhere floats need containment

### Usage
```html
<div class="header group">
  <div class="logo">...</div>
  <nav class="nav">...</nav>
</div>
```

### Modern Alternative: Flexbox/Grid
For new projects, prefer flexbox or grid over floats:

```css
/* Flexbox */
.header {
  display: flex;
  justify-content: space-between;
  align-items: center;
}

/* Grid */
.layout {
  display: grid;
  grid-template-columns: 1fr 300px;
  gap: 20px;
}
```

---

## Chapter 6: Fluid Grids (by Ethan Marcotte)

### The Formula
```
target ÷ context = result
```

**For font sizes:**
- target: desired size in pixels
- context: parent's font size in pixels
- result: em value

**For widths:**
- target: desired width in pixels
- context: container width in pixels
- result: percentage value

### Example: Font Sizing
```css
/* Context: body font-size is 16px (100%) */
body {
  font-size: 100%; /* 16px default */
}

/* 20px / 16px = 1.25em */
h2 {
  font-size: 1.25em;
}

/* Nested context changes! */
/* If h2 is 20px, and we want 24px ampersand: */
/* 24px / 20px = 1.2em */
h2 .amp {
  font-size: 1.2em;
}
```

### Example: Fluid Widths
```css
/* Container is 1000px, main content is 730px */
/* 730 / 1000 = 0.73 = 73% */

#wrap {
  max-width: 62.5em; /* 1000px / 16px */
  margin: 0 auto;
}

.main {
  float: left;
  width: 73%;
}

.sidebar {
  float: right;
  width: 25%; /* 250 / 1000 = 0.25 */
}
```

### Fluid Images
```css
img {
  max-width: 100%;
  height: auto;
}
```

### Responsive Breakpoints
```css
/* Mobile first */
.main {
  width: 100%;
}

@media (min-width: 768px) {
  .main {
    float: left;
    width: 73%;
  }

  .sidebar {
    float: right;
    width: 25%;
  }
}
```

---

## Chapter 7: Craftsmanship Details

### Typography: Best Available Ampersand
```css
.amp {
  font-family: Baskerville, "Goudy Old Style", Palatino,
               "Book Antiqua", Georgia, serif;
  font-style: italic;
}
```

### @font-face (Web Fonts)
```css
@font-face {
  font-family: "Custom Font";
  src: url("fonts/custom.woff2") format("woff2"),
       url("fonts/custom.woff") format("woff");
  font-weight: normal;
  font-style: normal;
  font-display: swap;
}

body {
  font-family: "Custom Font", Georgia, serif;
}
```

### Parallax Effect (Lazy Version)
```css
/* Negative percentage makes background move opposite to resize direction */
.header {
  background: url(clouds.png) repeat-x -80% 0;
}
```

### :last-child for List Styling
```css
ul li {
  padding-bottom: 1em;
  border-bottom: 1px solid #ccc;
}

ul li:last-child {
  padding-bottom: 0;
  border-bottom: none;
}
```

---

## Modern Additions (2024+)

### CSS Custom Properties (Variables)
```css
:root {
  --primary-color: #3792b3;
  --primary-hover: rgba(55, 146, 179, 0.65);
  --spacing-unit: 1rem;
  --border-radius: 8px;
}

.button {
  background: var(--primary-color);
  border-radius: var(--border-radius);
  padding: var(--spacing-unit);
}

.button:hover {
  background: var(--primary-hover);
}
```

### Container Queries
```css
.card-container {
  container-type: inline-size;
}

@container (min-width: 400px) {
  .card {
    display: flex;
    gap: 1rem;
  }
}
```

### Modern Layout with Grid
```css
.page-layout {
  display: grid;
  grid-template-columns: 1fr;
  gap: 2rem;
}

@media (min-width: 768px) {
  .page-layout {
    grid-template-columns: 1fr 300px;
  }
}
```

### Logical Properties (RTL Support)
```css
/* Instead of margin-left/right */
.element {
  margin-inline-start: 1rem;
  padding-block: 1rem;
}
```

### prefers-reduced-motion
```css
@media (prefers-reduced-motion: reduce) {
  * {
    animation-duration: 0.01ms !important;
    transition-duration: 0.01ms !important;
  }
}
```

### prefers-color-scheme (Dark Mode)
```css
:root {
  --bg-color: #fff;
  --text-color: #333;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg-color: #1a1a1a;
    --text-color: #e0e0e0;
  }
}
```

---

## Anti-Patterns to Avoid

### 1. Fixed Heights on Text Containers
```css
/* BAD */
.box { height: 100px; } /* Text will overflow */

/* GOOD */
.box { min-height: 100px; }
```

### 2. Pixel-Based Everything
```css
/* BAD */
.text { font-size: 14px; margin: 10px; }

/* GOOD */
.text { font-size: 0.875rem; margin: 0.625rem; }
```

### 3. Absolute Positioning for Layout
```css
/* BAD: Fragile, breaks with content changes */
.sidebar { position: absolute; right: 0; width: 200px; }

/* GOOD: Flexible layout */
.container { display: flex; }
.sidebar { flex: 0 0 200px; }
```

### 4. Over-Specificity
```css
/* BAD */
div#header ul.nav li.active a.link { ... }

/* GOOD */
.nav-link.active { ... }
```

### 5. Magic Numbers
```css
/* BAD */
.element { margin-top: 37px; } /* Why 37? */

/* GOOD */
.element { margin-top: var(--spacing-lg); }
```

### 6. Adding Classes to `<a>` Tags Without `:visited` Rules
When you add a class to an anchor, catch-all selectors like `.dark a:visited:not([class])` stop matching. Always add explicit `:visited` rules alongside `:link`/`:hover` for any classed link.
```css
/* BAD: Relies on catch-all — breaks when class is added */
.dark a:visited:not([class]) { color: var(--color-primary-300); }

/* GOOD: Explicit :visited on the classed link */
.link--custom { color: var(--color-primary); }
.link--custom:visited { color: var(--color-primary); }
.dark .link--custom:visited { color: var(--color-primary-400); }
```

### 7. Measuring DOM Elements Immediately After Showing Them
After removing `hidden` or changing `display`, the browser hasn't laid out the element yet. `getBoundingClientRect()` returns stale (often zero) dimensions. Force a reflow first.
```javascript
/* BAD: Dimensions are 0 */
element.classList.remove('hidden');
const rect = element.getBoundingClientRect(); // width=0, height=0

/* GOOD: Force reflow before measuring */
element.classList.remove('hidden');
element.offsetHeight; // triggers synchronous layout
const rect = element.getBoundingClientRect(); // accurate
```

---

## Testing Checklist

Before finalizing any component:

- [ ] **Text size test**: Increase browser text size 200% — does layout hold?
- [ ] **Content length test**: Add extra-long content — any overlap or breakage?
- [ ] **Window resize test**: Resize browser from 320px to 1920px+
- [ ] **Browser test**: Check in Chrome, Firefox, Safari (at minimum)
- [ ] **Mobile test**: Test on actual devices or DevTools emulation
- [ ] **Accessibility test**: Keyboard navigation, screen reader, color contrast
- [ ] **Reduced motion test**: Verify animations respect prefers-reduced-motion
- [ ] **Dark mode test**: If applicable, verify dark mode appearance
- [ ] **No utility classes**: All Tailwind refactored to semantic CSS
- [ ] **CSS custom properties**: Consistent use of design tokens

---

## Refactoring Tailwind to CSS

**CSS is king.** When you encounter Tailwind utility classes, refactor them to semantic CSS.

### The Process

1. **Identify** — What UI element is this?
2. **Name** — What does it DO, not how it looks
3. **Extract** — Move styles to a CSS file
4. **Replace** — Swap utility classes for semantic class

### Common Translations

| Tailwind | CSS |
|----------|-----|
| `flex` | `display: flex` |
| `items-center` | `align-items: center` |
| `justify-between` | `justify-content: space-between` |
| `p-4` | `padding: var(--space-md)` |
| `px-4` | `padding-inline: var(--space-md)` |
| `py-2` | `padding-block: var(--space-sm)` |
| `m-4` | `margin: var(--space-md)` |
| `mt-4` | `margin-top: var(--space-md)` |
| `gap-4` | `gap: var(--space-md)` |
| `w-full` | `width: 100%` |
| `max-w-lg` | `max-width: var(--max-width-lg)` |
| `text-lg` | `font-size: var(--text-lg)` |
| `text-sm` | `font-size: var(--text-sm)` |
| `font-bold` | `font-weight: var(--font-bold)` |
| `font-semibold` | `font-weight: var(--font-semibold)` |
| `text-gray-900` | `color: var(--color-text)` |
| `text-gray-500` | `color: var(--color-text-muted)` |
| `bg-white` | `background: var(--color-surface)` |
| `bg-gray-100` | `background: var(--color-surface-alt)` |
| `border` | `border: 1px solid var(--color-border)` |
| `border-gray-200` | `border-color: var(--color-border)` |
| `rounded` | `border-radius: var(--radius-sm)` |
| `rounded-lg` | `border-radius: var(--radius-lg)` |
| `rounded-full` | `border-radius: var(--radius-full)` |
| `shadow` | `box-shadow: var(--shadow-sm)` |
| `shadow-md` | `box-shadow: var(--shadow-md)` |
| `shadow-lg` | `box-shadow: var(--shadow-lg)` |
| `hover:bg-gray-100` | `.element:hover { background: var(--color-hover) }` |
| `focus:ring-2` | `:focus-visible { box-shadow: 0 0 0 2px var(--color-primary) }` |
| `dark:bg-gray-800` | `@media (prefers-color-scheme: dark) { ... }` |
| `sm:flex` | `@media (min-width: 40rem) { display: flex }` |
| `md:grid-cols-2` | `@media (min-width: 48rem) { grid-template-columns: repeat(2, 1fr) }` |
| `lg:px-8` | `@media (min-width: 64rem) { padding-inline: var(--space-xl) }` |

### Design Tokens

Replace Tailwind's config with CSS custom properties:

```css
:root {
    /* Spacing (replaces p-1 through p-12, m-1 through m-12, etc.) */
    --space-xs: 0.25rem;   /* 4px - replaces -1 */
    --space-sm: 0.5rem;    /* 8px - replaces -2 */
    --space-md: 1rem;      /* 16px - replaces -4 */
    --space-lg: 1.5rem;    /* 24px - replaces -6 */
    --space-xl: 2rem;      /* 32px - replaces -8 */
    --space-2xl: 3rem;     /* 48px - replaces -12 */

    /* Typography */
    --text-xs: 0.75rem;
    --text-sm: 0.875rem;
    --text-base: 1rem;
    --text-lg: 1.125rem;
    --text-xl: 1.25rem;
    --text-2xl: 1.5rem;
    --text-3xl: 1.875rem;

    --font-normal: 400;
    --font-medium: 500;
    --font-semibold: 600;
    --font-bold: 700;

    /* Colors */
    --color-primary: #3b82f6;
    --color-primary-dark: #2563eb;
    --color-primary-light: #eff6ff;

    --color-text: #111827;
    --color-text-muted: #6b7280;
    --color-surface: #ffffff;
    --color-surface-alt: #f9fafb;
    --color-border: #e5e7eb;
    --color-hover: #f3f4f6;

    /* Semantic colors */
    --color-success: #22c55e;
    --color-warning: #f59e0b;
    --color-error: #ef4444;
    --color-info: #3b82f6;

    /* Shadows */
    --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.05);
    --shadow-md: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
    --shadow-lg: 0 10px 15px -3px rgba(0, 0, 0, 0.1);

    /* Radii */
    --radius-sm: 0.25rem;
    --radius-md: 0.375rem;
    --radius-lg: 0.5rem;
    --radius-xl: 0.75rem;
    --radius-full: 9999px;

    /* Breakpoints (for reference in media queries) */
    /* sm: 40rem (640px), md: 48rem (768px), lg: 64rem (1024px), xl: 80rem (1280px) */
}

/* Dark mode */
@media (prefers-color-scheme: dark) {
    :root {
        --color-text: #f9fafb;
        --color-text-muted: #9ca3af;
        --color-surface: #111827;
        --color-surface-alt: #1f2937;
        --color-border: #374151;
        --color-hover: #1f2937;
    }
}
```

### Before/After Example

```html
<!-- BEFORE: Tailwind chaos -->
<div class="flex items-center justify-between p-4 mb-4 bg-white rounded-lg shadow-md border border-gray-200 hover:shadow-lg transition-shadow">
    <div class="flex items-center gap-3">
        <img class="w-10 h-10 rounded-full" src="avatar.jpg" alt="">
        <div>
            <h3 class="text-lg font-semibold text-gray-900">User Name</h3>
            <p class="text-sm text-gray-500">user@example.com</p>
        </div>
    </div>
    <button class="px-4 py-2 bg-blue-500 text-white rounded-lg hover:bg-blue-600 focus:ring-2 focus:ring-blue-500 focus:ring-offset-2">
        Follow
    </button>
</div>

<!-- AFTER: Semantic CSS -->
<div class="user-card">
    <div class="user-card__info">
        <img class="user-card__avatar" src="avatar.jpg" alt="">
        <div>
            <h3 class="user-card__name">User Name</h3>
            <p class="user-card__email">user@example.com</p>
        </div>
    </div>
    <button class="btn btn--primary">Follow</button>
</div>
```

```css
.user-card {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: var(--space-md);
    margin-bottom: var(--space-md);
    background: var(--color-surface);
    border-radius: var(--radius-lg);
    box-shadow: var(--shadow-md);
    border: 1px solid var(--color-border);
    transition: box-shadow 0.2s ease;
}

.user-card:hover {
    box-shadow: var(--shadow-lg);
}

.user-card__info {
    display: flex;
    align-items: center;
    gap: var(--space-sm);
}

.user-card__avatar {
    width: 2.5rem;
    height: 2.5rem;
    border-radius: var(--radius-full);
}

.user-card__name {
    font-size: var(--text-lg);
    font-weight: var(--font-semibold);
    color: var(--color-text);
}

.user-card__email {
    font-size: var(--text-sm);
    color: var(--color-text-muted);
}

.btn {
    padding: var(--space-sm) var(--space-md);
    border-radius: var(--radius-lg);
    border: none;
    cursor: pointer;
    font-weight: var(--font-medium);
}

.btn--primary {
    background: var(--color-primary);
    color: white;
}

.btn--primary:hover {
    background: var(--color-primary-dark);
}

.btn--primary:focus-visible {
    outline: none;
    box-shadow: 0 0 0 2px var(--color-surface), 0 0 0 4px var(--color-primary);
}
```

### Why This Matters

| Tailwind Problem | CSS Solution |
|------------------|--------------|
| HTML is unreadable | HTML documents itself |
| 50+ classes per element | 1-3 semantic classes |
| Styles scattered in markup | Styles in one place |
| Change padding site-wide? Find all `p-4` | Change `--space-md` once |
| Tight coupling | Separation of concerns |
| Requires build tools | Works natively |
| Learning cryptic abbreviations | Standard CSS knowledge |
