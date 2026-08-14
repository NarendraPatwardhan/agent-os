//! The first AgentOS consumer of luauc: a useful multi-module workflow planner compiled by the
//! pinned portable compiler and executed by the real kernel beside the interpreter built from the
//! same upstream Luau identity.

use host::ExecOptions;

use crate::boot_loom_agent_plan;

/// One compiled package handles normal, disabled, all-mode, defaulted, and protected lenient-error
/// workflows from the real VFS. The interpreter runs the exact installed sources with identical
/// arguments. JSON member order is not language semantics, so compare decoded values plus the
/// concrete product fields rather than encoder iteration order.
#[test]
fn compiled_agent_plan_matches_interpreter_across_workflows() {
    let mut session = boot_loom_agent_plan();
    let scenarios = [
        (
            "empty",
            "ready",
            r#"{"name":"empty","steps":[]}"#,
            0_u64,
            0_u64,
            0_u64,
        ),
        (
            "disabled",
            "ready",
            r#"{"name":"disabled","steps":[{"id":"later","command":"defer","enabled":false}]}"#,
            0,
            0,
            0,
        ),
        (
            "defaults",
            "ready",
            r#"{"name":"deploy","defaults":{"retries":2},"steps":[{"id":"build","command":"zig build","retries":1},{"id":"preview","command":"serve","enabled":false},{"id":"verify","command":"bazel test"}]}"#,
            2,
            0,
            3,
        ),
        (
            "all",
            "all",
            r#"{"name":"release","defaults":{"retries":1},"steps":[{"id":"compile","command":"build"},{"id":"publish","command":"upload","enabled":false,"retries":4},{"id":"announce","command":"notify","retries":0}]}"#,
            3,
            0,
            5,
        ),
        (
            "lenient",
            "lenient",
            r#"{"name":"repair","defaults":{"retries":3},"steps":[{"id":"inspect","command":"scan"},{"id":"","command":"broken"},{"id":"apply","command":"patch","retries":2}]}"#,
            2,
            1,
            5,
        ),
    ];

    for (scenario, mode, manifest, expected_steps, expected_skipped, expected_retries) in scenarios
    {
        let input = format!("/tmp/agent-plan-{scenario}-input.json");
        let compiled_output = format!("/tmp/agent-plan-{scenario}-compiled.json");
        let interpreted_output = format!("/tmp/agent-plan-{scenario}-interpreted.json");
        session
            .host
            .write_file(&input, manifest.as_bytes())
            .expect("seed workflow manifest");

        let compiled_status = session.run_for_output(&format!(
            "/bin/agent-plan {input} {compiled_output} {mode}; echo status=$?"
        ));
        let interpreted_status = session.run_for_output(&format!(
            "cd /lib/luau; /bin/luau agent_plan_main.luau {input} {interpreted_output} {mode}; echo status=$?"
        ));
        assert_eq!(
            compiled_status, "status=0\r\n",
            "compiled agent-plan failed for {scenario}"
        );
        assert_eq!(
            compiled_status, interpreted_status,
            "process behavior diverged for {scenario}"
        );

        let compiled_bytes = session
            .host
            .read_file(&compiled_output)
            .expect("read compiled plan output");
        let interpreted_bytes = session
            .host
            .read_file(&interpreted_output)
            .expect("read interpreted plan output");
        let mut compiled: serde_json::Value =
            serde_json::from_slice(&compiled_bytes).expect("compiled agent-plan emitted JSON");
        let mut interpreted: serde_json::Value = serde_json::from_slice(&interpreted_bytes)
            .expect("interpreter agent-plan emitted JSON");
        if scenario == "lenient" {
            let expected = "workflow step 2 must have a non-empty id";
            assert_eq!(
                compiled["skipped"][0]["error"].as_str(),
                Some("agent_plan_step.luau:6: workflow step 2 must have a non-empty id"),
                "compiled package lost its canonical module source"
            );
            assert_eq!(
                interpreted["skipped"][0]["error"].as_str(),
                Some("./agent_plan_step.luau:6: workflow step 2 must have a non-empty id"),
                "interpreter lost its installed-file source"
            );
            assert!(
                compiled["skipped"][0]["error"]
                    .as_str()
                    .expect("compiled lenient error")
                    .ends_with(expected)
                    && interpreted["skipped"][0]["error"]
                        .as_str()
                        .expect("interpreted lenient error")
                        .ends_with(expected),
                "protected validation messages diverged"
            );
            compiled["skipped"][0]
                .as_object_mut()
                .expect("compiled skipped record")
                .remove("error");
            interpreted["skipped"][0]
                .as_object_mut()
                .expect("interpreted skipped record")
                .remove("error");
        }
        assert_eq!(compiled, interpreted, "semantic divergence for {scenario}");
        assert_eq!(compiled["workflow"], scenario_to_workflow(scenario));
        assert_eq!(compiled["mode"], mode);
        assert_eq!(compiled["step_count"].as_u64(), Some(expected_steps));
        assert_eq!(compiled["skipped_count"].as_u64(), Some(expected_skipped));
        assert_eq!(compiled["total_retries"].as_u64(), Some(expected_retries));
        assert_eq!(compiled["generated_by"], "agent-plan");
        assert_eq!(compiled["input"], input);
    }
}

