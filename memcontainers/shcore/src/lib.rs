//! `shcore` — agent-os's OS-agnostic, POSIX-ish shell: a front-end (lexer +
//! parser) and a blocking executor, decoupled from the world by the `ShellOs`
//! trait (`os.rs`). It backs the wasm32 guest `/bin/sh`.
//!
//! Because the pure layers — lexing, parsing, expansion, arithmetic, globbing —
//! touch no syscalls, they are the ONE place agent-os keeps native unit tests
//! (SYSTEMS.md). The kernel cannot run natively (A2), so everywhere else there is
//! nothing to unit-test in isolation; integrated behaviour is driven through the
//! real kernel by the e2e suite (B6). That split is structural here:
//!
//!   - `no_std` for the guest build (the shell is a wasm32 guest, A6);
//!   - `std` only under `cfg(test)`, so the pure layers run on the host test
//!     runner. The OS-touching executor is validated end-to-end, never mocked.
//!
//! Ported from memcontainers `crates/shcore` (Step 2). Shell semantics — quoting,
//! expansion order, IFS splitting, control flow — are subtle and are preserved
//! exactly; the framing is agent-os's and every layer is Bazel-native with its own
//! tests. Constants shared with the kernel ABI are drift-checked against
//! `//contracts:constants_rust` rather than re-asserted by hand (B2).
//!
//! Port complete: front-end (`word`, `token`, `ast`, `parser`), expansion (`expand`,
//! `glob`, `arith`), the OS seam (`os`), and the tree-walking executor (`exec`).
#![cfg_attr(not(test), no_std)]

extern crate alloc;

pub mod arith;
pub mod ast;
pub mod echo;
pub mod exec;
pub mod expand;
pub mod glob;
pub mod os;
pub mod parser;
pub mod printf;
pub mod testexpr;
pub mod token;
pub mod word;

pub use ast::Script;
pub use exec::{Flow, Interp};
pub use expand::ExpandCtx;
pub use os::{Fd, FileStat, OsError, Pid, ShellOs, Signal};
pub use parser::{parse, ParseError};
pub use token::{tokenize, LexError, Operator, Token};
pub use word::{ParamOp, Word, WordPart};
