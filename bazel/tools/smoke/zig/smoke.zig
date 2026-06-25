//! Bootstrap smoke guest — proves the wasm32-freestanding Zig 0.16 toolchain works
//! in this repo (see BUILD.bazel). It is NOT part of the system: the real guests
//! live in programs/ and the kernels in kernel/. One exported function is enough to
//! force real codegen and a link to a `.wasm` binary through the same transition
//! every kernel and guest will use. Delete once those provide real wasm
//! targets to anchor `bazel test //...`.

export fn add(a: i32, b: i32) i32 {
    return a +% b;
}
