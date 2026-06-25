//! `kv` — a trivial resident KEY-VALUE service that proves the resident-service
//! primitive end to end (SERVICES.md P1). One binary, two activation modes
//! (VISION §4.5): spawned by the kernel with the service marker it runs a warm
//! `svc_serve` loop over an in-memory store; invoked from the shell (`kv get k`,
//! `kv put k v`) it is a thin client that `svc_connect`s the warm service and
//! `svc_call`s it. The store lives in the SERVICE's linear memory, so it stays warm
//! across calls; when the service exits, a client gets an error rather than a hang
//! (crash-only). No allocator — a fixed-capacity store.

#![no_std]
#![no_main]

use sysroot as rt;

rt::entry!(main); // tier (isolated) + service ("kv") are declared in the BUILD (mc_rust_program)

const SERVICE_NAME: &str = "kv";

// ── the warm store (lives in the service's linear memory) ────────────────────

const MAX_ENTRIES: usize = 64;
const MAX_KEY: usize = 64;
const MAX_VAL: usize = 512;

#[derive(Clone, Copy)]
struct Entry {
    used: bool,
    klen: usize,
    key: [u8; MAX_KEY],
    vlen: usize,
    val: [u8; MAX_VAL],
}

static mut STORE: [Entry; MAX_ENTRIES] = [Entry {
    used: false,
    klen: 0,
    key: [0; MAX_KEY],
    vlen: 0,
    val: [0; MAX_VAL],
}; MAX_ENTRIES];

fn store_get(key: &[u8]) -> Option<&'static [u8]> {
    // SAFETY: single-threaded service; one request handled at a time, so no aliasing
    // with the &mut in `store_put`.
    let store: &'static [Entry; MAX_ENTRIES] = unsafe { &*core::ptr::addr_of!(STORE) };
    for e in store {
        if e.used && &e.key[..e.klen] == key {
            return Some(&e.val[..e.vlen]);
        }
    }
    None
}

fn store_put(key: &[u8], val: &[u8]) -> bool {
    if key.len() > MAX_KEY || val.len() > MAX_VAL {
        return false;
    }
    // SAFETY: see `store_get`.
    let store: &mut [Entry; MAX_ENTRIES] = unsafe { &mut *core::ptr::addr_of_mut!(STORE) };
    for e in store.iter_mut() {
        if e.used && &e.key[..e.klen] == key {
            e.val[..val.len()].copy_from_slice(val);
            e.vlen = val.len();
            return true;
        }
    }
    for e in store.iter_mut() {
        if !e.used {
            e.key[..key.len()].copy_from_slice(key);
            e.klen = key.len();
            e.val[..val.len()].copy_from_slice(val);
            e.vlen = val.len();
            e.used = true;
            return true;
        }
    }
    false // full
}

// ── service mode: the warm svc_serve loop ────────────────────────────────────

fn serve_loop() -> ! {
    let server = match rt::svc_serve(SERVICE_NAME) {
        Ok(fd) => fd,
        Err(_) => rt::exit(1),
    };
    let mut buf = [0u8; 1024];
    let mut hbuf = [0i32; 0]; // kv accepts no delegated handles
    loop {
        let n = match rt::svc_recv(server, &mut buf, &mut hbuf) {
            Ok(n) => n,
            Err(_) => rt::exit(0), // channel closed: nothing more to serve
        };
        let Some(req) = rt::parse_svc_request(&buf[..n], &hbuf) else {
            continue;
        };
        // kv holds no per-session state, so a session-closed tombstone needs no cleanup.
        if req.kind != rt::SvcKind::Call {
            continue;
        }
        // request blob = op\0key[\0value]
        let mut parts = req.blob.split(|&b| b == 0);
        let op = parts.next().unwrap_or(b"");
        let key = parts.next().unwrap_or(b"");
        let value = parts.next().unwrap_or(b"");
        match op {
            b"get" => {
                let resp = store_get(key).unwrap_or(b"");
                let _ = rt::svc_respond(server, req.session, req.req_id, 0, resp, true);
            }
            b"put" => {
                store_put(key, value);
                let _ = rt::svc_respond(server, req.session, req.req_id, 0, b"", true);
            }
            b"_crash" => {
                // Test hook: a service that dies mid-call. The in-flight caller's
                // result read fails (EIO); a later connect lazily starts a fresh
                // instance. Crash-only, never a hang.
                rt::exit(7);
            }
            b"_stream_crash" => {
                // Test hook: stream a PARTIAL chunk (last=false), then die before the
                // final chunk. The in-flight caller must get EIO (crash-only), not
                // hang — exercises servicefs::drain_response's server-closed path.
                let _ = rt::svc_respond(server, req.session, req.req_id, 0, b"partial", false);
                rt::exit(7);
            }
            _ => {
                let _ = rt::svc_respond(server, req.session, req.req_id, 0, b"", true);
            }
        }
    }
}

