"""cc_headers — expose a set of C/C++ headers as a CcInfo (compilation context only) WITHOUT a CC
toolchain. The zig c++ build (rules_zig, via `deps`) consumes the CcInfo's include dirs + headers;
the actual compile is done by zig, so no cc_library / cc_toolchain is needed (agent-os registers a
zig toolchain, not a CC one — the `toolchains/zig_cc` Phase-A placeholder). See SYSTEM.md."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("//kernel/rust:defs.bzl", "release_wasm")

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

McProgramInfo = provider(
    doc = "A stamped, attested mc guest program — the load-ready wasm plus its declared metadata, " +
          "so downstream rules (images, service manifests) read tier/budget from the graph rather " +
          "than re-parsing the wasm.",
    fields = {
        "wasm": "The stamped .wasm File (mc_tier + mc_budget custom sections appended).",
        "tier": "The capability tier string (isolated / read-only / read-write / full).",
        "budget": "struct(mem, fuel, table) — the declared resource budget (VISION §16.5).",
        "service": "The mc_service name if this is a resident service (VISION §6), else \"\".",
    },
)

def _mc_program_impl(ctx):
    # 1. STAMP — append the kernel's load-time mc_tier + mc_budget custom sections. The Rust boxes
    #    emit these via declare_tier!/declare_budget!; the zig/C++ tools cannot (Zig's linksection
    #    makes a data segment, not a custom section), so //tools/mc-stamp does it post-link.
    stamped = ctx.actions.declare_file(ctx.label.name + ".wasm")
    ctx.actions.run(
        outputs = [stamped],
        inputs = [ctx.file.wasm],
        executable = ctx.executable._stamp,
        arguments = [
            ctx.file.wasm.path,
            stamped.path,
            ctx.attr.tier,
            ctx.attr.mem,
            ctx.attr.fuel,
            ctx.attr.table,
            ctx.attr.service,  # "" → no mc_service section; a name → stamp it (resident service, VISION §6)
        ],
        mnemonic = "McStamp",
        progress_message = "Stamping mc guest %{label}",
    )

    # 2. ATTEST — §9.3 import purity + §16.4 tier-cap fit, as a VALIDATION action: Bazel runs it for
    #    every target built (--run_validations, on by default) and fails the build on a violation,
    #    WITHOUT being an input to the stamped wasm. Attestation is a check on the artifact, not a
    #    transform of it, so the graph says exactly that — conformance enforced as a graph edge, not
    #    a shell `&&` hidden in a genrule cmd.
    attested = ctx.actions.declare_file(ctx.label.name + ".attested")
    ctx.actions.run_shell(
        outputs = [attested],
        inputs = [stamped],
        tools = [ctx.executable._attest],
        command = "{attest} {wasm} && touch {marker}".format(
            attest = ctx.executable._attest.path,
            wasm = stamped.path,
            marker = attested.path,
        ),
        mnemonic = "McAttest",
        progress_message = "Attesting mc guest %{label}",
    )

    return [
        DefaultInfo(files = depset([stamped])),
        McProgramInfo(
            wasm = stamped,
            tier = ctx.attr.tier,
            budget = struct(
                mem = int(ctx.attr.mem),
                fuel = int(ctx.attr.fuel),
                table = int(ctx.attr.table),
            ),
            service = ctx.attr.service,
        ),
        OutputGroupInfo(_validation = depset([attested])),
    ]

_mc_program = rule(
    implementation = _mc_program_impl,
    doc = "Stamp a zig/C++ domain-tool wasm with its mc_tier + mc_budget custom sections (VISION " +
          "§16.5) and attest it (§9.3 import purity + §16.4 tier-cap fit). Yields the load-ready " +
          "<name>.wasm + an McProgramInfo; a non-mc/unknown import or an over-tier syscall fails the build.",
    attrs = {
        "wasm": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The linked guest wasm to stamp + attest.",
        ),
        "tier": attr.string(mandatory = True, doc = "Capability tier (isolated/read-only/read-write/full)."),
        # Budgets are strings because attr.int caps at signed 32-bit but `fuel` is ~2e12; mc-stamp
        # parses them and the provider exposes them back as ints.
        "mem": attr.string(default = "0", doc = "Memory budget, bytes (0 = no mc_budget; the kernel default)."),
        "fuel": attr.string(default = "0", doc = "Fuel budget, interpreter steps (0 = the kernel default)."),
        "table": attr.string(default = "0", doc = "Table-elements budget (0 = the kernel default)."),
        "service": attr.string(default = "", doc = "Resident-service name → an mc_service section (VISION §6); \"\" for a one-shot tool."),
        "_stamp": attr.label(default = "//tools/mc-stamp", executable = True, cfg = "exec"),
        "_attest": attr.label(default = "//tools/mc-attest", executable = True, cfg = "exec"),
    },
)

def mc_program(name, wasm, tier, mem = 0, fuel = 0, table = 0, service = "", visibility = None):
    """Thin ergonomic wrapper over the `_mc_program` rule: takes INT budgets (e.g. 256 * 1024 * 1024)
    so call sites stay self-documenting, and forwards them as strings (attr.int is 32-bit; fuel is ~2e12).
    A 0 budget means "no mc_budget section" (the kernel default). `service` (optional) stamps the
    mc_service section marking a resident service (VISION §6). Used by the Zig/C++ lane (a pre-built
    `wasm`); the Rust lane wraps it via `mc_rust_program`."""
    _mc_program(
        name = name,
        wasm = wasm,
        tier = tier,
        mem = str(mem),
        fuel = str(fuel),
        table = str(table),
        service = service,
        visibility = visibility,
    )

def mc_rust_program(name, lib, tier, mem = 0, fuel = 0, table = 0, service = "", visibility = None):
    """A Rust guest PROGRAM, packaged uniformly with the Zig/C++ lane (VISION §16.5 / codex #1). A
    Rust `rust_binary` (`lib`) declares NO metadata in its source; this rule transitions it to opt +
    wasm32 (`release_wasm`), then stamps `mc_tier`/`mc_budget`/`mc_service` from the BUILD attributes
    and attests it (`mc_program`). So both guest lanes declare tier/budget/service ONCE — in the build
    graph, not the source — every guest is `mc-attest`ed, and the `McProgramInfo` provider carries the
    metadata for downstream image/manifest rules. `release_wasm` stays the kernel-only transition; this
    is its userland counterpart."""
    release_wasm(
        name = name + "_opt",
        lib = lib,
        platform = "//platforms:wasm32_freestanding",
    )
    mc_program(
        name = name,
        wasm = ":" + name + "_opt",
        tier = tier,
        mem = mem,
        fuel = fuel,
        table = table,
        service = service,
        visibility = visibility,
    )

def _mc_service_layer_impl(ctx):
    # Read the service NAME from each target's McProgramInfo (the graph), not by re-parsing the wasm.
    # mc-svc-manifest then writes /bin/<service> for both the install and the manifest's "binary" field
    # from that one name, and asserts the binary's own stamped mc_service matches — so the install path,
    # the manifest, and the artifact can never disagree (codex #2).
    tar = ctx.actions.declare_file(ctx.label.name + ".tar")
    args = [tar.path]
    inputs = []
    for policy, targets in [("eager", ctx.attr.eager), ("lazy", ctx.attr.lazy)]:
        for t in targets:
            info = t[McProgramInfo]
            if not info.service:
                fail("mc_service_layer: {} has no mc_service — not a resident service".format(t.label))
            args.extend([info.service, policy, info.wasm.path])
            inputs.append(info.wasm)
    if not inputs:
        fail("mc_service_layer: at least one eager or lazy service is required")
    ctx.actions.run(
        outputs = [tar],
        inputs = inputs,
        executable = ctx.executable._manifest,
        arguments = args,
        mnemonic = "McSvcLayer",
        progress_message = "Building the service layer %{label}",
    )
    return [DefaultInfo(files = depset([tar]))]

mc_service_layer = rule(
    implementation = _mc_service_layer_impl,
    doc = "Build a resident-service LAYER tar (codex #2): every service's stamped binary installed at " +
          "/bin/<service> PLUS the /etc/services.json that activates them, both derived from the targets' " +
          "McProgramInfo.service — so the install path and the manifest's binary field are written ONCE " +
          "and cannot drift, and the manifest is graph-derived rather than hand-written beside the image. " +
          "`eager` services start at boot; `lazy` ones on the first svc_connect. Merge into an image with " +
          "pkg_tar(deps = [..., \":<name>\"]).",
    attrs = {
        "eager": attr.label_list(providers = [McProgramInfo], doc = "Services activated at boot."),
        "lazy": attr.label_list(providers = [McProgramInfo], doc = "Services activated on the first svc_connect."),
        "_manifest": attr.label(default = "//tools/mc-svc-manifest", executable = True, cfg = "exec"),
    },
)
