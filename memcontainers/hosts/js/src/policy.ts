// Tool-policy types only. The policy LOGIC (validation, pattern matching, most-restrictive resolution)
// is single-source in `toolcore::policy` and reached from this host via the catalog-compiler wasm
// (`cc_validate_policy` / `cc_policy_resolve`) — there is no TypeScript reimplementation to drift.

export type ToolPolicyAction = "approve" | "require_approval" | "block";
export type ToolPolicyOwner = "org" | "user";

export interface ToolPolicyRule {
  owner: ToolPolicyOwner;
  pattern: string;
  action: ToolPolicyAction;
}
