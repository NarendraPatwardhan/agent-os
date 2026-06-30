//! Host-side credential-egress origin derivation from the curated registry (the wasmtime/Elixir peer
//! of the JS `deriveConnectionOrigins`). Hermetic: the registry is curated data, so derivation needs
//! no network. The JS side is proven end-to-end against real GitHub; this asserts the Rust host derives
//! the identical origins so the two hosts stay in parity.

use host::derive_connection_origins;

#[test]
fn github_origins_derived_from_curated_servers() {
    assert_eq!(
        derive_connection_origins("github.org.main"),
        vec!["https://api.github.com".to_string()],
    );
}

#[test]
fn openapi_and_google_integrations_derive_curated_servers() {
    // U1: every secret-bearing integration now carries curated `servers`, so a bare {ref, auth}
    // connection derives its egress origin — `mc.use("<x>", token)` works beyond GitHub.
    assert_eq!(
        derive_connection_origins("stripe.org.main"),
        vec!["https://api.stripe.com".to_string()],
    );
    assert_eq!(
        derive_connection_origins("openai.org.main"),
        vec!["https://api.openai.com".to_string()],
    );
    // Per-API Google egress hosts come from each discovery doc's rootUrl.
    assert_eq!(
        derive_connection_origins("google-gmail.org.main"),
        vec!["https://gmail.googleapis.com".to_string()],
    );
}

#[test]
fn microsoft_origin_derived_from_endpoint() {
    // No curated `servers`, but an `endpoint` — the origin is derived from it.
    assert_eq!(
        derive_connection_origins("microsoft.org.main"),
        vec!["https://graph.microsoft.com".to_string()],
    );
}

#[test]
fn uncurated_integration_yields_no_origins() {
    // Underivable ⇒ empty ⇒ the splice fails closed (derivation never widens an allowlist).
    assert!(derive_connection_origins("totally-not-real.org.main").is_empty());
}
