//! Strict Luau AOT promotion gates. These tests boot the real AgentOS kernel and run the exact
//! mc_program artifact produced by the zero-import frontend/backend and strict runtime graph.

use crate::boot_loom_aot;

/// One immutable artifact consumes six different argv values in six fresh processes. The ordinary
/// pinned /bin/luau interpreter computes the same loop from runtime argv in the same kernel session;
/// equality therefore crosses source -> IR -> object -> strict runtime -> adapter -> kernel stdio.
#[test]
fn luau_aot_object_matches_interpreter_for_dynamic_argv() {
    let mut session = boot_loom_aot();
    session
        .host
        .write_file(
            "/demo/aot-oracle.luau",
            concat!(
                "local n = assert(tonumber(...))\n",
                "local sum = 0\n",
                "for i = 1, n do sum += i end\n",
                "print(sum)\n",
            )
            .as_bytes(),
        )
        .expect("seed pinned-interpreter oracle");

    for input in [-3, 0, 1, 4, 7, 12] {
        let aot = session.run_for_output(&format!("luau-aot-oracle {input}"));
        let interpreted = session.run_for_output(&format!("luau /demo/aot-oracle.luau {input}"));
        assert_eq!(
            aot, interpreted,
            "strict AOT mismatch for argv input {input}"
        );
    }
}

/// A real root chunk returning a value is compiled from upstream IR and run as a stamped guest. The
/// entry requests zero results, matching ordinary Luau script semantics: return values are not output.
#[test]
fn luau_aot_top_level_return_is_silent() {
    let mut session = boot_loom_aot();
    assert_eq!(
        session.run_for_output("luau-aot-silent; echo status=$?"),
        "status=0\r\n"
    );
}
