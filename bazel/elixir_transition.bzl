"""Scoped Elixir/OTP platform transitions.

The Elixir lane needs rules_erlang's dual-platform setup: the host platform builds
OTP/Elixir from source, while the target platform selects the Erlang/Elixir
version constraints. Keep that platform switch on the dependency edge into
//server instead of asking humans to flip Bazel's top-level --config.
"""

def _elixir_platform_impl(_settings, _attr):
    return {
        "//command_line_option:host_platform": "//platforms:erlang_internal_platform",
        "//command_line_option:platforms": ["//platforms:erlang_linux_26_2_platform"],
    }

_elixir_platform_transition = transition(
    implementation = _elixir_platform_impl,
    inputs = [],
    outputs = [
        "//command_line_option:host_platform",
        "//command_line_option:platforms",
    ],
)

def _elixir_test_impl(ctx):
    actual_target = ctx.attr.actual[0]
    actual = actual_target[DefaultInfo]
    executable = actual.files_to_run.executable
    if executable == None:
        fail("elixir_test actual target must be executable")

    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = executable, is_executable = True)

    runfiles = ctx.runfiles()
    runfiles = runfiles.merge(actual.default_runfiles)
    runfiles = runfiles.merge(actual.data_runfiles)

    providers = [
        DefaultInfo(
            executable = out,
            files = depset([out], transitive = [actual.files]),
            runfiles = runfiles,
        ),
    ]
    if RunEnvironmentInfo in actual_target:
        providers.append(actual_target[RunEnvironmentInfo])
    return providers

def _elixir_file_impl(ctx):
    actual = ctx.attr.actual[0][DefaultInfo]
    files = actual.files.to_list()
    if len(files) != 1:
        fail("elixir_file actual target must produce exactly one file")
    output_name = ctx.attr.output
    if output_name == "":
        output_name = ctx.label.name
    out = ctx.actions.declare_file(output_name)
    ctx.actions.symlink(output = out, target_file = files[0])
    return [DefaultInfo(
        files = depset([out]),
        runfiles = actual.default_runfiles,
    )]

elixir_test = rule(
    implementation = _elixir_test_impl,
    test = True,
    attrs = {
        "actual": attr.label(
            mandatory = True,
            executable = True,
            cfg = _elixir_platform_transition,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

elixir_file = rule(
    implementation = _elixir_file_impl,
    attrs = {
        "actual": attr.label(
            mandatory = True,
            cfg = _elixir_platform_transition,
        ),
        "output": attr.string(),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
