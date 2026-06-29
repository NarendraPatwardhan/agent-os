export type ToolPolicyAction = "approve" | "require_approval" | "block";
export type ToolPolicyOwner = "org" | "user";

export interface ToolPolicyRule {
  owner: ToolPolicyOwner;
  pattern: string;
  action: ToolPolicyAction;
}

export class ToolPolicySet {
  private readonly rules: ToolPolicyRule[];

  constructor(rules: readonly ToolPolicyRule[] = []) {
    this.rules = rules.map((rule) => {
      validateRule(rule);
      return { ...rule };
    });
  }

  resolve(address: string): ToolPolicyAction | null {
    const seenOwners = new Set<ToolPolicyOwner>();
    let strongest: ToolPolicyAction | null = null;
    for (const rule of this.rules) {
      if (seenOwners.has(rule.owner) || !patternMatches(rule.pattern, address)) continue;
      seenOwners.add(rule.owner);
      if (strongest === null || actionRank(rule.action) > actionRank(strongest)) {
        strongest = rule.action;
      }
    }
    return strongest;
  }
}

function validateRule(rule: ToolPolicyRule): void {
  if (rule.owner !== "org" && rule.owner !== "user") {
    throw new Error(`invalid tool policy owner '${String(rule.owner)}'`);
  }
  if (!validPolicyPattern(rule.pattern)) {
    throw new Error(`invalid tool policy pattern '${rule.pattern}'`);
  }
  if (rule.action !== "approve" && rule.action !== "require_approval" && rule.action !== "block") {
    throw new Error(`invalid tool policy action '${String(rule.action)}'`);
  }
}

function validPolicyPattern(pattern: string): boolean {
  if (pattern === "*") return true;
  // The host authorizes at the egress splice, where it knows the connection
  // (integration.owner.connection) and the request method/origin but NOT the catalog tool address, so
  // it resolves rules against `integration.owner.connection.*`. A pattern can only match at connection
  // granularity or coarser: a trailing wildcard with at most three concrete segments. A per-tool
  // pattern (a concrete fourth segment) could never match and would silently no-op, so it is rejected
  // at construction rather than left as a fail-open footgun.
  const parts = pattern.split(".");
  return (
    parts.length >= 2 &&
    parts.length <= 4 &&
    parts[parts.length - 1] === "*" &&
    parts.every((part) => part === "*" || validSegment(part))
  );
}

function patternMatches(pattern: string, address: string): boolean {
  if (pattern === "*") return true;
  const p = pattern.split(".");
  const a = address.split(".");
  if (p[p.length - 1] === "*") {
    if (a.length < p.length - 1) return false;
    return p.slice(0, -1).every((part, i) => part === "*" || part === a[i]);
  }
  return p.length === a.length && p.every((part, i) => part === "*" || part === a[i]);
}

function validSegment(value: string): boolean {
  return /^[A-Za-z0-9_-]+$/.test(value);
}

function actionRank(action: ToolPolicyAction): number {
  switch (action) {
    case "approve":
      return 0;
    case "require_approval":
      return 1;
    case "block":
      return 2;
  }
}
