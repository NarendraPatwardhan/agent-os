"""Adapt a rules_js CLI for execution by generic Bazel formatter rules."""

def _js_tool_impl(ctx):
    actual = ctx.attr.actual[DefaultInfo]
    executable = actual.files_to_run.executable
    if executable == None:
        fail("js_tool actual target must be executable")

    runfile = executable.short_path[3:] if executable.short_path.startswith("../") else executable.short_path
    out = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(
        output = out,
        content = """#!/usr/bin/env bash
set -euo pipefail
export BAZEL_BINDIR=.
runfiles="${{RUNFILES_DIR:-$0.runfiles}}"
exec \"$runfiles/_main/{runfile}\" \"$@\"
""".format(runfile = runfile),
        is_executable = True,
    )

    runfiles = ctx.runfiles()
    runfiles = runfiles.merge(actual.default_runfiles)
    runfiles = runfiles.merge(actual.data_runfiles)
    return DefaultInfo(
        executable = out,
        runfiles = runfiles,
    )

js_tool = rule(
    implementation = _js_tool_impl,
    executable = True,
    attrs = {
        "actual": attr.label(
            mandatory = True,
            executable = True,
            cfg = "exec",
        ),
    },
)
