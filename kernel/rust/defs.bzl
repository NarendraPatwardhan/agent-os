"""Always-release wasm kernel + a size budget gate.

The kernel is meaningless as a debug artifact — the multi-MB unoptimized build is never
what ships, and we never want it. `release_wasm` pins the WHOLE kernel subgraph (wasmi,
talc, the kernel cdylib) to `compilation_mode=opt` regardless of the top-level `-c`, AND
transitions it onto the wasm32 platform, then surfaces the single optimized `.wasm`. The
cdylib is additionally built symbol-stripped (`-Cstrip=symbols`, in BUILD), so the default
`bazel build //kernel/rust:kernel` is the small, stripped artifact every time.

`kernel_size_test` is the B5 budget gate: the shipped wasm must stay under a byte ceiling,
so a size regression fails CI instead of silently bloating the agent's footprint.
"""

# Pin opt + the wasm platform for everything reachable from the kernel cdylib.
def _release_wasm_transition_impl(_settings, attr):
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:platforms": [attr.platform],
    }

_release_wasm_transition = transition(
    implementation = _release_wasm_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
    ],
)

def _release_wasm_impl(ctx):
    lib = ctx.attr.lib[0]
    wasm = [f for f in lib[DefaultInfo].files.to_list() if f.extension == "wasm"][0]
    out = ctx.actions.declare_file(ctx.label.name + ".wasm")
    # Re-export the transitioned cdylib's .wasm under a stable name (kernel.wasm).
    ctx.actions.symlink(output = out, target_file = wasm)
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

release_wasm = rule(
    implementation = _release_wasm_impl,
    doc = "Surface a rust_shared_library as an always-opt, wasm32 kernel.wasm.",
    attrs = {
        "lib": attr.label(
            mandatory = True,
            cfg = _release_wasm_transition,
            doc = "The rust_shared_library cdylib (built opt+wasm under the transition).",
        ),
        "platform": attr.string(default = "//platforms:wasm32_freestanding"),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def kernel_size_limit(name, wasm, max_bytes):
    """A B5 budget gate: fail if `wasm` exceeds `max_bytes`."""
    native.sh_test(
        name = name,
        size = "small",
        srcs = ["//kernel/rust:size-limit.sh"],
        args = ["$(rootpath %s)" % wasm, str(max_bytes)],
        data = [wasm],
    )
