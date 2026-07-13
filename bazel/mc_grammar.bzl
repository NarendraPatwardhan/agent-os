"""Hermetic .grammar -> generated parser artifacts (SYSTEMS.md B1/B3)."""

McGrammarInfo = provider(
    fields = {
        "grammar_json": "Normalized Tree-sitter grammar JSON.",
        "semantics": "AgentOS concrete-to-semantic projection.",
        "language": "Stable runtime language name.",
    },
)

def _mc_grammar_impl(ctx):
    root = ctx.file.root
    module_inputs = []
    module_args = []
    for target, module_id in sorted(ctx.attr.modules.items(), key = lambda item: item[1]):
        files = target.files.to_list()
        if len(files) != 1:
            fail("mc_grammar module %s must provide exactly one file" % target.label)
        module_inputs.append(files[0])
        module_args.extend(["--module", "%s=%s" % (module_id, files[0].path)])

    outs = struct(
        ir = ctx.actions.declare_file(ctx.label.name + "/grammar.ir.json"),
        grammar_json = ctx.actions.declare_file(ctx.label.name + "/grammar.json"),
        semantics = ctx.actions.declare_file(ctx.label.name + "/semantics.json"),
        diagnostics = ctx.actions.declare_file(ctx.label.name + "/diagnostics.json"),
    )
    args = ctx.actions.args()
    args.add_all(["--root", root.path])
    args.add_all(module_args)
    args.add_all(["--ir", outs.ir.path, "--grammar-json", outs.grammar_json.path])
    args.add_all(["--semantics", outs.semantics.path, "--diagnostics", outs.diagnostics.path])
    all_outputs = [outs.ir, outs.grammar_json, outs.semantics, outs.diagnostics]
    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = [args],
        inputs = depset([root] + module_inputs),
        outputs = all_outputs,
        mnemonic = "McGrammarGen",
        progress_message = "Generating parser %{label}",
    )
    return [
        DefaultInfo(files = depset(all_outputs)),
        McGrammarInfo(
            grammar_json = outs.grammar_json,
            semantics = outs.semantics,
            language = ctx.attr.language,
        ),
        OutputGroupInfo(
            semantics = depset([outs.semantics]),
            inspection = depset([outs.ir, outs.grammar_json, outs.diagnostics]),
        ),
    ]

mc_grammar = rule(
    implementation = _mc_grammar_impl,
    attrs = {
        "root": attr.label(allow_single_file = [".grammar"], mandatory = True),
        "modules": attr.label_keyed_string_dict(allow_files = [".grammar"]),
        "language": attr.string(mandatory = True),
        "_generator": attr.label(default = "//bazel/tools/mc-grammar-gen:mc-grammar-gen", executable = True, cfg = "exec"),
    },
)

McSyntaxPackInfo = provider(
    fields = {
        "csrcs": "Generated per-language parsers plus the shared immutable table pool.",
        "registry_zig": "Generated native language and semantic registry.",
        "report": "Deterministic parser sharing report.",
    },
)

def _mc_syntax_pack_impl(ctx):
    tables_c = ctx.actions.declare_file(ctx.label.name + "/shared_tables.c")
    registry_zig = ctx.actions.declare_file(ctx.label.name + "/registry.zig")
    report = ctx.actions.declare_file(ctx.label.name + "/report.json")
    parsers = []
    node_types = []
    manifests = []
    inputs = []
    args = ctx.actions.args()
    grammars = sorted([target[McGrammarInfo] for target in ctx.attr.grammars], key = lambda info: info.language)
    for grammar in grammars:
        parser = ctx.actions.declare_file(ctx.label.name + "/" + grammar.language + "/parser.c")
        nodes = ctx.actions.declare_file(ctx.label.name + "/" + grammar.language + "/node-types.json")
        manifest = ctx.actions.declare_file(ctx.label.name + "/" + grammar.language + "/manifest.json")
        args.add_all([
            "--language",
            grammar.language,
            grammar.grammar_json.path,
            grammar.semantics.path,
            parser.path,
            nodes.path,
            manifest.path,
        ])
        inputs.extend([grammar.grammar_json, grammar.semantics])
        parsers.append(parser)
        node_types.append(nodes)
        manifests.append(manifest)
    args.add_all(["--tables-c", tables_c.path, "--registry-zig", registry_zig.path, "--report", report.path])
    outputs = [tables_c, registry_zig, report] + parsers + node_types + manifests
    ctx.actions.run(
        executable = ctx.executable._packer,
        arguments = [args],
        inputs = depset(inputs),
        outputs = outputs,
        mnemonic = "McSyntaxPack",
        progress_message = "Packing syntax parsers %{label}",
    )
    return [
        DefaultInfo(files = depset(outputs)),
        McSyntaxPackInfo(csrcs = depset([tables_c] + parsers), registry_zig = registry_zig, report = report),
        OutputGroupInfo(
            csrcs = depset([tables_c] + parsers),
            registry_zig = depset([registry_zig]),
            node_types = depset(node_types),
            manifests = depset(manifests),
            report = depset([report]),
        ),
    ]

mc_syntax_pack = rule(
    implementation = _mc_syntax_pack_impl,
    attrs = {
        "grammars": attr.label_list(providers = [McGrammarInfo], mandatory = True),
        "_packer": attr.label(default = "//bazel/tools/mc-grammar-gen:mc-syntax-pack", executable = True, cfg = "exec"),
    },
)
