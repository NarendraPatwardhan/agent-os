def _package_manifest_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".tar")
    args = ctx.actions.args()
    args.add(ctx.file.payload)
    args.add(output)
    args.add(ctx.info_file)
    args.add(ctx.attr.gitz_commit)
    args.add(ctx.attr.gitz_integrity)
    args.add(ctx.attr.contract_major)
    args.add(ctx.attr.contract_minor)
    args.add(ctx.attr.capabilities)
    args.add(ctx.attr.build_mode)
    ctx.actions.run(
        executable = ctx.executable.tool,
        arguments = [args],
        inputs = depset([ctx.file.payload, ctx.info_file]),
        outputs = [output],
        mnemonic = "AgentOsPackageManifest",
        progress_message = "Stamping AgentOS package provenance",
    )
    return DefaultInfo(files = depset([output]))

package_manifest = rule(
    implementation = _package_manifest_impl,
    attrs = {
        "payload": attr.label(allow_single_file = True, mandatory = True),
        "tool": attr.label(executable = True, cfg = "exec", mandatory = True),
        "gitz_commit": attr.string(mandatory = True),
        "gitz_integrity": attr.string(mandatory = True),
        "contract_major": attr.int(mandatory = True),
        "contract_minor": attr.int(mandatory = True),
        "capabilities": attr.int(mandatory = True),
        "build_mode": attr.string(mandatory = True),
    },
)
