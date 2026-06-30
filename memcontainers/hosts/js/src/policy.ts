// Connection-policy types only. The policy LOGIC (validation, pattern matching, most-restrictive resolution)
// is single-source in `toolcore::policy` and reached from this host via the catalog-compiler wasm
// (`cc_validate_policy` / `cc_policy_resolve`) — there is no TypeScript reimplementation to drift.

export type ConnectionPolicyAction = "approve" | "require_approval" | "block";
export type ConnectionPolicyOwner = "org" | "user";

export interface ConnectionPolicyRule {
  owner: ConnectionPolicyOwner;
  pattern: string;
  action: ConnectionPolicyAction;
}
