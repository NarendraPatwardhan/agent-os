#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolPolicyAction {
    Approve,
    RequireApproval,
    Block,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolPolicyOwner {
    Org,
    User,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolPolicyRule {
    pub owner: ToolPolicyOwner,
    pub pattern: String,
    pub action: ToolPolicyAction,
}

#[derive(Debug, Clone, Default)]
pub struct ToolPolicySet {
    rules: Vec<ToolPolicyRule>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolPolicyError {
    InvalidOwner,
    InvalidPattern,
    InvalidAction,
}

impl ToolPolicySet {
    pub fn new(rules: Vec<ToolPolicyRule>) -> Result<Self, ToolPolicyError> {
        for rule in &rules {
            validate_rule(rule)?;
        }
        Ok(Self { rules })
    }

    pub fn empty() -> Self {
        Self::default()
    }

    pub fn resolve(&self, address: &str) -> Option<ToolPolicyAction> {
        let mut seen_org = false;
        let mut seen_user = false;
        let mut strongest = None::<ToolPolicyAction>;
        for rule in &self.rules {
            let seen = match rule.owner {
                ToolPolicyOwner::Org => &mut seen_org,
                ToolPolicyOwner::User => &mut seen_user,
            };
            if *seen || !pattern_matches(&rule.pattern, address) {
                continue;
            }
            *seen = true;
            if strongest
                .map(|current| action_rank(rule.action) > action_rank(current))
                .unwrap_or(true)
            {
                strongest = Some(rule.action);
            }
        }
        strongest
    }
}

fn validate_rule(rule: &ToolPolicyRule) -> Result<(), ToolPolicyError> {
    match rule.owner {
        ToolPolicyOwner::Org | ToolPolicyOwner::User => {}
    }
    match rule.action {
        ToolPolicyAction::Approve | ToolPolicyAction::RequireApproval | ToolPolicyAction::Block => {
        }
    }
    if !valid_policy_pattern(&rule.pattern) {
        return Err(ToolPolicyError::InvalidPattern);
    }
    Ok(())
}

fn valid_policy_pattern(pattern: &str) -> bool {
    if pattern == "*" {
        return true;
    }
    // The host authorizes at the egress splice, where it knows the connection
    // (`integration.owner.connection`) and the request's method/origin, but NOT the catalog tool
    // address — so it resolves rules against `integration.owner.connection.*`. A pattern can therefore
    // only match at connection granularity or coarser: a trailing wildcard with at most three concrete
    // segments. A per-tool pattern (a concrete fourth segment) could never match and would silently
    // no-op, so it is rejected at construction rather than left as a fail-open footgun.
    let parts = pattern.split('.').collect::<Vec<_>>();
    parts.len() >= 2
        && parts.len() <= 4
        && parts.last() == Some(&"*")
        && parts.iter().all(|part| *part == "*" || valid_segment(part))
}

fn pattern_matches(pattern: &str, address: &str) -> bool {
    if pattern == "*" {
        return true;
    }
    let p = pattern.split('.').collect::<Vec<_>>();
    let a = address.split('.').collect::<Vec<_>>();
    if p.last() == Some(&"*") {
        if a.len() < p.len() - 1 {
            return false;
        }
        return p[..p.len() - 1]
            .iter()
            .zip(a.iter())
            .all(|(p, a)| *p == "*" || p == a);
    }
    p.len() == a.len() && p.iter().zip(a.iter()).all(|(p, a)| *p == "*" || p == a)
}

fn valid_segment(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|b| matches!(b, b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'_' | b'-'))
}

fn action_rank(action: ToolPolicyAction) -> u8 {
    match action {
        ToolPolicyAction::Approve => 0,
        ToolPolicyAction::RequireApproval => 1,
        ToolPolicyAction::Block => 2,
    }
}
