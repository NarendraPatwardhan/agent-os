//! The `echo` rendering logic — pure, no OS.
//!
//! Shared by the `echo` builtin (`exec.rs`) and the `/bin/echo` tool (`programs/`),
//! so the leading-flag parsing (`-neE`), the `-e` escape set, and the LF line ending
//! live once and stay identical between the two (B2 in spirit).
//!
//! POSIX/XSI `echo`: only leading `-n`/`-e`/`-E` tokens (combinable, e.g. `-ne`) are
//! options; everything after the first non-flag is printed. `\n` is a literal LF (the
//! terminal adds CR via ONLCR), and `\c` (under `-e`) stops all further output.

use alloc::string::String;
use alloc::vec::Vec;

/// Render an `echo` invocation (`args` is the words after `echo`) into the exact
/// bytes to write — including the trailing newline unless suppressed by `-n` or `\c`.
pub fn render(args: &[String]) -> Vec<u8> {
    let mut newline = true;
    let mut escapes = false;
    let mut start = 0;
    // Leading `-n` / `-e` / `-E` flags (combinable, e.g. `-ne`).
    while let Some(a) = args.get(start) {
        let b = a.as_bytes();
        if b.len() >= 2 && b[0] == b'-' && b[1..].iter().all(|c| matches!(c, b'n' | b'e' | b'E')) {
            for &c in &b[1..] {
                match c {
                    b'n' => newline = false,
                    b'e' => escapes = true,
                    b'E' => escapes = false,
                    _ => {}
                }
            }
            start += 1;
        } else {
            break;
        }
    }
    let mut out: Vec<u8> = Vec::new();
    let mut stopped = false;
    for (i, a) in args[start..].iter().enumerate() {
        if i > 0 {
            out.push(b' ');
        }
        if escapes {
            let (bytes, stop) = unescape(a);
            out.extend_from_slice(&bytes);
            if stop {
                stopped = true;
                break;
            }
        } else {
            out.extend_from_slice(a.as_bytes());
        }
    }
    if newline && !stopped {
        // Emit LF; the terminal adds the CR (ONLCR), so files/pipes stay LF.
        out.push(b'\n');
    }
    out
}

/// Interpret `echo -e` backslash escapes, returning the decoded bytes and whether
/// `\c` (stop all further output) was encountered.
fn unescape(s: &str) -> (Vec<u8>, bool) {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 1 < b.len() {
            match b[i + 1] {
                b'n' => out.push(b'\n'),
                b't' => out.push(b'\t'),
                b'r' => out.push(b'\r'),
                b'\\' => out.push(b'\\'),
                b'a' => out.push(0x07),
                b'b' => out.push(0x08),
                b'f' => out.push(0x0c),
                b'v' => out.push(0x0b),
                b'0' => out.push(0),
                b'c' => return (out, true),
                other => {
                    out.push(b'\\');
                    out.push(other);
                }
            }
            i += 2;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    (out, false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::string::ToString;
    use alloc::vec::Vec;

    fn e(args: &[&str]) -> String {
        let v: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        String::from_utf8_lossy(&render(&v)).into_owned()
    }

    #[test]
    fn plain_and_spacing() {
        assert_eq!(e(&["hi"]), "hi\n");
        assert_eq!(e(&["a", "b", "c"]), "a b c\n");
        assert_eq!(e(&[]), "\n");
    }

    #[test]
    fn n_flag_suppresses_newline() {
        assert_eq!(e(&["-n", "hi"]), "hi");
        assert_eq!(e(&["-ne", "x\\ty"]), "x\ty");
    }

    #[test]
    fn e_flag_escapes_and_capital_e_disables() {
        assert_eq!(e(&["-e", "a\\tb"]), "a\tb\n");
        assert_eq!(e(&["-E", "a\\tb"]), "a\\tb\n");
        assert_eq!(e(&["a\\tb"]), "a\\tb\n"); // default: no escapes
    }

    #[test]
    fn c_stops_output_and_newline() {
        assert_eq!(e(&["-e", "ab\\cde", "fg"]), "ab");
    }

    #[test]
    fn non_flag_first_word_ends_option_scan() {
        // `-x` is not a -neE flag, so it (and everything after) is printed.
        assert_eq!(e(&["-x", "y"]), "-x y\n");
    }
}
