"""Always-release native host artifacts.

A debug host artifact is a trap: wasmtime/cranelift compiled at `-c fastbuild` JITs and
instantiates `kernel.wasm` an order of magnitude slower, so every interactive run and —
the reason this exists — every e2e boot would crawl. The release wrappers pin the WHOLE
host subgraph (wasmtime, the TLS stack, the host lib) to `compilation_mode=opt` regardless
of the top-level `-c`, then re-export the transitioned artifact under a stable name.

The same transition is what e2e targets apply to their host dependency, so "e2e always runs
release wasmtime" is structural — not a flag someone has to remember to pass.

NOTE on host_musl: this transition does NOT force `//platforms:host_musl` yet, and
deliberately so. The original design wanted musl to "match a prebuilt libwasmtime.a" — but AgentOS
compiles wasmtime from source (crate_universe), so that premise is gone. And true musl is a
real toolchain integration, not a platform string: rules_rust's gnu and musl toolchains are
constraint-INDISTINGUISHABLE (both `target_compatible_with = [cpu:x86_64, os:linux]`), so
naming `host_musl` silently resolves to gnu; making it stick needs a custom libc
constraint + manual toolchain registration AND a musl C toolchain for the native C deps
(the TLS stack, zstd-sys). That buys static distribution, nothing for e2e speed, so it is
deferred until distribution actually needs it.
"""

# Pin opt for everything reachable from the host binary, whatever the top-level `-c`.
def _host_release_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

_host_release_transition = transition(
    implementation = _host_release_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _host_release_binary_impl(ctx):
    bin = ctx.attr.bin[0]
    default = bin[DefaultInfo]
    src_exe = default.files_to_run.executable

    # Re-export the transitioned binary under this rule's name, preserving runnability.
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = out, target_file = src_exe, is_executable = True)
    return [DefaultInfo(
        executable = out,
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]).merge(default.default_runfiles),
    )]

def _host_release_shared_library_impl(ctx):
    lib = ctx.attr.lib[0]
    default = lib[DefaultInfo]

    shared = None
    for file in default.files.to_list():
        if file.extension in ["so", "dylib", "dll"]:
            shared = file
            break
    if not shared:
        fail("host_release_shared_library expected a shared library output")

    # Re-export the transitioned cdylib under its normal filename so downstream staging
    # rules do not learn Bazel's configuration-specific output path.
    out = ctx.actions.declare_file(ctx.attr.out if ctx.attr.out else shared.basename)
    ctx.actions.symlink(output = out, target_file = shared)
    return [DefaultInfo(
        files = depset([out]),
        runfiles = ctx.runfiles(files = [out]).merge(default.default_runfiles),
    )]

host_release_binary = rule(
    implementation = _host_release_binary_impl,
    executable = True,
    doc = "Surface a rust_binary as an always-opt (release wasmtime) binary.",
    attrs = {
        "bin": attr.label(
            mandatory = True,
            cfg = _host_release_transition,
            doc = "The rust_binary, built at compilation_mode=opt under the transition.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

host_release_shared_library = rule(
    implementation = _host_release_shared_library_impl,
    doc = "Surface a rust_shared_library as an always-opt native shared library.",
    attrs = {
        "lib": attr.label(
            mandatory = True,
            cfg = _host_release_transition,
            doc = "The rust_shared_library cdylib, built at compilation_mode=opt under the transition.",
        ),
        "out": attr.string(
            doc = "Optional stable output basename. Defaults to the transitioned shared library basename.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
