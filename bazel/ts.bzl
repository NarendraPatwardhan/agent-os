"""mc_ts_project — the repo's single ts_project wrapper.

Every TypeScript target compiles under one shared config (//:tsconfig) and emits .d.ts declarations:
the JS host (hosts/js), the @mc/* SDK (sdk-js/), and the generated contract descriptors
(contracts:*_ts). The JS host that consumes those generated env_ts/ctl_ts descriptors is exactly the
"ts compiler lane" the contracts codegen was written to wait for — so the boundary the kernel and the
Rust host derive from is the one the JS host derives from too (B2, no drift)."""

load("@aspect_rules_ts//ts:defs.bzl", "ts_project")

def mc_ts_project(name, **kwargs):
    """A ts_project pinned to //:tsconfig, declaration on. Pass srcs/deps/data as usual."""
    ts_project(
        name = name,
        tsconfig = kwargs.pop("tsconfig", "//:tsconfig"),
        declaration = kwargs.pop("declaration", True),
        **kwargs
    )
