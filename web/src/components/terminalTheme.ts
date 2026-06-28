export function readCssVar(scope: HTMLElement, name: string): string | undefined {
  const value = getComputedStyle(scope).getPropertyValue(name).trim();
  return value.length > 0 ? value : undefined;
}

export function resolveCssColor(expr: string, scope: HTMLElement, fallback = "#0b0b0c"): string {
  const probe = scope.ownerDocument.createElement("span");
  probe.style.position = "absolute";
  probe.style.pointerEvents = "none";
  probe.style.visibility = "hidden";
  probe.style.color = expr;
  scope.appendChild(probe);
  const value = getComputedStyle(probe).color;
  probe.remove();
  return value.length > 0 && value !== "canvastext" ? value : fallback;
}

export function resolveCssPx(expr: string, scope: HTMLElement): number | undefined {
  const probe = scope.ownerDocument.createElement("span");
  probe.style.position = "absolute";
  probe.style.pointerEvents = "none";
  probe.style.visibility = "hidden";
  probe.style.width = expr;
  scope.appendChild(probe);
  const value = Number.parseFloat(getComputedStyle(probe).width);
  probe.remove();
  return Number.isFinite(value) ? value : undefined;
}

export function rgbaCssColor(expr: string, opacity: number, scope: HTMLElement): string {
  const resolved = resolveCssColor(expr, scope);
  const match = resolved.match(/rgba?\(([^)]+)\)/i);
  if (!match) return resolved;
  const parts = match[1].split(/[,\s/]+/).filter(Boolean);
  const [r, g, b] = parts;
  if (!r || !g || !b) return resolved;
  return `rgba(${r}, ${g}, ${b}, ${opacity})`;
}
