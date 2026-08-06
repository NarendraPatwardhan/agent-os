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
        let aot = session.run_for_output(&format!("luau-aot-scalar {lhs} {rhs}; echo status=$?"));
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

/// One source-built function selects between a descending while-loop and an ascending numeric
/// for-loop from a real boolean argument. The two arms add versus subtract, so equal loop bounds
/// cannot hide an incorrect truthiness branch or accidental common implementation.
#[test]
fn luau_aot_structural_truthiness_and_loop_paths_match_interpreter() {
    let mut session = boot_loom_aot();

    for (n, descending) in [
        (0, true),
        (0, false),
        (1, true),
        (1, false),
        (5, true),
        (5, false),
        (12, true),
        (12, false),
    ] {
        let flag = if descending { "true" } else { "false" };
        let aot =
            session.run_for_output(&format!("luau-aot-structural {n} {flag}; echo status=$?"));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local run = require(\"aot_structural_core\"); local n, flag = ...; print(run(assert(tonumber(n)), flag == \"true\"))' {n} {flag}; echo status=$?"
        ));
        assert_eq!(
            aot, interpreted,
            "strict AOT structural-core mismatch for n={n}, descending={descending}"
        );
        assert!(
            aot.ends_with("status=0\r\n"),
            "strict AOT structural-core failed for n={n}, descending={descending}: {aot:?}"
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

/// The exact source-built four-Proto package exercises widened fixed calls at both boundaries. Its
/// caller invokes a zero-parameter/zero-result child and a four-parameter/three-result child, then
/// consumes all three returned values. The pinned interpreter requires the same installed source.
#[test]
fn luau_aot_general_fixed_call_shapes_match_interpreter() {
    let mut session = boot_loom_aot();

    for (a, b, c, d) in [
        (-50, 8, 3, -7),
        (0, 0, 0, 0),
        (20, 22, -5, 9),
        (7, -3, 11, -4),
        (1234, 5678, -4321, -1000),
    ] {
        let expected = format!("{}\r\nstatus=0\r\n", 2 * (a + b + c + d));
        let aot = session.run_for_output(&format!(
            "luau-aot-general-call {a} {b} {c} {d}; echo status=$?"
        ));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local run = require(\"aot_general_call\"); print(run(...))' {a} {b} {c} {d}; echo status=$?"
        ));
        assert_eq!(
            aot, expected,
            "strict AOT general fixed call failed for {a}/{b}/{c}/{d}"
        );
        assert_eq!(
            aot, interpreted,
            "strict AOT general fixed call mismatch for {a}/{b}/{c}/{d}"
        );
    }
}

/// The exact source-built package consumes one fixed value from the returned caller's runtime
/// varargs, forwards the open list through a one-fixed-parameter variadic child, and adjusts that
/// child's open return into four fixed parameters. The pinned interpreter requires the same source.
#[test]
fn luau_aot_vararg_forwarding_and_result_adjustment_match_interpreter() {
    let mut session = boot_loom_aot();

    for (a, b, c, d) in [
        (-50, 8, 3, -7),
        (0, 0, 0, 0),
        (20, 22, -5, 9),
        (7, -3, 11, -4),
        (1234, 5678, -4321, -1000),
    ] {
        let expected = format!("{}\r\nstatus=0\r\n", 2 * a + b + c + d);
        let aot = session.run_for_output(&format!(
            "luau-aot-vararg-forward {a} {b} {c} {d}; echo status=$?"
        ));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local run = require(\"aot_vararg_forward\"); print(run(...))' {a} {b} {c} {d}; echo status=$?"
        ));
        assert_eq!(
            aot, expected,
            "strict AOT vararg forwarding failed for {a}/{b}/{c}/{d}"
        );
        assert_eq!(
            aot, interpreted,
            "strict AOT vararg forwarding mismatch for {a}/{b}/{c}/{d}"
        );
    }

    let (a, b, c, d, discarded) = (19, -7, 5, 11, 999_999);
    let expected = format!("{}\r\nstatus=0\r\n", 2 * a + b + c + d);
    let aot = session.run_for_output(&format!(
        "luau-aot-vararg-forward {a} {b} {c} {d} {discarded}; echo status=$?"
    ));
    let interpreted = session.run_for_output(&format!(
        "luau -e 'local run = require(\"aot_vararg_forward\"); print(run(...))' {a} {b} {c} {d} {discarded}; echo status=$?"
    ));
    assert_eq!(aot, expected, "strict AOT open-tail truncation failed");
    assert_eq!(aot, interpreted, "strict AOT open-tail truncation mismatch");
}