/// A compiled validation failure crosses the real protected-dispatch boundary with the same source
/// behavior as the interpreter, and a subsequent compiled process still completes normally. This
/// proves the command reports language errors instead of trapping or poisoning the kernel.
#[test]
fn compiled_agent_plan_reports_errors_and_kernel_recovers() {
    let mut session = boot_loom_agent_plan();
    session
        .host
        .write_file(
            "/tmp/agent-plan-error-input.json",
            br#"{"name":"error","steps":[]}"#,
        )
        .expect("seed invalid-mode workflow");

    let compiled = session
        .host
        .run(
            "agent-plan",
            &[
                "/tmp/agent-plan-error-input.json".to_owned(),
                "/tmp/agent-plan-error-aot.json".to_owned(),
                "impossible".to_owned(),
            ],
            200_000,
            ExecOptions::default(),
        )
        .expect("run compiled invalid-mode workflow");
    let interpreted = session
        .host
        .run(
            "luau",
            &[
                "agent_plan_main.luau".to_owned(),
                "/tmp/agent-plan-error-input.json".to_owned(),
                "/tmp/agent-plan-error-interpreted.json".to_owned(),
                "impossible".to_owned(),
            ],
            200_000,
            ExecOptions {
                cwd: Some("/lib/luau".into()),
                ..ExecOptions::default()
            },
        )
        .expect("run interpreted invalid-mode workflow");
    for (label, result) in [("compiled", compiled), ("interpreted", interpreted)] {
        let stderr = String::from_utf8_lossy(&result.stderr);
        assert!(
            stderr.contains("workflow mode must be ready, all, or lenient"),
            "{label} path lost the Luau validation error: {stderr:?}"
        );
        assert_eq!(
            result.exit_code, 1,
            "{label} path returned the wrong failure status"
        );
    }

    assert_eq!(
        session.run_for_output(
            "/bin/agent-plan /tmp/agent-plan-error-input.json /tmp/agent-plan-recovered.json ready; echo status=$?",
        ),
        "status=0\r\n",
        "compiled command did not recover after the protected failure"
    );
    let recovered = session
        .host
        .read_file("/tmp/agent-plan-recovered.json")
        .expect("read recovered plan");
    let recovered: serde_json::Value =
        serde_json::from_slice(&recovered).expect("recovered plan is JSON");
    assert_eq!(recovered["workflow"], "error");
    assert_eq!(recovered["step_count"].as_u64(), Some(0));
}

fn scenario_to_workflow(scenario: &str) -> &str {
    match scenario {
        "defaults" => "deploy",
        "all" => "release",
        "lenient" => "repair",
        value => value,
    }
}
