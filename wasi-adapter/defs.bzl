"""WASI→mc conversion (VISION §13.4 / §16.3): turn a wasm32-wasi guest crate into a pure-`mc` box.

A box compiled for wasm32-wasi imports `wasi_snapshot_preview1`. `mc_box` link-injects the
`//wasi-adapter` object (whose `__imported_wasi_*` definitions resolve the stable WASI imports
in one shot), then drives the TRAMPOLINE FIXPOINT for the residue: Rust std/deps bind a few
calls (`args_*`, `random_get`, …) to hash-mangled symbols the adapter's stable names don't match,
and a relink can reveal a DEEPER binding (memcontainers' getrandom case). So each round links the
adapter + every trampoline so far; `//tools/wasi-trampoline` reads that round's residual mangled
imports (symbol + signature, straight off the wasm) into the next trampoline; repeat until a box
imports only `mc`. Post-convergence rounds read zero residue → empty trampolines → byte-identical
relinks Bazel caches, so the round cap is free past convergence. The whole pipeline is graph
targets — no out-of-band xtask. Ported from memcontainers' `xtask::{build_wasi_adapter,
convert_wasi_tool,generate_trampoline}` + `conformance::func_imports_full`.
"""

load("@rules_rust//rust:defs.bzl", "rust_binary", "rust_library")
load("//kernel/rust:defs.bzl", "release_wasm")

# Trampoline+relink rounds before giving up. Matches memcontainers' xtask MAX_ROUNDS; a high cap
# is cheap because post-convergence rounds are cached.
_MAX_ROUNDS = 8

def _obj_from_rlib(name, rlib):
    """Extract the single relocatable object from a codegen-units=1 rlib (an ar archive)."""
    native.genrule(
        name = name,
        srcs = [rlib],
        outs = [name + ".o"],
        cmd = "RL=$$(realpath $(execpath %s)); D=$$(mktemp -d); (cd $$D && ar x $$RL); cp $$D/*.o $@" % rlib,
        tags = ["manual"],
    )

def mc_box(name, srcs, crate_root, crate_name, crate_features, deps, edition = "2021", compile_data = [], rounds = _MAX_ROUNDS, visibility = None):
    """Build a wasm32-wasi guest crate and convert it to a pure-`mc` box named `name`.

    `name` is the converged box (the final round). Intermediate rounds + trampolines are private
    `<name>_r<k>` / `<name>_tramp<k>_*` targets. Build under `--platforms=//platforms:wasm32_wasi`.
    """
    adapter = "//wasi-adapter:wasi_adapter_obj"
    ident = name.replace("-", "_")

    def _round(rname, objs, vis):
        # Link-inject every accumulated object (adapter + trampolines) via -Clink-arg; the objects
        # are compile_data so they land in the rustc/link action's sandbox.
        rust_binary(
            name = rname,
            srcs = srcs,
            crate_root = crate_root,
            crate_name = crate_name,
            edition = edition,
            crate_features = crate_features,
            rustc_flags = ["-Clink-arg=$(location %s)" % o for o in objs],
            compile_data = objs + compile_data,
            tags = ["manual"],
            deps = deps,
            visibility = vis,
        )

    objs = [adapter]
    _round(name + "_r0", objs, None)
    prev = name + "_r0"

    for k in range(1, rounds + 1):
        # The next trampoline = forwarders for the previous round's residual mangled imports.
        native.genrule(
            name = "%s_tramp%d_src" % (name, k),
            srcs = [prev],
            outs = ["%s_tramp%d.rs" % (name, k)],
            tools = ["//tools/wasi-trampoline"],
            cmd = "$(execpath //tools/wasi-trampoline) $(execpath %s) $@" % prev,
            tags = ["manual"],
        )
        rust_library(
            name = "%s_tramp%d_lib" % (name, k),
            srcs = ["%s_tramp%d_src" % (name, k)],
            crate_name = "%s_tramp%d" % (ident, k),
            edition = edition,
            rustc_flags = ["-Ccodegen-units=1"],
            tags = ["manual"],
        )
        _obj_from_rlib("%s_tramp%d_obj" % (name, k), "%s_tramp%d_lib" % (name, k))
        objs = objs + ["%s_tramp%d_obj" % (name, k)]

        last = (k == rounds)
        rname = name if last else "%s_r%d" % (name, k)
        _round(rname, objs, visibility if last else None)
        prev = rname

    # §16.4 attestation: surface the converged box opt+wasm32-wasi, then FAIL THE BUILD if its mc
    # imports exceed its declared tier. //... reaches `<name>.attest`, so a mis-tiered box (an
    # applet importing a syscall its tier cannot use — spawn/net/mount in read-only, …) is a build
    # error, not a runtime surprise (the §16.4 / A9 default-deny gate, drift = build error).
    release_wasm(name = name + "_opt", lib = name, platform = "//platforms:wasm32_wasi", visibility = visibility)
    native.genrule(
        name = name + ".attest",
        srcs = [name + "_opt"],
        outs = [name + ".attested"],
        tools = ["//tools/mc-attest"],
        cmd = "$(execpath //tools/mc-attest) $(execpath :%s_opt) && touch $@" % name,
    )

    # The roster → /bin symlinks: read the converged box's mc_applets section and emit
    # /bin/<applet> → <box> symlinks — the SINGLE source for the staged /bin (no hand list, no
    # drift from what the box dispatches; §16.3). A flavor image layers `<name>_symlinks`.
    native.genrule(
        name = name + "_symlinks",
        srcs = [name + "_opt"],
        outs = [name + "_symlinks.tar"],
        tools = ["//tools/mc-roster"],
        cmd = "$(execpath //tools/mc-roster) $(execpath :%s_opt) %s $@" % (name, name),
        visibility = visibility,
    )
