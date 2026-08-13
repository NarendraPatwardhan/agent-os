# Git engine boundary

The Git subsystem is one backend-generic Zig engine over Gitz, compiled into two host artifacts:

- `git_engine.wasm`: zero-import `wasm32-freestanding` for JavaScript/browser hosts, backed by
  `memory.Storage` and `fs.Mem`;
- `git-engine`: a native executable supervised as a BEAM Port, backed by filesystem storage and
  `fs.Os` rooted at the host-authorized repository directory.

Both artifacts use the generated binary contract from `memcontainers/contracts/git.kdl`. The scalar
Wasm exports and native length-prefixed carrier contain no Git semantics. TLS, credentials, connection
authorization, HTTP, and durable placement remain host effects; repository, worktree, object, ref,
pack, and Git wire behavior belong to the shared engine and Gitz.

## Preserve, redesign, delete

| Concern | Rule |
| --- | --- |
| `CAP_NET`, origin policy, credentials, TLS, HTTP | Preserve in host adapters; credentials never enter engine memory. |
| Guest `/bin/git` and GitFs mount | Preserve product faces; relay typed generated operations only. |
| Durable repositories | Browser persists opaque engine images; native uses rooted filesystem storage. |
| Clone/fetch/pull/push | Resumable Gitz state machines yielding generic HTTP effects. |
| Engine protocol | Generated binary messages and generated AOGQ/AOGR envelopes only. |
| Errors/results | Stable typed records; CLI text is rendered outside the engine. |
| `ge_*`, C headers, JSON dispatch | Deleted; they are not compatibility contracts. |
| libgit2 and Emscripten/MEMFS | Deleted from the build and product graph. |
| Old Port frame types | Deleted; native framing is only `u32le length | generated envelope`. |
| Host pkt-line, wants/haves, refspec, sideband logic | Delete as the shared remote pump replaces it. |
| `.git/agentos/push.pack` IPC | Delete; binary data crosses bounded stream handles. |

Numeric opcodes, limits, message identifiers, status values, error domains, and envelope layout must not
be copied into handwritten host code. Update `git.kdl`, regenerate all projections, and run their drift
gates.

Native filesystem sessions use Gitz's root-anchored component walk with no-follow semantics. Reference
publication uses Gitz's durable journal and recovery before repository open; checkpoint invokes the
engine's recursive durability barrier. The BEAM production HTTP path spools request and response streams
to bounded temporary files, so packs are not assembled as one BEAM binary. Hosts map generated error
domain/code pairs to their native filesystem errors.

The browser release tar and server package both carry `share/licenses/gitz/LICENSE`. The server package's
`priv/package-manifest.json` binds its Git contract version, exact upstream commit, license requirement,
and SHA-256 file inventory.