// ── client mode: the CLI ─────────────────────────────────────────────────────

fn append(buf: &mut [u8], at: usize, src: &[u8]) -> usize {
    let n = src.len().min(buf.len() - at);
    buf[at..at + n].copy_from_slice(&src[..n]);
    at + n
}

fn cli(args_blob: &[u8]) -> ! {
    let mut parts = args_blob.split(|&b| b == 0).filter(|p| !p.is_empty());
    let op = parts.next().unwrap_or(b"");
    let key = parts.next().unwrap_or(b"");
    let value = parts.next().unwrap_or(b"");
    if op.is_empty() {
        rt::eprint("kv: usage: kv get <key> | kv put <key> <value>\n");
        rt::exit(2);
    }
    let conn = match rt::svc_connect(SERVICE_NAME) {
        Ok(fd) => fd,
        Err(_) => {
            rt::eprint("kv: service unavailable\n");
            rt::exit(1);
        }
    };
    // Build the request blob: op\0key[\0value]
    let mut req = [0u8; 1024];
    let mut len = 0usize;
    len = append(&mut req, len, op);
    len = append(&mut req, len, b"\0");
    len = append(&mut req, len, key);
    if op == b"put" {
        len = append(&mut req, len, b"\0");
        len = append(&mut req, len, value);
    }
    let result = match rt::svc_call(conn, &req[..len], &[]) {
        Ok(fd) => fd,
        Err(_) => {
            rt::eprint("kv: call failed\n");
            rt::exit(1);
        }
    };
    // Stream the response to stdout.
    let mut rbuf = [0u8; 1024];
    let mut wrote_any = false;
    loop {
        match rt::read(result, &mut rbuf) {
            Ok(0) => break,
            Ok(k) => {
                wrote_any = true;
                if rt::write_all(1, &rbuf[..k]).is_err() {
                    rt::exit(1);
                }
            }
            Err(_) => {
                // The service died mid-call: the result read fails. Crash-only.
                rt::eprint("kv: service error\n");
                rt::exit(1);
            }
        }
    }
    // `get` of an existing key prints the value + a newline (conventional); `put` and a
    // missing `get` print nothing.
    if op == b"get" && wrote_any {
        let _ = rt::write_all(1, b"\n");
    }
    rt::exit(0);
}

fn main() {
    let mut argbuf = [0u8; 4096];
    let n = rt::args_into(&mut argbuf);
    // argv[0] is the program path; SERVICE mode is signalled by argv[1].
    let mut parts = argbuf[..n].split(|&b| b == 0);
    let _arg0 = parts.next();
    let arg1 = parts.next().unwrap_or(b"");
    if arg1 == rt::SERVICE_MARKER.as_bytes() {
        serve_loop();
    }
    // CLI: forward everything after argv[0]'s NUL.
    let start = argbuf[..n]
        .iter()
        .position(|&b| b == 0)
        .map(|i| i + 1)
        .unwrap_or(n);
    cli(&argbuf[start..n]);
}
