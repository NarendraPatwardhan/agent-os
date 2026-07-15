"""WASI→mc conversion (SYSTEMS.md): turn a wasm32-wasi guest crate into a pure-`mc` box.

A box compiled for wasm32-wasi imports `wasi_snapshot_preview1`. The conversion link-injects the
`//memcontainers/wasi-adapter` object (whose `__imported_wasi_*` definitions resolve the stable WASI imports
in one shot), then drives the TRAMPOLINE FIXPOINT for the residue: Rust std/deps bind a few
calls (`args_*`, `random_get`, …) to hash-mangled symbols the adapter's stable names don't match,
and a relink can reveal a DEEPER binding (memcontainers' getrandom case). So each round links the
adapter + every trampoline so far; `//bazel/tools/wasi-trampoline` reads that round's residual mangled
imports (symbol + signature, straight off the wasm) into the next trampoline; repeat until a box
imports only `mc`. Post-convergence rounds read zero residue → empty trampolines → byte-identical
relinks Bazel caches, so the round cap is free past convergence. The whole pipeline is graph
targets — no out-of-band xtask. Ported from memcontainers' `xtask::{build_wasi_adapter,
convert_wasi_tool,generate_trampoline}` + `conformance::func_imports_full`.

Two consumers ride the shared conversion (`_convert_to_mc`): `mc_box` packages the multi-applet
coreutils busybox (its own in-source `mcbox!` tier stamp + the `mc-roster` /bin symlinks), and
`mc_wasi_program` packages a SINGLE std-wasi tool as an mc program/SERVICE (SYSTEMS.md — e.g.
typst), stamping mc_tier/mc_budget/mc_service from the build graph via `mc_program` (no roster).
"""

load("@rules_rust//rust:defs.bzl", "rust_binary", "rust_library")
load("//bazel:mc_program.bzl", "mc_program")
load("//bazel:release_wasm.bzl", "release_wasm")
load("//bazel:wasm_opt.bzl", "wasm_opt")

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

