"""Rust tests whose implementation subgraph is compiled with `-c opt`.

Use this for Rust tests generally, and especially for any test that instantiates
wasmtime. The public test target keeps the caller's name; the generated
`<name>_inner` target is manual and is the actual rust_test built through an opt
transition.
"""

load("@rules_rust//rust:defs.bzl", "rust_test")

def _opt_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

_opt_transition = transition(
    implementation = _opt_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _opt_rust_test_impl(ctx):
    inner = ctx.attr.inner[0]
    exe = inner[DefaultInfo].files_to_run.executable
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = exe, is_executable = True)

    providers = [DefaultInfo(
        executable = out,
        runfiles = ctx.runfiles(files = [out]).merge(inner[DefaultInfo].default_runfiles),
    )]
    if RunEnvironmentInfo in inner:
        providers.append(inner[RunEnvironmentInfo])
    return providers

_opt_rust_test = rule(
    implementation = _opt_rust_test_impl,
    test = True,
    attrs = {
        "inner": attr.label(mandatory = True, cfg = _opt_transition),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def rust_opt_test(name, size = "small", tags = None, visibility = None, **kwargs):
    """Wrap a rust_test in a public opt-transitioned test target."""
    inner_name = name + "_inner"
    inner_tags = list(kwargs.pop("tags", []))
    if "manual" not in inner_tags:
        inner_tags.append("manual")

    rust_test(
        name = inner_name,
        tags = inner_tags,
        **kwargs
    )

    outer_kwargs = {
        "size": size,
        "tags": [] if tags == None else tags,
    }
    if visibility != None:
        outer_kwargs["visibility"] = visibility
    _opt_rust_test(
        name = name,
        inner = ":" + inner_name,
        **outer_kwargs
    )
