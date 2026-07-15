"""Repository-aware wrappers for formatters not modeled by rules_lint."""

def source_formatter(name, language, tool, data = []):
    """Creates matching write and check commands for one first-party language."""
    native.sh_binary(
        name = name,
        srcs = ["//tools/format:runner.sh"],
        args = [
            "write",
            "$(rlocationpath {})".format(tool),
            language,
        ],
        data = [tool] + data,
        deps = ["@bazel_tools//tools/bash/runfiles"],
    )
    native.sh_binary(
        name = name + ".check",
        srcs = ["//tools/format:runner.sh"],
        args = [
            "check",
            "$(rlocationpath {})".format(tool),
            language,
        ],
        data = [tool] + data,
        deps = ["@bazel_tools//tools/bash/runfiles"],
    )