def _convert_to_mc(name, srcs, crate_root, crate_name, crate_features, deps, edition, compile_data, rounds, extra_rustc_flags, box_visibility):
    """Build the wasm32-wasi crate (`srcs`/`crate_root`) and trampoline-fixpoint it to a pure-`mc`
    rust_binary named `name` (the converged final round). Private rounds are `<name>_r<k>` /
    `<name>_tramp<k>_*`. `extra_rustc_flags` ride ONLY the final converged box — the intermediate rounds
    are throwaway (only their IMPORTS are read to build the next trampoline), and a flag like `-Cstrip`
    removes the `name` section `wasi-trampoline` needs to read those import symbols. The final-box flags
    don't change the import SET, so the trampolines built from the un-stripped rounds stay valid; the
    flags (typst's `-zstack-size` + `-Cstrip`) then apply to the box that actually ships. Shared by
    `mc_box` and `mc_wasi_program`; the caller adds packaging (roster vs. mc_program stamp)."""
    adapter = "//memcontainers/wasi-adapter:wasi_adapter_obj"
    ident = name.replace("-", "_")

    def _round(rname, objs, vis, extra):
        # Link-inject every accumulated object (adapter + trampolines) via -Clink-arg; the objects
        # are compile_data so they land in the rustc/link action's sandbox. `extra` (final round only)
        # carries per-tool link/codegen flags (typst's `-zstack-size` + `-Cstrip`).
        rust_binary(
            name = rname,
            srcs = srcs,
            crate_root = crate_root,
            crate_name = crate_name,
            edition = edition,
            crate_features = crate_features,
            rustc_flags = ["-Clink-arg=$(location %s)" % o for o in objs] + extra,
            compile_data = objs + compile_data,
            tags = ["manual"],
            deps = deps,
            visibility = vis,
        )

    objs = [adapter]
    _round(name + "_r0", objs, None, [])
    prev = name + "_r0"

    for k in range(1, rounds + 1):
        # The next trampoline = forwarders for the previous round's residual mangled imports.
        native.genrule(
            name = "%s_tramp%d_src" % (name, k),
            srcs = [prev],
            outs = ["%s_tramp%d.rs" % (name, k)],
            tools = ["//bazel/tools/wasi-trampoline"],
            cmd = "$(execpath //bazel/tools/wasi-trampoline) $(execpath %s) $@" % prev,
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
        _round(rname, objs, box_visibility if last else None, extra_rustc_flags if last else [])
        prev = rname

def mc_box(name, srcs, crate_root, crate_name, crate_features, deps, edition = "2021", compile_data = [], rounds = _MAX_ROUNDS, visibility = None):
    """Build a wasm32-wasi guest crate and convert it to a pure-`mc` box named `name`, then attest it
    and emit the `mc-roster` /bin symlinks (the multi-applet busybox lane — the coreutils).

    `name` is the converged box (the final round). Intermediate rounds + trampolines are private
    `<name>_r<k>` / `<name>_tramp<k>_*` targets. Build under `--platforms=//platforms:wasm32_wasi`.
    """
    _convert_to_mc(name, srcs, crate_root, crate_name, crate_features, deps, edition, compile_data, rounds, [], visibility)

    # Attestation: surface the converged box under the opt+wasm32-wasi transition, post-link optimize
    # it, then FAIL THE BUILD if its mc
    # imports exceed its declared tier. //... reaches `<name>.attest`, so a mis-tiered box (an
    # applet importing a syscall its tier cannot use — spawn/net/mount in read-only, …) is a build
    # error, not a runtime surprise (the A9 default-deny gate, drift = build error).
    release_wasm(name = name + "_release", lib = name, platform = "//platforms:wasm32_wasi")
    wasm_opt(name = name + "_opt", wasm = ":" + name + "_release", visibility = visibility)
    native.genrule(
        name = name + ".attest",
        srcs = [name + "_opt"],
        outs = [name + ".attested"],
        tools = ["//bazel/tools/mc-attest"],
        cmd = "$(execpath //bazel/tools/mc-attest) $(execpath :%s_opt) && touch $@" % name,
    )

    # The roster → /bin symlinks: read the converged box's mc_applets section and emit
    # /bin/<applet> → <box> symlinks — the SINGLE source for the staged /bin (no hand list, no
    # drift from what the box dispatches). A flavor image layers `<name>_symlinks`.
    native.genrule(
        name = name + "_symlinks",
        srcs = [name + "_opt"],
        outs = [name + "_symlinks.tar"],
        tools = ["//bazel/tools/mc-roster"],
        cmd = "$(execpath //bazel/tools/mc-roster) $(execpath :%s_opt) %s $@" % (name, name),
        visibility = visibility,
    )

def mc_wasi_program(name, srcs, crate_root, crate_name, deps, tier, service = "", mem = 0, fuel = 0, table = 0, crate_features = [], edition = "2021", compile_data = [], rounds = _MAX_ROUNDS, extra_rustc_flags = [], visibility = None):
    """A SINGLE std-wasi tool as an mc program/SERVICE (SYSTEMS.md — the Rust-std lane, e.g. typst):
    convert the wasm32-wasi crate to a pure-`mc` box (the adapter + trampoline fixpoint, shared with
    `mc_box`), transition it with `release_wasm`, then post-link optimize, stamp
    mc_tier/mc_budget/mc_service, and attest (`mc_program`,
    whose validation action enforces import purity and tier fit). Unlike `mc_box` there is NO
    busybox roster — one tool, not a multi-applet box — and the metadata is declared in the BUILD (the
    `mc_rust_program` convention), not in the source. `service` (non-empty) stamps the mc_service section
    so `mc_service_layer` activates it. `extra_rustc_flags` ride only the final converged box, after
    trampoline discovery, so flags like `-Cstrip=symbols` do not erase import names before analysis.
    Build under `--platforms=//platforms:wasm32_wasi`.

    Targets: `<name>` (the stamped service, McProgramInfo), `<name>_box` (the converged rust_binary),
    `<name>_box_release` (the transitioned wasm that mc_program post-link optimizes).
    """
    box = name + "_box"
    _convert_to_mc(box, srcs, crate_root, crate_name, crate_features, deps, edition, compile_data, rounds, extra_rustc_flags, None)
    release_wasm(name = box + "_release", lib = box, platform = "//platforms:wasm32_wasi")
    mc_program(
        name = name,
        wasm = ":" + box + "_release",
        tier = tier,
        service = service,
        mem = mem,
        fuel = fuel,
        table = table,
        visibility = visibility,
    )