/// The exact two-module package requires one stateful module twice during each invocation. The
/// strict-AOT guest calls the returned entry closure twice in one process, so both require sites and
/// both invocations must observe the same once-initialized, GC-rooted module result.
#[test]
fn luau_aot_static_module_initializes_once_and_preserves_cached_state() {
    let mut session = boot_loom_aot();

    for (a, b, c, d) in [
        (-50, 8, 3, -7),
        (0, 0, 0, 0),
        (20, 22, -5, 9),
        (7, -3, 11, -4),
        (1234, -567, -321, 1000),
    ] {
        let first = 1001 * a + b;
        let second = 1001 * (a + b + c) + d;
        let expected = format!("{first}\r\n{second}\r\nstatus=0\r\n");
        let aot = session.run_for_output(&format!(
            "luau-aot-static-import {a} {b} {c} {d}; echo status=$?"
        ));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local run = require(\"aot_static_import\"); local a, b, c, d = ...; print(run(a, b)); print(run(c, d))' {a} {b} {c} {d}; echo status=$?"
        ));
        assert_eq!(
            aot, expected,
            "strict AOT static import failed for {a}/{b}/{c}/{d}"
        );
        assert_eq!(
            aot, interpreted,
            "strict AOT static import mismatch for {a}/{b}/{c}/{d}"
        );
    }
}

/// Five compiled modules form two transitive paths to one mutable state export. The same returned
/// entry closure runs twice around full GC, exercising repeated require sites, transitive caching,
/// four-result return ranges, and persistent state in one stamped artifact.
#[test]
fn luau_aot_transitive_static_graph_shares_state_across_gc() {
    let mut session = boot_loom_aot();

    for values in [
        [-5, 2, 7, -3, 4, 1, -6, 8],
        [0, 0, 0, 0, 0, 0, 0, 0],
        [1, 2, 3, 4, 5, 6, 7, 8],
        [20, -8, 11, -4, -3, 9, -2, 6],
        [123, -57, -31, 100, 14, -9, 22, -45],
    ] {
        let mut total = 0i64;
        let mut expected_values = [0i64; 8];
        for call in 0..2 {
            let offset = call * 4;
            total += i64::from(values[offset]);
            expected_values[offset] = 10 * total;
            total += i64::from(values[offset + 1]);
            expected_values[offset + 1] = 100 * total + 1;
            total += i64::from(values[offset + 2]);
            expected_values[offset + 2] = 10 * total;
            total += i64::from(values[offset + 3]);
            expected_values[offset + 3] = 100 * total + 1;
        }
        let expected = format!(
            "{}\r\n{}\r\n{}\r\n{}\r\n{}\r\n{}\r\n{}\r\n{}\r\nstatus=0\r\n",
            expected_values[0],
            expected_values[1],
            expected_values[2],
            expected_values[3],
            expected_values[4],
            expected_values[5],
            expected_values[6],
            expected_values[7],
        );
        let args = values
            .iter()
            .map(i32::to_string)
            .collect::<Vec<_>>()
            .join(" ");
        let aot = session.run_for_output(&format!("luau-aot-static-graph {args}; echo status=$?"));
        let interpreted = session.run_for_output(&format!(
            "luau -e 'local run = require(\"aot_static_graph_main\"); local a,b,c,d,e,f,g,h = ...; local r1,r2,r3,r4 = run(a,b,c,d); print(r1); print(r2); print(r3); print(r4); r1,r2,r3,r4 = run(e,f,g,h); print(r1); print(r2); print(r3); print(r4)' {args}; echo status=$?"
        ));
        assert_eq!(
            aot, expected,
            "strict AOT transitive graph produced wrong state"
        );
        assert_eq!(aot, interpreted, "strict AOT transitive graph mismatch");
    }
}

/// A -> B -> A is rejected explicitly by the compiled registry on every independent attempt. The
/// guest checks the stable cycle-error identity before printing each false result. AgentOS
/// `/bin/luau` is deliberately not a differential here: its current loader recursively reloads this
/// closed graph until the process exhausts its call stack instead of producing a catchable error.
#[test]
fn luau_aot_static_cycle_fails_closed_and_can_be_retried() {
    let mut session = boot_loom_aot();
    let expected = "false\r\nfalse\r\nstatus=0\r\n";
    let aot = session.run_for_output("luau-aot-static-cycle; echo status=$?");
    assert_eq!(aot, expected, "strict AOT cycle handling was not catchable");
}

/// AgentOS require caches only successful initializers. A separately cached probe records a failed
/// initializer's side effect, proving that the second require reruns it instead of replaying an old
/// error or treating a failed placeholder as a module export.
#[test]
fn luau_aot_failed_static_initializer_retries_after_gc() {
    let mut session = boot_loom_aot();
    let expected = "false\r\n1\r\nfalse\r\n2\r\nstatus=0\r\n";
    let aot = session.run_for_output("luau-aot-static-initializer; echo status=$?");
    let interpreted = session.run_for_output(
        "luau -e 'local run = require(\"aot_static_initializer_main\"); local first = pcall(run, true); print(first); print(run(false)); local second = pcall(run, true); print(second); print(run(false))' ; echo status=$?",
    );
    assert_eq!(
        aot, expected,
        "strict AOT failed initializer was not retried exactly once"
    );
    assert_eq!(aot, interpreted, "strict AOT initializer retry mismatch");
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
