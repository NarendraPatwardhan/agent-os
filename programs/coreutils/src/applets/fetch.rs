//! `fetch [-X METHOD] [-H 'K: V']... [-d BODY] URL` — a curl-like HTTP client guest. It parses
//! `-X METHOD`, `-H 'K: V'` (repeatable), and `-d BODY`, serializes the request blob the host
//! parses (`METHOD URL\n<headers>\n\n<body>`), calls `rt::http_request` to get a readable
//! response-body fd, reads the status with `rt::http_status`, and streams the body to standard
//! output. The kernel performs the request and the host terminates TLS; the guest never sees a
//! socket or the host handle.
//!
//! Network access is gated: without the NET capability (`--allow-net`), the request reports
//! "network unavailable". This makes the applet `tier_full` (NET).
//!
//! Flags: `-X METHOD` (default GET; `-d` implies POST unless `-X` is set), `-H 'K: V'`
//! (repeatable), `-d BODY` (sets `Content-Length`). Deviations from curl: this is a minimal
//! client — there is no `-o`/`--output`, `-L`/`--location` (redirect following), `-s`/`--silent`,
//! `-i`/`-I` (headers), `-u` (auth), or `-A` (user-agent); only `-X`, `-H`, and `-d`. A status
//! `>= 400` still streams the body but makes the exit status nonzero (curl-like).
//!
//! Exit status: `0` the request completed with a status `< 400`; `1` transport failure, network
//! unavailable, or an HTTP status `>= 400`; `2` usage error (missing URL or flag argument,
//! unknown option).
//!
//! Ported from memcontainers' `programs::fetch`.

use alloc::vec::Vec;

use clap::{Arg, ArgAction, Command};

use sysroot as rt;

/// The clap command — the single source of `fetch`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("fetch")
        .about("Make an HTTP request and stream the response body to standard output.")
        .override_usage("fetch [-X METHOD] [-H 'K: V']... [-d BODY] URL")
        .arg(
            Arg::new("method")
                .short('X')
                .num_args(1)
                .value_name("METHOD")
                .help("request method (default GET; -d implies POST unless -X is set)"),
        )
        .arg(
            Arg::new("header")
                .short('H')
                .action(ArgAction::Append)
                .num_args(1)
                .value_name("K: V")
                .help("add a request header line; may be repeated"),
        )
        .arg(
            Arg::new("data")
                .short('d')
                .num_args(1)
                .value_name("BODY")
                .help("send BODY as the request body (sets Content-Length)"),
        )
        .arg(
            Arg::new("URL")
                .required(true)
                .value_name("URL")
                .help("the http(s) URL to request"),
        )
}

/// `fetch [-X METHOD] [-H 'K: V']... [-d BODY] URL`. Returns the exit status.
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
            eprintln!("fetch: usage: fetch [-X METHOD] [-H 'K: V'] [-d BODY] <url>");
            return 2;
        }
    };
    let body = m.get_one::<String>("data").map(String::as_bytes);
    // A body implies POST unless an explicit method was given.
    let method = match m.get_one::<String>("method") {
        Some(x) => x.as_str(),
        None if body.is_some() => "POST",
        None => "GET",
    };

    // Build the request blob: `METHOD URL\n`, header lines, a blank line, then the body.
    let mut blob: Vec<u8> = Vec::new();
    blob.extend_from_slice(method.as_bytes());
    blob.push(b' ');
    blob.extend_from_slice(url.as_bytes());
    blob.push(b'\n');
    if let Some(hs) = m.get_many::<String>("header") {
        for h in hs {
            blob.extend_from_slice(h.as_bytes());
            blob.push(b'\n');
        }
    }
    if let Some(b) = body {
        blob.extend_from_slice(b"Content-Length: ");
        let mut tmp = [0u8; 20];
        let mut i = tmp.len();
        let mut v = b.len();
        if v == 0 {
            i -= 1;
            tmp[i] = b'0';
        }
        while v > 0 {
            i -= 1;
            tmp[i] = b'0' + (v % 10) as u8;
            v /= 10;
        }
        blob.extend_from_slice(&tmp[i..]);
        blob.push(b'\n');
    }
    blob.push(b'\n');
    if let Some(b) = body {
        blob.extend_from_slice(b);
    }

    let fd = match rt::http_request(&blob) {
        Ok(fd) => fd,
        Err(rt::EPERM) => {
            eprintln!("fetch: network unavailable");
            return 1;
        }
        Err(_) => {
            eprintln!("fetch: request failed");
            return 1;
        }
    };

    // Wait for the response head and read its status (curl-like exit code: nonzero for >= 400).
    let status = match rt::http_status(fd) {
        Ok(s) => s,
        Err(rt::EPERM) => {
            eprintln!("fetch: network unavailable");
            rt::close(fd);
            return 1;
        }
        Err(_) => {
            eprintln!("fetch: request failed");
            rt::close(fd);
            return 1;
        }
    };

    // Stream the body to stdout. A read error is a transport failure.
    let mut chunk = [0u8; 4096];
    loop {
        match rt::read(fd, &mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                if rt::write_all(rt::STDOUT, &chunk[..n]).is_err() {
                    break;
                }
            }
            Err(_) => {
                eprintln!("fetch: request failed");
                rt::close(fd);
                return 1;
            }
        }
    }
    rt::close(fd);

    // curl-like: a >= 400 response is a command failure even though the body was delivered.
    if status >= 400 {
        1
    } else {
        0
    }
}
