"""Compile-check the guest sysroot for its real target: wasm32.

The sysroot is a `no_std` rlib whose `mc` import block is `#[link(wasm_import_module =
"mc")]` — it compiles ONLY for wasm32, there is no native build. A plain `build_test` checks
a target in the default (native host) config, which the sysroot can't satisfy, so this
transitions the library onto `//platforms:wasm32_freestanding` first and asserts it builds.
This is the same shape as the kernel's `release_wasm` (a wasm32 transition over a no_std
crate), minus the opt pin and the `.wasm` surfacing — an rlib has no single-file output.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")

def _to_wasm32_impl(_settings, _attr):
    return {"//command_line_option:platforms": "//platforms:wasm32_freestanding"}

_to_wasm32 = transition(
    implementation = _to_wasm32_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _wasm32_lib_impl(ctx):
    # Re-surface the wasm32-transitioned library's outputs; building this rule compiles the
    # library for wasm32.
    return [DefaultInfo(files = ctx.attr.lib[0][DefaultInfo].files)]

_wasm32_lib = rule(
    implementation = _wasm32_lib_impl,
    attrs = {
        "lib": attr.label(mandatory = True, cfg = _to_wasm32),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

def wasm32_build_test(name, lib):
    """Assert `lib` compiles for wasm32 (the guest target)."""
    _wasm32_lib(name = name + ".wasm32", lib = lib, tags = ["manual"])
    build_test(name = name, targets = [":" + name + ".wasm32"])
