load("@rules_zig//zig:defs.bzl", "zig_binary", "zig_configure_binary", "zig_library")

def coreutils_box(name, tier, tier_section, set_kind, srcs):
    zig_library(
        name = name + "_build_options",
        main = "src/build_options/%s_%s.zig" % (tier, set_kind),
        import_name = "build_options",
        tags = ["manual"],
    )

    zig_binary(
        name = name + "_raw",
        main = "src/main.zig",
        srcs = srcs,
        linkopts = [
            "-fno-entry",
            "-rdynamic",
        ],
        tags = ["manual"],
        deps = [
            ":" + name + "_build_options",
            "//memcontainers/sysroot/zig:sys",
        ],
    )

    zig_configure_binary(
        name = name + "_wasm",
        actual = ":" + name + "_raw",
        mode = "release_small",
        target = "//platforms:wasm32_freestanding",
        threaded = "single",
        tags = ["manual"],
    )

    native.genrule(
        name = name + "_applets",
        srcs = ["src/registry_data.zig"],
        outs = [name + ".applets"],
        tools = ["//bazel/tools/mc-applets"],
        cmd = "$(execpath //bazel/tools/mc-applets) $(location src/registry_data.zig) %s %s $@" % (tier, set_kind),
        tags = ["manual"],
    )

    native.genrule(
        name = name + "_opt",
        srcs = [
            ":" + name + "_wasm",
            ":" + name + "_applets",
        ],
        outs = [name + "_opt.wasm"],
        tools = ["//bazel/tools/mc-stamp"],
        cmd = "$(execpath //bazel/tools/mc-stamp) $(execpath :%s_wasm) $@ %s 0 0 0 '' $(execpath :%s_applets)" % (name, tier_section, name),
        visibility = ["//visibility:public"],
    )

    native.genrule(
        name = name + ".attest",
        srcs = [":" + name + "_opt"],
        outs = [name + ".attested"],
        tools = ["//bazel/tools/mc-attest"],
        cmd = "$(execpath //bazel/tools/mc-attest) $(execpath :%s_opt) && touch $@" % name,
    )

    native.genrule(
        name = name + "_symlinks",
        srcs = [":" + name + "_opt"],
        outs = [name + "_symlinks.tar"],
        tools = ["//bazel/tools/mc-roster"],
        cmd = "$(execpath //bazel/tools/mc-roster) $(execpath :%s_opt) %s $@" % (name, name),
        visibility = ["//visibility:public"],
    )
