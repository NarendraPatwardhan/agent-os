//! Cross-host parity for the tool policy engine. This test and the TS sibling
//! (`//memcontainers/hosts/js:policy_parity_test`) consume the SAME vector file
//! (`test/policy_parity.json`), so the two independent implementations — `policy.rs` here and
//! `policy.ts` there — cannot drift in how they resolve rules or which patterns they reject. The
//! egress splice authorizes at connection granularity, so resolve addresses are
//! `integration.owner.connection.*`.

use host::{ToolPolicyAction, ToolPolicyOwner, ToolPolicyRule, ToolPolicySet};
use serde_json::Value;

fn vectors() -> Value {
    let rel = std::env::var("MC_POLICY_VECTORS").expect("MC_POLICY_VECTORS unset (run under bazel)");
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let path = r
        .rlocation(&rel)
        .unwrap_or_else(|| panic!("{rel} not found in runfiles"));
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_slice(&bytes).expect("parse policy_parity.json")
}

fn owner(s: &str) -> Option<ToolPolicyOwner> {
    match s {
        "org" => Some(ToolPolicyOwner::Org),
        "user" => Some(ToolPolicyOwner::User),
        _ => None,
    }
}

fn action(s: &str) -> Option<ToolPolicyAction> {
    match s {
        "approve" => Some(ToolPolicyAction::Approve),
        "require_approval" => Some(ToolPolicyAction::RequireApproval),
        "block" => Some(ToolPolicyAction::Block),
        _ => None,
    }
}

fn rule(v: &Value) -> Option<ToolPolicyRule> {
    Some(ToolPolicyRule {
        owner: owner(v["owner"].as_str()?)?,
        pattern: v["pattern"].as_str()?.to_string(),
        action: action(v["action"].as_str()?)?,
    })
}

fn action_label(a: Option<ToolPolicyAction>) -> Option<&'static str> {
    a.map(|a| match a {
        ToolPolicyAction::Approve => "approve",
        ToolPolicyAction::RequireApproval => "require_approval",
        ToolPolicyAction::Block => "block",
    })
}

#[test]
fn policy_resolve_matches_shared_vectors() {
    let v = vectors();
    for case in v["resolve"].as_array().expect("resolve array") {
        let name = case["name"].as_str().unwrap_or("?");
        let rules: Vec<ToolPolicyRule> = case["rules"]
            .as_array()
            .expect("rules array")
            .iter()
            .map(|r| rule(r).unwrap_or_else(|| panic!("{name}: invalid rule in a resolve case")))
            .collect();
        let set = ToolPolicySet::new(rules)
            .unwrap_or_else(|e| panic!("{name}: rules did not construct: {e:?}"));
        let got = action_label(set.resolve(case["address"].as_str().expect("address")));
        let want = case["expect"].as_str();
        assert_eq!(got, want, "resolve parity case '{name}'");
    }
}

#[test]
fn policy_construction_rejects_shared_vectors() {
    let v = vectors();
    for case in v["reject"].as_array().expect("reject array") {
        let name = case["name"].as_str().unwrap_or("?");
        let r = &case["rule"];
        // Rust models owner/action as enums, so a bad owner/action value is unconstructible
        // (type-enforced) — those cases are exercised only by the TS sibling, where they are strings.
        // Here we assert the PATTERN rejections, which both implementations must enforce identically.
        let (Some(o), Some(a)) = (
            owner(r["owner"].as_str().unwrap_or("")),
            action(r["action"].as_str().unwrap_or("")),
        ) else {
            continue;
        };
        let built = ToolPolicySet::new(vec![ToolPolicyRule {
            owner: o,
            pattern: r["pattern"].as_str().expect("pattern").to_string(),
            action: a,
        }]);
        assert!(
            built.is_err(),
            "reject parity case '{name}' should fail to construct"
        );
    }
}
