"""abi_library — project one contract into many languages, compile-validate the code
projections, and gate drift (SYSTEMS.md, B2).

For each language it:
  1. runs the projector over the contract → `<name>.gen.<ext>` (always fresh — B1),
  2. for rust/zig, wraps the output in a library + a build_test, so an invalid
     projection is a failed build (the compiler validates the generator's output),
  3. mirrors every projection into `gen/` behind a `write_source_files` diff gate, so
     an editor-visible copy stays honest and any hand-edit is a failed test (B2).

Consumers depend on the library target (`//memcontainers/contracts:mc_rust`, …) — the fresh genrule
output — never the committed `gen/` copy, so the binding a build uses is never stale.
"""

load("@rules_rust//rust:defs.bzl", "rust_library")
load("@rules_zig//zig:defs.bzl", "zig_library")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@aspect_bazel_lib//lib:write_source_files.bzl", "write_source_files")

_EXT = {
    "rust": "rs",
    "zig": "zig",
    "ts": "ts",
    "elixir": "ex",
    "md": "md",
    "asyncapi": "asyncapi.yaml",
    "openapi": "openapi.yaml",
}

def abi_library(name, contract, langs):
    """Project `contract` into each of `langs`. `name` is the module id (mc/env/ctl/wire/constants)."""
    sync_files = {}
    for lang in langs:
        ext = _EXT[lang]
        gen = "%s_%s_gen" % (name, lang)
        out = "%s.gen.%s" % (name, ext)

        # The projector emits one (module, lang) to stdout. Deterministic: same inputs
        # → byte-identical output, so the diff gate below is stable (A7/B2).
        native.genrule(
            name = gen,
            srcs = [contract],
            outs = [out],
            tools = ["//memcontainers/contracts/codegen:projector"],
            cmd = "$(location //memcontainers/contracts/codegen:projector) --module {m} --lang {l} --contract $(location {c}) > $@".format(
                m = name,
                l = lang,
                c = contract,
            ),
        )
        sync_files["gen/%s" % out] = ":%s" % gen

        # Compile-validate the code projections (the generator's output must be real
        # source). Text projections (ts/md/asyncapi) are gated by diff only until their
        # compiler lane lands (ts: the JS host).
        if lang == "rust":
            rust_library(
                name = "%s_rust" % name,
                srcs = [":%s" % gen],
                crate_root = ":%s" % gen,
                edition = "2021",
                visibility = ["//visibility:public"],
            )
            build_test(name = "%s_rust_build_test" % name, targets = [":%s_rust" % name])
        elif lang == "zig":
            zig_library(
                name = "%s_zig" % name,
                main = ":%s" % gen,
                visibility = ["//visibility:public"],
            )
            build_test(name = "%s_zig_build_test" % name, targets = [":%s_zig" % name])

    # B2 drift gate. Update the committed copies with `bazel run //memcontainers/contracts:<name>_sync`.
    write_source_files(
        name = "%s_sync" % name,
        files = sync_files,
        visibility = ["//visibility:public"],
    )
