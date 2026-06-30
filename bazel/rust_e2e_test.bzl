"""e2e tests that boot the real kernel under an always-RELEASE host.

Your rule: every e2e runs release wasmtime, because a debug wasmtime JITs/instantiates
kernel.wasm an order of magnitude slower. `rust_e2e_test` makes that structural — it pins
the test's whole subgraph (the host lib, wasmtime, cranelift) to `compilation_mode=opt`
with a transition, exactly like the shipped `mc` (hosts/wasmtime/defs.bzl). No `-c opt`
anyone has to remember; `bazel test //memcontainers/tests/e2e:…` is release by construction.

The kernel.wasm keeps its own release_wasm transition (opt + wasm32), so the data-dep'd
kernel is unaffected; this transition only optimizes the native host the test links.
"""

load("//bazel:rust_opt_test.bzl", "rust_opt_test")

def rust_e2e_test(name, kernel = "//memcontainers/kernel/rust:kernel", size = "small", **kwargs):
    """A rust_test whose host subgraph (wasmtime) builds at compilation_mode=opt.

    Keep the WHOLE suite in ONE such target. Measured: the host compiles kernel.wasm once
    per process (~0.9s, cranelift) and every boot after that is ~1.6ms (MODULE_CACHE), so a
    single binary runs the entire suite in ~1s. Splitting into many targets would re-pay the
    ~0.9s compile each time — the one thing to NOT do given the sub-second-per-test bar.

    `kernel` is the kernel.wasm under test: a data-dep whose RUNFILES path the suite reads
    from the MC_KERNEL_WASM env. So the SAME source boots ANY kernel — the Rust kernel by
    default, the Zig kernel under the B7 parity gate — by pointing `kernel` elsewhere,
    with no edit to the tests. This is the lever that makes the suite the shared parity oracle.
    """
    data = kwargs.pop("data", []) + [kernel]
    env = dict(kwargs.pop("env", {}))
    env["MC_KERNEL_WASM"] = "$(rlocationpath %s)" % kernel
    rust_opt_test(name = name, size = size, data = data, env = env, **kwargs)
