//! `wscat URL` — a bidirectional WebSocket client guest. It opens a WebSocket with
//! `rt::ws_open` (a bidirectional fd), then runs an `rt::poll` pump over `[ws, stdin]`: stdin
//! lines are sent as messages, received messages are written to standard output. The kernel
//! owns the host connection and terminates TLS for `wss://`; the guest never sees a socket. This
//! makes the applet `tier_full` (NET).
//!
//! `URL` must be a `ws://` or `wss://` address (positional). Deviations from the npm `wscat`:
//! this is a minimal client — there is no `-c`/`--connect` (the URL is positional), no
//! `-l`/`--listen` server mode, no `-H`/`--header`, no `--subprotocol`, no `-x` execute, and no
//! `-w` wait/ping control.
//!
//! Exit semantics mirror the builtin: a connection that closes before any message arrived is a
//! failure ("connection failed", exit 1); once at least one message has been received and stdin
//! is at EOF, the pump exits cleanly after a short idle window with no further activity.
//! Capability denial (no NET / `--allow-net`) reports "network unavailable" (exit 1).
//!
//! Exit status: `0` the session completed after receiving at least one message; `1` connection
//! failed, network unavailable, or a poll error; `2` usage error (missing or non-ws/wss URL).
//!
//! Ported from memcontainers' `programs::wscat`.

use clap::{Arg, Command};

use sysroot as rt;

/// Idle window (ms) with no WebSocket activity, after stdin EOF and at least one received
/// message, before exiting cleanly.
const IDLE_MS: i32 = 250;

/// The clap command — the single source of `wscat`'s flag surface AND its `--help`.
fn command() -> Command {
    Command::new("wscat")
        .about("Connect to a WebSocket and pipe standard input/output to it.")
        .override_usage("wscat URL")
        .arg(
            Arg::new("URL")
                .required(true)
                .value_name("URL")
                .help("the ws:// or wss:// address to connect to"),
        )
}

/// `wscat URL`. Returns the exit status.
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
            eprintln!("wscat: usage: wscat <url>");
            return 2;
        }
    };
    if !(url.starts_with("ws://") || url.starts_with("wss://")) {
        eprintln!("wscat: usage: wscat <ws|wss-url>");
        return 2;
    }

    // Open the bidirectional WebSocket fd; it reads/writes/polls like any stream.
    let ws = match rt::ws_open(url) {
        Ok(fd) => fd,
        Err(_) => {
            eprintln!("wscat: network unavailable");
            return 1;
        }
    };

    let pollin = rt::POLLIN as i16;
    let mut stdin_eof = false;
    let mut received_any = false;
    let mut buf = [0u8; 8192];

    loop {
        // Poll stdin (until EOF) and the ws together. Before the connection has proven alive (a
        // message received) we block indefinitely so a failed handshake — which surfaces as a ws
        // read error/EOF — is observed; once alive and stdin is drained we use a finite idle
        // window to exit.
        let timeout = if stdin_eof && received_any {
            IDLE_MS
        } else {
            rt::POLL_BLOCK
        };

        // The ws is index 0 so it is ALWAYS polled; stdin is index 1 and is dropped from the set
        // once at EOF (a closed pipe is always "readable", which would otherwise spin the poll).
        let mut fds = [
            rt::PollFd::new(ws, pollin),
            rt::PollFd::new(rt::STDIN, pollin),
        ];
        let nfds = if stdin_eof { 1 } else { 2 };
        let ready = match rt::poll(&mut fds[..nfds], timeout) {
            Ok(r) => r,
            Err(_) => {
                eprintln!("wscat: poll failed");
                rt::close(ws);
                return 1;
            }
        };

        if ready == 0 {
            // Idle window elapsed (only reachable once alive + stdin EOF).
            rt::close(ws);
            return 0;
        }

        // ws → stdout. Service the ws side first so a pending echo is flushed.
        if fds[0].ready(pollin) || fds[0].ready(rt::POLLHUP as i16) {
            match rt::read(ws, &mut buf) {
                Ok(0) => {
                    // The connection closed. A close before any message means the handshake
                    // never came up — a failure to report.
                    rt::close(ws);
                    if received_any {
                        return 0;
                    } else {
                        eprintln!("wscat: connection failed");
                        return 1;
                    }
                }
                Ok(n) => {
                    if rt::write_all(rt::STDOUT, &buf[..n]).is_err() {
                        rt::close(ws);
                        return 0;
                    }
                    received_any = true;
                }
                Err(_) => {
                    rt::close(ws);
                    if received_any {
                        return 0;
                    } else {
                        eprintln!("wscat: connection failed");
                        return 1;
                    }
                }
            }
        }

        // stdin → ws.
        if !stdin_eof && fds[1].ready(pollin) {
            match rt::read(rt::STDIN, &mut buf) {
                Ok(0) => stdin_eof = true,
                Ok(n) => {
                    if rt::write_all(ws, &buf[..n]).is_err() {
                        // Peer gone while sending; if we already got data this is a clean end,
                        // otherwise a failure.
                        rt::close(ws);
                        if received_any {
                            return 0;
                        } else {
                            eprintln!("wscat: connection failed");
                            return 1;
                        }
                    }
                }
                Err(_) => stdin_eof = true,
            }
        }
    }
}
