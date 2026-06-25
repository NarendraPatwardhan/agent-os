"""A reusable B5 size-budget gate, as a Bazel rule — no shell script on disk.

Bazel learns an artifact's byte size only once it is BUILT (the execution phase — the file
does not exist at analysis), so the ceiling is enforced by a single build action that fails,
and so fails the wrapping test, when `file` exceeds `max_bytes`. Everything but the byte
count itself — the budget, the diagnostics, the test wiring — is Starlark.

Generic over the artifact: the always-opt kernel.wasm, a per-tier `mcbox` multicall binary,
a flavor layer tar. Generalized out of the kernel's original `kernel_size_limit` so
every shipped artifact wires its ceiling through ONE rule.
"""

load("@bazel_skylib//rules:build_test.bzl", "build_test")

def _size_limit_check_impl(ctx):
    f = ctx.file.file
    ok = ctx.actions.declare_file(ctx.label.name + ".ok")

    # The byte count is the one fact only the execution phase holds; the comparison and the
    # verdict are the rule's. A regression fails this action → fails the build → fails the
    # test. `wc -c` is the whole shell surface (Bazel has no native size assertion).
    ctx.actions.run_shell(
        inputs = [f],
        outputs = [ok],
        command = """set -euo pipefail
sz=$(wc -c < "{path}")
if [ "$sz" -gt "{max}" ]; then
  echo "{name}: $sz bytes — OVER the {max}-byte budget by $((sz - {max})). Optimize, or raise the budget deliberately." >&2
  exit 1
fi
echo "{name}: $sz bytes ({max}-byte budget, $(({max} - sz)) headroom)."
touch "{ok}"
""".format(path = f.path, max = ctx.attr.max_bytes, name = f.basename, ok = ok.path),
        mnemonic = "SizeLimit",
        progress_message = "Size-budget gate: %s" % f.short_path,
    )
    return [DefaultInfo(files = depset([ok]))]

_size_limit_check = rule(
    implementation = _size_limit_check_impl,
    attrs = {
        "file": attr.label(
            allow_single_file = True,
            mandatory = True,
            doc = "A label producing the single file to bound (a .wasm, a binary, a pkg_tar layer).",
        ),
        "max_bytes": attr.int(mandatory = True, doc = "The byte ceiling."),
    },
)

def size_limit(name, file, max_bytes):
    """Fail the build — and so `bazel test` — if `file` exceeds `max_bytes`."""
    _size_limit_check(
        name = name + ".check",
        file = file,
        max_bytes = max_bytes,
        tags = ["manual"],
    )
    build_test(name = name, targets = [":" + name + ".check"])
