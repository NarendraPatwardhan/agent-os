# Binaryen

Binaryen is a host-only post-link WebAssembly optimizer. `MODULE.bazel` fetches the official pinned
version 130 Node distribution; this directory carries only its Bazel build definition, following B3's
vendor-less dependency rule. Neither Binaryen nor its license enters an AgentOS guest or image.

`//bazel/tools/wasm-opt` runs the portable `wasm-opt.js` under the hermetic rules_js Node toolchain.
`//bazel:wasm_opt.bzl` owns the single release policy and emits the artifact that metadata stamping,
capability attestation, size gates, and images consume.
