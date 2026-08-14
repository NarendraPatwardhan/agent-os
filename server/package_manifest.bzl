def _package_manifest_impl(ctx):
    output = ctx.actions.declare_file(ctx.label.name + ".tar")
    args = ctx.actions.args()
    args.add("server")
    args.add(ctx.file.payload)
    args.add(output)
    args.add(ctx.info_file)
    args.add(ctx.file.module_file)
    args.add(ctx.attr.contract_major)
    args.add(ctx.attr.contract_minor)
    args.add(ctx.attr.capabilities)
    args.add(ctx.attr.build_mode)
    args.add(ctx.attr.target_os)
    args.add(ctx.attr.target_arch)
    args.add(ctx.attr.target_abi)
    args.add(ctx.attr.otp_version)
    args.add(ctx.attr.elixir_version)
    ctx.actions.run(
        executable = ctx.executable.tool,
        arguments = [args],
        inputs = depset(
            [ctx.file.payload, ctx.info_file, ctx.file.module_file] + ctx.files.module_graph,
        ),
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
        "module_file": attr.label(allow_single_file = True, mandatory = True),
        "module_graph": attr.label(allow_files = True, mandatory = True),
        "contract_major": attr.int(mandatory = True),
        "contract_minor": attr.int(mandatory = True),
        "capabilities": attr.int(mandatory = True),
        "build_mode": attr.string(mandatory = True),
        "target_os": attr.string(mandatory = True),
        "target_arch": attr.string(mandatory = True),
        "target_abi": attr.string(mandatory = True),
        "otp_version": attr.string(mandatory = True),
        "elixir_version": attr.string(mandatory = True),
    },
)
