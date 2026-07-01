"""gh_release — `bazel run` a GitHub release straight from the build graph (REST API, no `gh` CLI).

A release is a side-effecting DEPLOY, not a hermetic build: it talks to api.github.com +
uploads.github.com over HTTPS, mutating a GitHub repo. So it is a `bazel run` target (client env,
network) wrapping a node uploader (publish.mjs) — node's bundled TLS + CA roots make it zero-dep and
as hermetic as a network tool gets (the node binary is the pinned rules_js toolchain, node 22).

The assets are ordinary graph outputs — the deterministic, content-addressed kernel.wasm + flavor
tars (fixed mtime/uid/gid → byte-identical per commit, so a release's bytes are reproducible). Each
rides in as a runfile; the macro hands the tool a name→runfiles-path map via one env var
(MC_RELEASE_ASSETS), each path produced by `$(rlocationpath ...)` — the SAME runfiles resolution the
JS host's e2e uses (hosts/js parity_test), so what is uploaded can't drift from the data-deps (B1).

Like //bazel/tools/size, this is a tool-scoped Starlark macro: consumers just
`load("//bazel/tools/gh-release:defs.bzl", "gh_release")`.

Usage:
    gh_release(
        name = "publish",
        repo = "NarendraPatwardhan/agent-os",
        assets = {
            "//memcontainers/kernel/rust:kernel": "kernel.wasm",
            "//memcontainers/images:minimal":     "minimal.tar",
            ...
        },
    )

The tool also generates a `sha256sum -c`-compatible SHA256SUMS over the uploaded bytes and ships it
as an extra asset. Release notes are mandatory (--notes / --notes-file); GitHub auto-generated notes
are never used.

    GITHUB_TOKEN=... bazel run //bazel/tools/gh-release:publish -- --tag v0.3.0 --notes-file NOTES.md [--draft]
    bazel run //bazel/tools/gh-release:publish -- --tag v0.3.0 --notes "..." --dry-run   # validate, no network
"""

load("@aspect_rules_js//js:defs.bzl", "js_binary")

def gh_release(name, repo, assets, entry_point = "publish.mjs", **kwargs):
    """A `bazel run` GitHub-release publisher over the REST API.

    Args:
      name: target name (`bazel run //bazel/tools/gh-release:<name>`).
      repo: "owner/repo" the release is cut on.
      assets: dict of {Bazel label: asset filename}. Each label must produce exactly ONE file; that
        file is uploaded under the given name. All are deterministic graph outputs.
      entry_point: the node uploader (default //bazel/tools/gh-release:publish.mjs).
      **kwargs: forwarded to the underlying js_binary (visibility, tags, ...).
    """

    # name → $(rlocationpath) map, expanded by Bazel from each asset's runfiles path. One env var
    # carries the whole map as JSON; expand_location replaces every $(rlocationpath ...) token in it.
    asset_map = {filename: "$(rlocationpath %s)" % label for label, filename in assets.items()}

    js_binary(
        name = name,
        entry_point = entry_point,
        data = assets.keys(),
        env = {
            "MC_RELEASE_REPO": repo,
            "MC_RELEASE_ASSETS": json.encode(asset_map),
        },
        **kwargs
    )
