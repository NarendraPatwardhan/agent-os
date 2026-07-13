"""Hermetic post-link optimization for every shipped WebAssembly artifact.

Compilers already build release-small outputs, but Binaryen can see the final linked module and apply
WebAssembly-specific whole-program DCE, code folding, function merging, and zero-aware data packing.
This rule is deliberately one policy rather than per-program flags: every shipped artifact receives
the same deterministic pass before metadata stamping, capability attestation, size gates, and images.
"""

# The repository's wasm32 targets already emit this stable feature set. Keep it explicit:
# `--all-features` permits Binaryen to introduce proposal instructions the kernel's interpreter does
# not implement.
_FEATURES = [
    "--enable-sign-ext",
    "--enable-mutable-globals",
    "--enable-nontrapping-float-to-int",
    "--enable-bulk-memory",
    "--enable-bulk-memory-opt",
]

def _wasm_opt_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".wasm")
    args = ctx.actions.args()
    args.add(ctx.file.wasm)
    args.add_all(_FEATURES)
    args.add_all(["-Oz", "--converge", "-o"])
    args.add(out)
    ctx.actions.run(
        executable = ctx.executable._optimizer,
        arguments = [args],
        # rules_js launchers normally chdir to Bazel's output tree. This action deliberately passes
        # execroot-relative paths, so keep the action's execroot cwd; "." is the launcher's documented
        # build-action setting for that mode.
        env = {"BAZEL_BINDIR": "."},
        inputs = [ctx.file.wasm],
        outputs = [out],
        mnemonic = "WasmOpt",
        progress_message = "Optimizing WebAssembly %{label}",
    )
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

wasm_opt = rule(
    implementation = _wasm_opt_impl,
    doc = "Optimize one final linked wasm with the repository-wide pinned Binaryen size policy.",
    attrs = {
        "wasm": attr.label(
            # rules_zig's configured-binary target does not advertise an extension even though its
            # sole output is WebAssembly. The optimizer itself parses and validates the input.
            allow_single_file = True,
            mandatory = True,
            doc = "Final linked wasm to optimize before stamping and validation.",
        ),
        "_optimizer": attr.label(
            default = "//bazel/tools/wasm-opt:wasm-opt",
            executable = True,
            cfg = "exec",
        ),
    },
)
