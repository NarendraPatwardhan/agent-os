"""Force compilation_mode=opt on a dependency subgraph.

Used so Wasm product targets always build as release even when the top-level
invocation is -c fastbuild.
"""

def _opt_transition_impl(_settings, _attr):
    return {"//command_line_option:compilation_mode": "opt"}

_opt_transition = transition(
    implementation = _opt_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:compilation_mode"],
)

def _force_opt_impl(ctx):
    info = ctx.attr.target[0][DefaultInfo]
    return [
        DefaultInfo(
            files = info.files,
            runfiles = info.default_runfiles,
        ),
    ]

force_opt = rule(
    implementation = _force_opt_impl,
    doc = "Re-export target built under compilation_mode=opt.",
    attrs = {
        "target": attr.label(
            mandatory = True,
            cfg = _opt_transition,
            doc = "Target (and deps) forced into -c opt.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
