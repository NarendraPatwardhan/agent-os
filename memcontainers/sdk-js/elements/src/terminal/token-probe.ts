// Resolve CSS values — including var()/color-mix()/oklch() — to concrete strings
// by letting the browser compute them on a throwaway probe element. This is how
// the terminal inherits the host page's design tokens without hardcoding colors:
// xterm's JS theme wants literal rgb strings, so we sample them from the cascade.
//
// The probe is appended to a `scope` element (default <body>) so per-element
// custom properties set on the host resolve correctly — custom properties inherit
// through the shadow boundary.

function probeScope(scope?: HTMLElement | null): HTMLElement {
  return scope ?? document.body;
}

/** Resolve a CSS color expression to a concrete `rgb(...)`/`rgba(...)` string. */
export function resolveColor(value: string, scope?: HTMLElement | null): string {
  const probe = document.createElement("span");
  probe.style.color = value;
  probe.style.display = "none";
  const host = probeScope(scope);
  host.appendChild(probe);
  const rgb = getComputedStyle(probe).color;
  probe.remove();
  return rgb;
}

/** Resolve a CSS length (e.g. `var(--fs-13)`) to a pixel number. */
export function resolvePx(value: string, scope?: HTMLElement | null): number {
  const probe = document.createElement("span");
  probe.style.fontSize = value;
  probe.style.display = "none";
  const host = probeScope(scope);
  host.appendChild(probe);
  const px = parseFloat(getComputedStyle(probe).fontSize);
  probe.remove();
  return px;
}

/** Resolve a color and re-emit it at a given alpha, so selections/scrollbars can
 *  layer translucently over the terminal background. */
export function rgbaColor(value: string, alpha: number, scope?: HTMLElement | null): string {
  const resolved = resolveColor(value, scope);
  const match = resolved.match(/rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)/);
  if (match) return `rgba(${match[1]}, ${match[2]}, ${match[3]}, ${alpha})`;

  // getComputedStyle returned a non-rgb form (e.g. oklch) — rasterize one pixel to
  // read its rgb channels.
  const canvas = document.createElement("canvas");
  canvas.width = 1;
  canvas.height = 1;
  const ctx = canvas.getContext("2d");
  if (!ctx) return resolved;
  ctx.fillStyle = resolved;
  ctx.fillRect(0, 0, 1, 1);
  const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data;
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

/** Read a CSS custom property off an element (with a fallback). */
export function readVar(el: HTMLElement, name: string, fallback = ""): string {
  const v = getComputedStyle(el).getPropertyValue(name).trim();
  return v.length > 0 ? v : fallback;
}
