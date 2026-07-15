"""Expose the registered Zig compiler as a formatter executable."""

def _zig_formatter_impl(ctx):
    toolchain = ctx.toolchains["@rules_zig//zig:toolchain_type"].zigtoolchaininfo
    if toolchain.mode != "file":
        fail("zig_formatter requires the hermetic file-backed Zig toolchain")

    zig = toolchain.zig_exe.file
    zig_runfile = zig.short_path[3:] if zig.short_path.startswith("../") else zig.short_path
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        output = executable,
        content = """#!/usr/bin/env bash
set -euo pipefail
runfiles="${{RUNFILES_DIR:-$0.runfiles}}"
exec \"$runfiles/{zig}\" fmt \"$@\"
""".format(zig = zig_runfile),
        is_executable = True,
    )

    return DefaultInfo(
        executable = executable,
        runfiles = ctx.runfiles(files = [
            zig,
            toolchain.zig_lib.file,
            toolchain.validation,
        ]),
    )

zig_formatter = rule(
    implementation = _zig_formatter_impl,
    executable = True,
    toolchains = ["@rules_zig//zig:toolchain_type"],
)
