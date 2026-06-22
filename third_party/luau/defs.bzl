"""cc_headers — expose a set of C/C++ headers as a CcInfo (compilation context only) WITHOUT a CC
toolchain. The zig c++ build (rules_zig, via `deps`) consumes the CcInfo's include dirs + headers;
the actual compile is done by zig, so no cc_library / cc_toolchain is needed (agent-os registers a
zig toolchain, not a CC one — the `toolchains/zig_cc` Phase-A placeholder). See PLAN.md."""

load("@bazel_skylib//lib:paths.bzl", "paths")

def _cc_headers_impl(ctx):
    # Make each `includes` entry exec-root-relative: <repo>/<package>/<inc>. For @luau (package "")
    # → external/<repo>/VM/include; for the main-repo glue (package third_party/luau/glue, inc ".")
    # → third_party/luau/glue.
    inc = [
        paths.normalize(paths.join(ctx.label.workspace_root, ctx.label.package, d))
        for d in ctx.attr.includes
    ]
    return [
        DefaultInfo(files = depset(ctx.files.hdrs)),
        CcInfo(compilation_context = cc_common.create_compilation_context(
            headers = depset(ctx.files.hdrs),
            includes = depset(inc),
        )),
    ]

cc_headers = rule(
    implementation = _cc_headers_impl,
    attrs = {
        "hdrs": attr.label_list(allow_files = True, doc = "The header files."),
        "includes": attr.string_list(doc = "Include dirs (package-relative), added as -I."),
    },
    doc = "Header-only CcInfo with no CC toolchain dependency.",
)
