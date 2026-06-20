"""abi_library — project one contract file into many languages (VISION §6.2, B2).

For each requested language, run the projector over the contract to emit a binding
(`<name>.gen.<ext>`), and wire a `write_source_files` drift gate so a stale checked-in
copy is a failed `diff_test` — in every language at once. This is the mechanism that
makes the four boundaries impossible to drift across the Rust kernel, the Zig kernel,
the hosts, and the TS client.

Inert until //contracts/codegen:projector exists (Phase A step 3). The macro is
written now — the contract's intended projection shape — so turning it on is a
one-line edit to contracts/BUILD.bazel, not a design task.
"""

_EXT = {
    "rust": "rs",
    "zig": "zig",
    "ts": "ts",
    "asyncapi": "yaml",
    "md": "md",
}

def abi_library(name, contract, langs):
    """Generate <name>.gen.<ext> for each lang from `contract`, each behind a drift gate.

    Args:
        name: projection group name (e.g. "mc", "env", "ctl", "wire").
        contract: the source .kdl label (e.g. "syscalls.kdl").
        langs: languages to project into; keys of _EXT.
    """
    for lang in langs:
        native.genrule(
            name = "%s_%s_gen" % (name, lang),
            srcs = [contract, "constants.kdl"],
            outs = ["%s.gen.%s" % (name, _EXT[lang])],
            tools = ["//contracts/codegen:projector"],
            # The projector reads the contract (+ shared constants) and emits one
            # language to stdout. Deterministic: same inputs → byte-identical output.
            cmd = "$(location //contracts/codegen:projector) --lang %s --contract $(location %s) > $@" % (lang, contract),
        )

        # B2 drift gate — keep an editor-visible <name>.gen.<ext> honest. Enabled
        # with aspect_bazel_lib in Phase A:
        #   load("@aspect_bazel_lib//lib:write_source_files.bzl", "write_source_files")
        #   write_source_files(
        #       name = "%s_%s" % (name, lang),
        #       files = {"gen/%s.gen.%s" % (name, _EXT[lang]): ":%s_%s_gen" % (name, lang)},
        #   )
