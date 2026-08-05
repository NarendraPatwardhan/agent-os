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

/// Raw argv strings force the exact upstream-IR object through CHECK_TAG -> DO_ARITH -> compiled
/// rejoin. Both the stamped AOT guest and the separately linked interpreter must succeed and agree.
#[test]
fn luau_aot_arithmetic_slow_path_rejoins_compiled_code() {
    let mut session = boot_loom_aot();
    session
        .host
        .write_file(
            "/demo/aot-slow-add.luau",
            b"local lhs, rhs = ...\nprint(lhs + rhs)\n",
        )
        .expect("seed pinned-interpreter slow arithmetic oracle");

    for (lhs, rhs) in [(-50, 8), (0, 0), (20, 22), (7, -3), (1234, 5678)] {
        let expected = format!("{}\r\nstatus=0\r\n", lhs + rhs);
        let aot = session.run_for_output(&format!("luau-aot-slow-add {lhs} {rhs}; echo status=$?"));
        let interpreted = session.run_for_output(&format!(
            "luau /demo/aot-slow-add.luau {lhs} {rhs}; echo status=$?"
        ));
        assert_eq!(aot, expected, "strict AOT slow add failed for {lhs}/{rhs}");
        assert_eq!(
            aot, interpreted,
            "strict AOT slow add mismatch for {lhs}/{rhs}"
        );
    }
}

/// One source-built function exercises the broad scalar fast tier and its exact fallback blocks:
/// add/subtract/multiply/divide/floor-divide/modulo/negate plus a runtime-selected numeric branch.
/// The stamped guest and the pinned interpreter load the same installed source and receive the same
/// numeric values; positive and negative divisors select both branch arms.
#[test]
fn luau_aot_scalar_arithmetic_and_branch_breadth_matches_interpreter() {
    let mut session = boot_loom_aot();

    for (lhs, rhs) in [(-50, 5), (0, 2), (20, 4), (7, 2), (12, 3), (8, -2), (9, -3)] {
        let aot = session.run_for_output(&format!(
            "luau-aot-scalar {lhs} {rhs}; echo status=$?"
        ));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local run = require(\"aot_scalar_breadth\"); local a, b = ...; print(run(assert(tonumber(a)), assert(tonumber(b))))' {lhs} {rhs}; echo status=$?"
        ));
        assert_eq!(
            aot, interpreted,
            "strict AOT scalar breadth mismatch for {lhs}/{rhs}"
        );
        assert!(
            aot.ends_with("status=0\r\n"),
            "strict AOT scalar breadth failed for {lhs}/{rhs}: {aot:?}"
        );
    }
}

/// The exact source-built package publishes all three Protos, survives full collection, returns a
/// real caller closure, materializes its child closure, and rejoins after compiled Luau-to-Luau
/// CALL. The pinned interpreter requires the same installed source as a module and invokes the
/// returned closure; no rewritten source stands in for the compiler input.
#[test]
fn luau_aot_compiled_proto_graph_calls_rejoin() {
    let mut session = boot_loom_aot();

    for (lhs, rhs) in [(-50, 8), (0, 0), (20, 22), (7, -3), (1234, 5678)] {
        let expected = format!("{}\r\nstatus=0\r\n", lhs + rhs);
        let aot = session.run_for_output(&format!(
            "luau-aot-compiled-call {lhs} {rhs}; echo status=$?"
        ));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local run = require(\"aot_compiled_call\"); print(run(...))' {lhs} {rhs}; echo status=$?"
        ));
        assert_eq!(
            aot, expected,
            "strict AOT compiled call failed for {lhs}/{rhs}"
        );
        assert_eq!(
            aot, interpreted,
            "strict AOT compiled call mismatch for {lhs}/{rhs}"
        );
    }
}

/// The exact source-built package publishes a three-Proto graph whose inner compiled closure reads
/// one immutable captured value after full collection. The interpreter requires that same installed
/// source and invokes its returned closure with the same two raw strings.
#[test]
fn luau_aot_captured_proto_graph_calls_rejoin() {
    let mut session = boot_loom_aot();

    for (lhs, rhs) in [(-50, 8), (0, 0), (20, 22), (7, -3), (1234, 5678)] {
        let expected = format!("{}\r\nstatus=0\r\n", lhs + rhs);
        let aot = session.run_for_output(&format!(
            "luau-aot-captured-call {lhs} {rhs}; echo status=$?"
        ));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local run = require(\"aot_captured_call\"); print(run(...))' {lhs} {rhs}; echo status=$?"
        ));
        assert_eq!(
            aot, expected,
            "strict AOT captured call failed for {lhs}/{rhs}"
        );
        assert_eq!(
            aot, interpreted,
            "strict AOT captured call mismatch for {lhs}/{rhs}"
        );
    }
}

/// The exact source-built package publishes a three-Proto graph whose inner compiled call returns
/// two contiguous values. The caller consumes both before rejoining compiled arithmetic, while the
/// interpreter requires the same installed source and receives the same two raw strings.
#[test]
fn luau_aot_multi_result_proto_graph_calls_rejoin() {
    let mut session = boot_loom_aot();

    for (lhs, rhs) in [(-50, 8), (0, 0), (20, 22), (7, -3), (1234, 5678)] {
        let expected = format!("{}\r\nstatus=0\r\n", 2 * lhs + rhs);
        let aot = session.run_for_output(&format!(
            "luau-aot-multi-result-call {lhs} {rhs}; echo status=$?"
        ));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local run = require(\"aot_multi_result_call\"); print(run(...))' {lhs} {rhs}; echo status=$?"
        ));
        assert_eq!(
            aot, expected,
            "strict AOT multi-result call failed for {lhs}/{rhs}"
        );
        assert_eq!(
            aot, interpreted,
            "strict AOT multi-result call mismatch for {lhs}/{rhs}"
        );
    }
}

/// The exact source-built factory closes a mutable local into one accumulator. Its factory frame is
/// gone and a full collection runs before the same accumulator is called twice, proving that the
/// open UpVal was closed into owned storage and that both compiled calls mutate that same cell. The
/// pinned interpreter requires the exact installed source and receives the same three raw strings.
#[test]
fn luau_aot_reference_capture_survives_close_gc_and_mutation() {
    let mut session = boot_loom_aot();

    for (initial, delta1, delta2) in [
        (10, 5, -2),
        (-3, 8, 4),
        (0, 0, 0),
        (-50, -8, 7),
        (1234, 5678, -4321),
    ] {
        let expected = format!("{}\r\nstatus=0\r\n", initial + delta1 + delta2);
        let aot = session.run_for_output(&format!(
            "luau-aot-reference-capture {initial} {delta1} {delta2}; echo status=$?"
        ));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local initial, delta1, delta2 = ...; local factory = require(\"aot_reference_capture\"); local accumulator = factory(initial); accumulator(delta1); print(accumulator(delta2))' {initial} {delta1} {delta2}; echo status=$?"
        ));
        assert_eq!(
            aot, expected,
            "strict AOT reference capture failed for {initial}/{delta1}/{delta2}"
        );
        assert_eq!(
            aot, interpreted,
            "strict AOT reference capture mismatch for {initial}/{delta1}/{delta2}"
        );
    }
}
