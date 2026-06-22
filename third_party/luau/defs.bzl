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

def _cc_object_impl(ctx):
    # FORCE-LINK a precompiled relocatable object via user_link_flags (a positional object is linked
    # whole), as opposed to a static library whose members are pulled lazily. The wasi-adapter's
    # __imported_wasi_* definitions must override wasi-libc's import stubs, so they have to be present
    # unconditionally — a lazy rlib leaves the WASI imports unresolved. No CC toolchain needed.
    obj = ctx.file.obj
    return [
        DefaultInfo(files = depset([obj])),
        CcInfo(linking_context = cc_common.create_linking_context(
            linker_inputs = depset([cc_common.create_linker_input(
                owner = ctx.label,
                user_link_flags = [obj.path],
                additional_inputs = depset([obj]),
            )]),
        )),
    ]

cc_object = rule(
    implementation = _cc_object_impl,
    attrs = {"obj": attr.label(allow_single_file = True, doc = "A relocatable .o to force-link.")},
    doc = "Force-link a precompiled object via CcInfo, no CC toolchain.",
)
