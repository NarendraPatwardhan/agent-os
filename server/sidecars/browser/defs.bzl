"""Hermetic conversion from a rules_oci image layout to a Firecracker initramfs."""

def _browser_initramfs_impl(ctx):
    image = ctx.file.image
    output = ctx.actions.declare_file(ctx.attr.name + ".cpio")
    coreutils = ctx.toolchains["@aspect_bazel_lib//lib:coreutils_toolchain_type"]
    jq = ctx.toolchains["@aspect_bazel_lib//lib:jq_toolchain_type"]

    ctx.actions.run_shell(
        inputs = [image],
        outputs = [output],
        tools = [
            ctx.executable._mkinitramfs,
            ctx.executable._umoci,
            coreutils.coreutils_info.bin,
            jq.jqinfo.bin,
        ],
        arguments = [
            image.path,
            output.path,
            coreutils.coreutils_info.bin.path,
            jq.jqinfo.bin.path,
            ctx.executable._umoci.path,
            ctx.executable._mkinitramfs.path,
        ],
        command = """
set -eu
image="$1"
output="$2"
coreutils="$3"
jq="$4"
umoci="$5"
mkinitramfs="$6"
work="$("$coreutils" mktemp -d "${TMPDIR:-/tmp}/agentos-browser.XXXXXX")"
trap '"$coreutils" rm -rf "$work"' EXIT
layout="$work/oci"
bundle="$work/bundle"
"$coreutils" mkdir -p "$layout"
"$coreutils" cp -R "$image/." "$layout/"
"$jq" '.manifests[0].annotations["org.opencontainers.image.ref.name"] = "latest"' \
  "$layout/index.json" > "$layout/index.tagged.json"
"$coreutils" mv "$layout/index.tagged.json" "$layout/index.json"
"$umoci" unpack --rootless --image "$layout:latest" "$bundle"
"$mkinitramfs" --root "$bundle/rootfs" "$output"
""",
        mnemonic = "BrowserInitramfs",
        progress_message = "Building Firecracker browser initramfs %{label}",
    )
    return DefaultInfo(files = depset([output]))

browser_initramfs = rule(
    implementation = _browser_initramfs_impl,
    attrs = {
        "image": attr.label(allow_single_file = True, mandatory = True),
        "_mkinitramfs": attr.label(
            default = "//server/sidecars/runner:mkinitramfs",
            executable = True,
            cfg = "exec",
        ),
        "_umoci": attr.label(
            default = "@umoci//file",
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@aspect_bazel_lib//lib:coreutils_toolchain_type",
        "@aspect_bazel_lib//lib:jq_toolchain_type",
    ],
)
