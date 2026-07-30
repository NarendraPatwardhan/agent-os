"""Pick a single file by extension from a multi-file target."""

def _pick_file_impl(ctx):
    matches = [f for f in ctx.files.src if f.path.endswith(ctx.attr.extension)]
    if len(matches) != 1:
        fail("pick_file %s: expected exactly one *%s in %s, got %s" % (
            ctx.label,
            ctx.attr.extension,
            ctx.attr.src,
            [f.basename for f in ctx.files.src],
        ))
    src = matches[0]
    out = ctx.actions.declare_file(ctx.attr.out if ctx.attr.out else src.basename)
    ctx.actions.symlink(output = out, target_file = src)
    return [DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out]))]

pick_file = rule(
    implementation = _pick_file_impl,
    attrs = {
        "src": attr.label(mandatory = True, doc = "Multi-file provider (e.g. wasm_cc_binary)."),
        "extension": attr.string(mandatory = True, doc = "Suffix including dot, e.g. \".wasm\"."),
        "out": attr.string(default = "", doc = "Optional output basename."),
    },
)
