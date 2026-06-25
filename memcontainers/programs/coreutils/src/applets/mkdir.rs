//! `mkdir [OPTION]... DIRECTORY...` — create directories. `-p`/`--parents` creates any missing
//! parents and treats an already-existing target as success (rather than an error); `-m`/`--mode`
//! `MODE` sets the new directory's permission bits (octal) instead of the kernel default. With
//! `-m`, only the final component's mode is set — parents created by `-p` keep the default mode
//! (matching GNU). No output on success; errors are GNU-style.
//!
//! Flags: `-p`/`--parents`, `-m`/`--mode MODE`. Args+help are via clap; the directory creation
//! goes through `crate::fsutil::mkdir_p` (for `-p`) / `rt::mkdir`, and the mode through
//! `rt::chmod`.
//!
//! Deviations from GNU mkdir: MODE is OCTAL ONLY (`755`, `0644`) — symbolic modes (`u+x`) are NOT
//! accepted; `-v`/`--verbose` and `-Z`/`--context` are NOT implemented.
//!
//! Exit status: `0` all directories created; `1` a directory could not be created (or its mode
//! could not be set); `2` a usage error, including an invalid MODE (clap).
//!
//! Ported from memcontainers' `programs::mkdir`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use crate::prelude::*;
use sysroot as rt;

/// Parse an octal mode string (`"755"`, `"0644"`) into permission bits, or `None` if it is not
/// all octal digits.
fn parse_octal_mode(s: &[u8]) -> Option<u16> {
    if s.is_empty() || !s.iter().all(|b| (b'0'..=b'7').contains(b)) {
        return None;
    }
    let mut m: u16 = 0;
    for &b in s {
        m = m.checked_mul(8)?.checked_add((b - b'0') as u16)?;
    }
    Some(m & 0o7777)
}

/// The clap command — the single source of `mkdir`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("mkdir")
        .about("Create the DIRECTORY(ies), if they do not already exist.")
        .arg(
            Arg::new("parents")
                .short('p')
                .long("parents")
                .action(ArgAction::SetTrue)
                .help("no error if existing, make parent directories as needed"),
        )
        .arg(
            Arg::new("mode")
                .short('m')
                .long("mode")
                .num_args(1)
                .value_name("MODE")
                .help("set file mode (as in chmod), octal only (default 0755)"),
        )
        .arg(
            Arg::new("DIRECTORY")
                .action(ArgAction::Append)
                .num_args(0..)
                .help("the directories to create"),
        )
}

/// `mkdir [OPTION]... DIRECTORY...`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let parents = m.get_flag("parents");
    let mode = match m.get_one::<String>("mode") {
        Some(spec) => match parse_octal_mode(spec.as_bytes()) {
            Some(v) => Some(v),
            None => {
                eprintln!("mkdir: invalid mode: {}", spec);
                return 1;
            }
        },
        None => None,
    };
    let ops: Vec<&str> = m
        .get_many::<String>("DIRECTORY")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("mkdir: missing operand");
        return 1;
    }

    let mut rc = 0;
    for path in &ops {
        let res = if parents {
            fsutil::mkdir_p(path)
        } else {
            rt::mkdir(path)
        };
        match res {
            Ok(()) => {
                // `-m` sets the new directory's mode (the final component only,
                // matching GNU; parents created by `-p` keep the default).
                if let Some(md) = mode {
                    if let Err(e) = rt::chmod(path, md) {
                        eprintln!("mkdir: {}: {}", path, rt::strerror(e));
                        rc = 1;
                    }
                }
            }
            Err(e) => {
                eprintln!("mkdir: {}: {}", path, rt::strerror(e));
                rc = 1;
            }
        }
    }
    rc
}
