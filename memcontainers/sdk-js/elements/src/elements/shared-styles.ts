import { css } from "lit";

// Base styles for the one shadow-DOM element in this package (<mc-sandbox>). The
// light-DOM components are styled by styles/components.css instead; these Lit `css`
// rules exist only because shadow-DOM selectors don't pierce in from the page.
//
// Deliberately does NOT capture design tokens into `--mc-*` on :host — that would
// let a :host rule outrank an embedder's `mc-sandbox { --mc-accent: … }`. Instead
// each rule reads tokens with the fallback chain `var(--mc-x, var(--x, <fallback>))`,
// so precedence is: embedder `--mc-x` › host design system `--x` (base.css) › a
// standalone-correct default. Custom properties inherit through the shadow boundary,
// so the tokens defined on :root in base.css reach in here.
export const baseStyles = css`
  :host {
    box-sizing: border-box;
    display: block;
    color: var(--mc-fg, var(--fg, #1b1b1f));
    font-family: var(--mc-font-sans, var(--font-sans, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif));
    -webkit-font-smoothing: antialiased;
  }
  :host([hidden]) {
    display: none;
  }
  *,
  *::before,
  *::after {
    box-sizing: border-box;
  }
`;
