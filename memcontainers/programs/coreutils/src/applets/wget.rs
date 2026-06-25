//! `wget [-O FILE] URL` — retrieve a URL over HTTP. A real HTTP client guest: it calls
//! `rt::http_get`, which hands back a readable fd backed by the response body, and streams that
//! body to standard output (or to `-O FILE`). The kernel performs the request and the host
//! terminates TLS; the guest never sees a socket or the host handle.
//!
//! Network access is gated: without the NET capability (`--allow-net`), the syscall returns
//! `EPERM` and `wget` reports "network unavailable". This makes the applet `tier_full` (NET).
//!
//! Flags: `-O FILE`/`--output-document=FILE` (write to FILE; `-` means standard output).
//! Deviations from GNU `wget`: this is a minimal client — there is no `-o` (log file), `-P`
//! (prefix), `-c` (continue), `-q` (quiet), `--method`, or `--header`; no recursion
//! (`-r`/`-np`/`-l`), no robots handling, and no redirect following. The body-only fd model
//! means the guest does not observe the HTTP status line. The first non-flag argument is the URL.
//! (`-O` is an addition over the memcontainers original, which always wrote to stdout.)
//!
//! Exit status: `0` the body was retrieved; `1` transport failure, network unavailable, or the
//! output file could not be opened; `2` usage error (no URL).
//!
//! Ported from memcontainers' `programs::wget`.

use clap::{Arg, Command};

use sysroot as rt;

/// The clap command — the single source of `wget`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("wget")
        .about("Retrieve a URL over HTTP and write the response body to standard output (or -O FILE).")
        .override_usage("wget [-O FILE] URL")
        .arg(
            Arg::new("output-document")
                .short('O')
                .long("output-document")
                .num_args(1)
                .value_name("FILE")
                .help("write the body to FILE instead of standard output (- means stdout)"),
        )
        .arg(
            Arg::new("URL")
                .required(true)
                .value_name("URL")
                .help("the http(s) URL to retrieve"),
        )
}

/// Stream the response-body fd `fd` to the output fd `out`. Returns `Ok(())` on EOF, `Err(())`
/// on a transport read error; a downstream write error ends quietly. The caller owns `fd`.
fn pump(fd: i32, out: i32) -> Result<(), ()> {
    let mut chunk = [0u8; 4096];
    loop {
        match rt::read(fd, &mut chunk) {
            Ok(0) => return Ok(()),
            Ok(n) => {
                if rt::write_all(out, &chunk[..n]).is_err() {
                    return Ok(());
                }
            }
            Err(_) => return Err(()),
        }
    }
}

/// `wget [-O FILE] URL`. Returns the exit status.
pub fn uumain(args: impl uucore::Args) -> i32 {
    let m = match command().try_get_matches_from(args) {
        Ok(m) => m,
        Err(e) => {
            let _ = e.print();
            return if e.exit_code() == 0 { 0 } else { 2 };
        }
    };

    let url = match m.get_one::<String>("URL") {
        Some(u) => u.as_str(),
        None => {
            eprintln!("wget: usage: wget <url>");
            return 2;
        }
    };

    // Resolve the output sink: stdout by default, or `-O FILE` (with `-` meaning stdout).
    let out_path = m.get_one::<String>("output-document");
    let (out_fd, close_out) = match out_path {
        Some(p) if p != "-" => match rt::open(p, rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC) {
            Ok(fd) => (fd, true),
            Err(e) => {
                eprintln!("wget: {}: {}", p, rt::strerror(e));
                return 1;
            }
        },
        _ => (rt::STDOUT, false),
    };

    let fd = match rt::http_get(url) {
        Ok(fd) => fd,
        Err(rt::EPERM) => {
            eprintln!("wget: network unavailable");
            if close_out {
                rt::close(out_fd);
            }
            return 1;
        }
        Err(_) => {
            eprintln!("wget: request failed");
            if close_out {
                rt::close(out_fd);
            }
            return 1;
        }
    };

    let rc = match pump(fd, out_fd) {
        Ok(()) => 0,
        Err(()) => {
            eprintln!("wget: body read failed");
            1
        }
    };
    rt::close(fd);
    if close_out {
        rt::close(out_fd);
    }
    rc
}
