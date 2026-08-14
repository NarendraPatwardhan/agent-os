"""Manifest the platform-specific Firecracker operator bundle."""

def _firecracker_bundle_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".tar")
    args = ctx.actions.args()
    args.add("firecracker")
    args.add(ctx.file.payload)
    args.add(output)
    args.add(ctx.info_file)
    args.add(ctx.file.module_file)
    args.add(ctx.attr.target_os)
    args.add(ctx.attr.target_arch)
    ctx.actions.run(
        executable = ctx.executable.tool,
        arguments = [args],
        inputs = depset(
            [ctx.file.payload, ctx.info_file, ctx.file.module_file] + ctx.files.module_graph,
        ),
        outputs = [output],
        mnemonic = "AgentOsFirecrackerBundleManifest",
        progress_message = "Stamping Firecracker bundle provenance",
    )
    return DefaultInfo(files = depset([output]))

firecracker_bundle = rule(
    implementation = _firecracker_bundle_impl,
    attrs = {
        "payload": attr.label(allow_single_file = True, mandatory = True),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
        "module_file": attr.label(allow_single_file = True, mandatory = True),
        "module_graph": attr.label(allow_files = True, mandatory = True),
        "target_os": attr.string(mandatory = True),
        "target_arch": attr.string(mandatory = True),
    },
)
