//! The facade prelude for HAND-WRITTEN applets — pulled in with `use crate::prelude::*`,
//! paired with `use sysroot as rt` for the raw mc wrappers. This is the mc-shaped I/O uucore
//! does not provide (VISION §16.3); a uutils applet (`uu_base64`) or an external-crate applet
//! (`grep` over ripgrep) does not touch it — they bring their own clap/uucore/std I/O.

// A re-export hub: not every applet uses every facade helper (the slice's cat uses only
// `BufOut`), so unused re-exports here are expected as more applets land.
#![allow(unused_imports)]

pub use crate::textio::{self, BufOut, LineReader};
pub use crate::{fsutil, spool};
