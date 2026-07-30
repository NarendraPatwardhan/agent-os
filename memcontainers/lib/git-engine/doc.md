# Host git engine package (GIT.md)

**PR0:** hermetic packaging only — link smoke against BCR libgit2 under zig-cc
(`hermetic_cc_toolchain`). No Run ABI / porcelain yet (PR1).

| Later PR | Content |
|----------|---------|
| PR1 | `ge_*` Run facade + fixtures |
| PR2 | emcc `git_engine.wasm` + monorepo `wasm_opt` + size gate |
| PR7 | native `git-engine` Port for BEAM |

See workspace-root `GIT.md` for architecture (libgit2, no go-git, no freestanding
product path).
