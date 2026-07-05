"""Zig-kernel Asyncify packaging rule.

The Zig kernel uses Binaryen Asyncify to instrument only the embedded wasm3 call
chain and the thin syscall trampoline. This rule is deliberately Zig-only: Rust
uses wasmi's native resumability and never passes through Binaryen.
"""

def _asyncify_wasm_impl(ctx):
    src = ctx.file.src
    out = ctx.actions.declare_file(ctx.label.name + ".wasm")
    manifest = ctx.actions.declare_file(ctx.label.name + ".asyncify.txt")
    verbose = ctx.actions.declare_file(ctx.label.name + ".asyncify.verbose")
    only_list = ctx.actions.declare_file(ctx.label.name + ".asyncify.onlylist")
    remove_list = ctx.actions.declare_file(ctx.label.name + ".asyncify.removelist")

    ctx.actions.write(
        output = only_list,
        content = "\n".join(ctx.attr.only_list) + ("\n" if ctx.attr.only_list else ""),
    )
    ctx.actions.write(
        output = remove_list,
        content = "\n".join(ctx.attr.remove_list) + ("\n" if ctx.attr.remove_list else ""),
    )

    ctx.actions.run_shell(
        command = """
set -eu
export BINARYEN_CORES=1
ONLY_ARG=""
if [ -s "$5" ]; then
  ONLY_ARG="--pass-arg=asyncify-onlylist@@$5"
fi
REMOVE_ARG=""
if [ -s "$7" ]; then
  REMOVE_ARG="--pass-arg=asyncify-removelist@@$7"
fi
IMPORT_ARG=""
if [ "$8" = "1" ]; then
  IMPORT_ARG="--pass-arg=asyncify-ignore-imports"
fi
INDIRECT_ARG=""
if [ "$6" = "1" ]; then
  INDIRECT_ARG="--pass-arg=asyncify-ignore-indirect"
fi
# The kernel is built with -fno-strip so the wasm NAME SECTION survives: Binaryen's
# asyncify-onlylist matches wasm3's functions BY NAME (§7.4), and without names it
# instruments nothing (the suspend/resume silently becomes a no-op). -fno-strip ALSO emits
# DWARF that Binaryen's asyncify cannot parse ("Fatal: TODO: DW_LNE_define_file"), so strip
# DWARF FIRST while KEEPING names (-g), then asyncify the DWARF-free, still-named wasm (-g
# again, to carry the names into both the shipped artifact and the verbose no-creep stream).
PRE="$3.pre-asyncify.wasm"
"$1" --strip-dwarf -g "$2" -o "$PRE"
# Capture BOTH the verbose analysis (stdout) and Binaryen's warnings (stderr) into $4 so the
# no-creep gate can read them from a file: a "non-existing function name"/"non-matching
# pattern" warning means a remove_list entry (the catch frame or a host export) matched
# nothing — i.e. it would be instrumented and the unwind could escape. On a hard failure,
# surface $4 so the error is not swallowed.
"$1" "$PRE" -o "$3" -g --enable-bulk-memory --enable-nontrapping-float-to-int --asyncify $INDIRECT_ARG $IMPORT_ARG $ONLY_ARG $REMOVE_ARG --pass-arg=asyncify-verbose > "$4" 2>&1 || { cat "$4" >&2; exit 1; }
""",
        arguments = [
            ctx.file.wasm_opt.path,
            src.path,
            out.path,
            verbose.path,
            only_list.path,
            "1" if ctx.attr.ignore_indirect else "0",
            remove_list.path,
            "1" if ctx.attr.ignore_imports else "0",
        ],
        inputs = [src, only_list, remove_list],
        outputs = [out, verbose],
        tools = [ctx.file.wasm_opt],
        mnemonic = "AsyncifyWasm",
        progress_message = "Asyncifying %{input}",
    )
    ctx.actions.write(
        output = manifest,
        content = "\n".join([
            "mode=binaryen",
            "input=%s" % src.short_path,
            "tool=%s" % ctx.file.wasm_opt.short_path,
            "ignore_indirect=%s" % ctx.attr.ignore_indirect,
            "ignore_imports=%s" % ctx.attr.ignore_imports,
            "only_list:",
        ] + ["  %s" % fn for fn in ctx.attr.only_list] + [
            "remove_list:",
        ] + ["  %s" % fn for fn in ctx.attr.remove_list]) + "\n",
    )

    return [
        DefaultInfo(files = depset([out]), runfiles = ctx.runfiles(files = [out])),
        OutputGroupInfo(
            asyncify_manifest = depset([manifest]),
            asyncify_verbose = depset([verbose]),
        ),
    ]

asyncify_wasm = rule(
    implementation = _asyncify_wasm_impl,
    doc = "Package a Zig kernel wasm through the Asyncify transition seam.",
    attrs = {
        "src": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "The pre-Asyncify Zig kernel wasm.",
        ),
        "only_list": attr.string_list(
            doc = "Functions allowed to be Asyncify-instrumented. Empty until the wasm3 driver executes guests.",
        ),
        "remove_list": attr.string_list(
            doc = "Functions that must remain outside Asyncify instrumentation, usually internal driver boundaries.",
        ),
        "ignore_indirect": attr.bool(
            default = False,
            doc = "Pass asyncify-ignore-indirect when the suspend path is known to use direct calls only.",
        ),
        "ignore_imports": attr.bool(
            default = True,
            doc = "Pass asyncify-ignore-imports so Zig host imports do not widen the suspend graph.",
        ),
        "wasm_opt": attr.label(
            default = Label("@binaryen_linux_x86_64//:bin/wasm-opt"),
            allow_single_file = True,
            cfg = "exec",
            doc = "Binaryen wasm-opt executable.",
        ),
    },
)
