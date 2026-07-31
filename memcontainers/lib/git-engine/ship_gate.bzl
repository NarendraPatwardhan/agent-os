"""Analysis-time gates for ship filegroups (GIT.md L5 NOTICE membership).

Validates required basenames appear in a label's DefaultInfo files without
building expensive generated members (e.g. emcc wasm). Dropping NOTICE from
the product filegroup fails analysis of the gate target.
"""

def _assert_ship_files_impl(ctx):
    have = {f.basename: True for f in ctx.files.ship}
    missing = [n for n in ctx.attr.required if n not in have]
    if missing:
        fail("%s: ship set missing required files %s (have %s)" % (
            ctx.label,
            missing,
            sorted(have.keys()),
        ))
    out = ctx.actions.declare_file(ctx.label.name + ".ok")
    # No ship inputs: membership is analysis-only so CI stays cheap when wasm is not built.
    ctx.actions.write(out, "ok\n")
    return [DefaultInfo(files = depset([out]))]

assert_ship_files = rule(
    implementation = _assert_ship_files_impl,
    doc = "Fail analysis if ship DefaultInfo lacks required basenames (L5).",
    attrs = {
        "ship": attr.label(
            mandatory = True,
            allow_files = True,
            doc = "Product filegroup or multi-file label (e.g. :git_engine_wasm).",
        ),
        "required": attr.string_list(
            mandatory = True,
            doc = "Basenames that must appear (NOTICE, COPYING, …).",
        ),
    },
)
