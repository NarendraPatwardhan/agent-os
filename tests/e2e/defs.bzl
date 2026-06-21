"""e2e tests that boot the real kernel under an always-RELEASE host.

Your rule: every e2e runs release wasmtime, because a debug wasmtime JITs/instantiates
kernel.wasm an order of magnitude slower. `rust_e2e_test` makes that structural — it pins
the test's whole subgraph (the host lib, wasmtime, cranelift) to `compilation_mode=opt`
with a transition, exactly like the shipped `mc` (hosts/wasmtime/defs.bzl). No `-c opt`
anyone has to remember; `bazel test //tests/e2e:…` is release by construction.

The kernel.wasm keeps its own release_wasm transition (opt + wasm32), so the data-dep'd
kernel is unaffected; this transition only optimizes the native host the test links.
"""

load("@rules_rust//rust:defs.bzl", "rust_test")

def _opt_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

_opt_transition = transition(
    implementation = _opt_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _opt_test_impl(ctx):
    inner = ctx.attr.inner[0]
    exe = inner[DefaultInfo].files_to_run.executable
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = exe, is_executable = True)

    providers = [DefaultInfo(
        executable = out,
        runfiles = ctx.runfiles(files = [out]).merge(inner[DefaultInfo].default_runfiles),
    )]
    # Forward the inner test's run environment (if any) so `bazel test` sees it.
    if RunEnvironmentInfo in inner:
        providers.append(inner[RunEnvironmentInfo])
    return providers

_opt_test = rule(
    implementation = _opt_test_impl,
    test = True,
    attrs = {
        "inner": attr.label(mandatory = True, cfg = _opt_transition),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def rust_e2e_test(name, size = "small", **kwargs):
    """A rust_test whose host subgraph (wasmtime) builds at compilation_mode=opt.

    Keep the WHOLE suite in ONE such target. Measured: the host compiles kernel.wasm once
    per process (~0.9s, cranelift) and every boot after that is ~1.6ms (MODULE_CACHE), so a
    single binary runs the entire suite in ~1s. Splitting into many targets would re-pay the
    ~0.9s compile each time — the one thing to NOT do given the sub-second-per-test bar.
    """
    rust_test(name = name + "_inner", tags = ["manual"], **kwargs)
    _opt_test(name = name, inner = ":" + name + "_inner", size = size)
