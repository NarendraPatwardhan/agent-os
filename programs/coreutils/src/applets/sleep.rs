//! `sleep NUMBER[smhd]...` — suspend execution for the sum of the given durations. Each
//! NUMBER may be fractional (e.g. `1.5`); the optional one-letter suffix is `s` (seconds, the
//! default), `m` (minutes), `h` (hours), or `d` (days). With multiple operands sleep waits for
//! their sum. Backed by the `mc` `sleep_ms` syscall (millisecond resolution).
//!
//! Flags: none beyond `--help`/`--version` (GNU `sleep` takes only operands).
//!
//! Deviations from GNU: sub-millisecond fractions are truncated to millisecond resolution; no
//! locale or units beyond `s`/`m`/`h`/`d`. A long total is chunked across multiple `sleep_ms`
//! calls (the syscall takes an `i32` ms count).
//!
//! Exit status: 0 on success; 1 if a NUMBER is not a valid time interval; 2 on a usage error
//! (no operand). Uses the ambient clock (`sleep_ms`) → tier_readonly (CAP_AMBIENT).
//!
//! Ported from memcontainers' `programs::sleep`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// Parse one `NUMBER[suffix]` operand into milliseconds. `None` if malformed or overflowing.
fn parse_ms(b: &[u8]) -> Option<u64> {
    let (num, mult) = match b.last() {
        Some(b's') => (&b[..b.len() - 1], 1u64),
        Some(b'm') => (&b[..b.len() - 1], 60),
        Some(b'h') => (&b[..b.len() - 1], 3600),
        Some(b'd') => (&b[..b.len() - 1], 86400),
        _ => (b, 1),
    };
    if num.is_empty() {
        return None;
    }
    let (mut int, mut frac, mut fdig, mut dot) = (0u64, 0u64, 0u32, false);
    for &c in num {
        if c == b'.' {
            if dot {
                return None;
            }
            dot = true;
            continue;
        }
        if !c.is_ascii_digit() {
            return None;
        }
        let d = (c - b'0') as u64;
        if !dot {
            int = int.checked_mul(10)?.checked_add(d)?;
        } else if fdig < 3 {
            frac = frac * 10 + d;
            fdig += 1;
        }
    }
    while fdig < 3 {
        frac *= 10;
        fdig += 1;
    }
    // (int.frac seconds-in-unit) → ms: (int*1000 + frac) * mult.
    Some((int.checked_mul(1000)?.checked_add(frac)?).checked_mul(mult)?)
}

/// The clap command — the single source of `sleep`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("sleep")
        .about("Pause for NUMBER seconds, where NUMBER is an integer or floating-point with an optional suffix: s for seconds (the default), m for minutes, h for hours, d for days. With several arguments, pause for the sum of their values.")
        .arg(Arg::new("DURATION").action(ArgAction::Append).num_args(1..).help("time to sleep, e.g. 5, 2.5m, 1h, 100ms-style is unsupported (use s/m/h/d)"))
}

/// `sleep DURATION...`. Returns the exit status (0 success; 1 a bad interval; 2 usage error).
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        // clap prints help/usage/version itself; mirror its exit code (0 for --help/--version).
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let ops: Vec<&str> = m
        .get_many::<String>("DURATION")
        .map(|v| v.map(String::as_str).collect())
        .unwrap_or_default();
    if ops.is_empty() {
        eprintln!("sleep: missing operand");
        return 2;
    }

    let mut total: u64 = 0;
    for o in &ops {
        match parse_ms(o.as_bytes()) {
            Some(ms) => total = total.saturating_add(ms),
            None => {
                eprintln!("sleep: invalid time interval '{}'", o);
                return 1;
            }
        }
    }

    // mc sleep_ms takes an i32; chunk long sleeps so the full duration is honored.
    while total > 0 {
        let chunk = total.min(i32::MAX as u64);
        let _ = rt::sleep_ms(chunk as i32);
        total -= chunk;
    }
    0
}
