//! `pkgfsd` — the demand-load file server for `/pkg` (§7.1, approach A). A guest daemon:
//! `serve("/pkg")`, then loop `serve_recv` → dispatch. A tool's NAME is cheap + visible (the baked
//! catalog answers `readdir`/`stat` offline); only a `read` fetches the BYTES — cache hit
//! `/var/persist/pkg/<sha>` (persistfs) or cache miss `/net/https/<registry>/<path>` (netfs) →
//! `sha256`-verify → write-through cache. pkgfsd is the only `CAP_NET`+`CAP_PERSIST` holder, so a
//! consumer reaches a tool via `/pkg/bin/<name>` without holding either itself ("capability by
//! namespace"). Pure logic lives in `//pkgcore` (unit-tested). Ported from memcontainers' pkgfsd.
//!
//! Config (baked into a pkgfs-backed flavor): `/etc/pkg/catalog` (the catalog,
//! `name\tsha256hex\tsize\tregpath` rows) and `/etc/pkg/registry` (the netfs locator
//! `<scheme>/<host>[/prefix]`).

#![no_std]
#![no_main]

extern crate alloc;
use alloc::string::String;
use alloc::vec::Vec;

use sysroot as rt;

// pkgcore + the catalog use `alloc`; provide the same wasm allocator the kernel + sh use.
#[global_allocator]
static ALLOC: talc::wasm::WasmDynamicTalc = talc::wasm::new_wasm_dynamic_allocator();

// tier (full — needs CAP_NET + CAP_PERSIST) + budget are declared in the BUILD (mc_rust_program).

/// Fallback registry locator when `/etc/pkg/registry` is absent (a real netfs path shape —
/// `<scheme>/<host>/<prefix>`; the live host is configured per VM).
const DEFAULT_REGISTRY: &str = "https/registry.invalid/mc";

/// Read a whole file into a Vec (None on any error — e.g. a cache miss).
fn read_file(path: &str) -> Option<Vec<u8>> {
    let fd = rt::open(path, rt::O_READ).ok()?;
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => break,
            Ok(n) => out.extend_from_slice(&buf[..n]),
            Err(_) => {
                rt::close(fd);
                return None;
            }
        }
    }
    rt::close(fd);
    Some(out)
}

/// Write `data` to `path`, truncating (best-effort cache write-through).
fn write_file(path: &str, data: &[u8]) -> bool {
    let Ok(fd) = rt::open(path, rt::O_CREATE | rt::O_WRITE | rt::O_TRUNC) else {
        return false;
    };
    let ok = rt::write_all(fd, data).is_ok();
    rt::close(fd);
    ok
}

fn respond_dir(srv: i32, id: u32) {
    let mut rec = [0u8; rt::STAT_RECORD_LEN];
    rt::encode_stat(
        &rt::Stat {
            size: 0,
            is_dir: true,
            is_symlink: false,
            nlink: 2,
            mode: 0o755,
            mtime: 0,
            atime: 0,
            ctime: 0,
        },
        &mut rec,
    );
    let _ = rt::serve_respond(srv, id, 0, &rec);
}

fn respond_file_stat(srv: i32, id: u32, size: u64) {
    let mut rec = [0u8; rt::STAT_RECORD_LEN];
    rt::encode_stat(
        &rt::Stat {
            size,
            is_dir: false,
            is_symlink: false,
            nlink: 1,
            mode: 0o755, // executable — these are guest programs
            mtime: 0,
            atime: 0,
            ctime: 0,
        },
        &mut rec,
    );
    let _ = rt::serve_respond(srv, id, 0, &rec);
}

fn handle_stat(srv: i32, id: u32, path: &str, cat: &pkgcore::Catalog) {
    if path == "/" || path == "/bin" {
        respond_dir(srv, id);
        return;
    }
    if let Some(name) = path.strip_prefix("/bin/") {
        if let Some(e) = cat.lookup(name) {
            respond_file_stat(srv, id, e.size);
            return;
        }
    }
    let _ = rt::serve_respond(srv, id, rt::ENOENT, &[]);
}

fn handle_readdir(srv: i32, id: u32, path: &str, cat: &pkgcore::Catalog) {
    let mut buf = [0u8; 4096];
    if path == "/" {
        if let Some(n) = rt::push_serve_dirent(&mut buf, 0, rt::SERVE_DIRENT_DIR, "bin") {
            let _ = rt::serve_respond(srv, id, 0, &buf[..n]);
            return;
        }
    } else if path == "/bin" {
        let mut off = 0;
        for e in &cat.entries {
            match rt::push_serve_dirent(&mut buf, off, rt::SERVE_DIRENT_FILE, &e.name) {
                Some(n) => off = n,
                None => break, // catalog larger than one buffer — serve what fits
            }
        }
        let _ = rt::serve_respond(srv, id, 0, &buf[..off]);
        return;
    }
    let _ = rt::serve_respond(srv, id, rt::ENOENT, &[]);
}

fn handle_open(srv: i32, id: u32, path: &str, cat: &pkgcore::Catalog, base: &str) {
    let Some(name) = path.strip_prefix("/bin/") else {
        let _ = rt::serve_respond(srv, id, rt::ENOENT, &[]);
        return;
    };
    let Some(e) = cat.lookup(name) else {
        let _ = rt::serve_respond(srv, id, rt::ENOENT, &[]);
        return;
    };

    // Cache hit: read the content-addressed cache and re-verify (defends against a corrupted /
    // truncated cache entry).
    let cache = pkgcore::cache_path(&e.sha_hex);
    if let Some(bytes) = read_file(&cache) {
        if pkgcore::verify(&bytes, &e.sha_hex) {
            let _ = rt::serve_respond(srv, id, 0, &bytes);
            return;
        }
    }

    // Cache miss: fetch over the network, verify, write-through, then serve.
    let url = pkgcore::registry_url(base, &e.reg_path);
    if let Some(bytes) = read_file(&url) {
        if pkgcore::verify(&bytes, &e.sha_hex) {
            let _ = write_file(&cache, &bytes); // best-effort cache
            let _ = rt::serve_respond(srv, id, 0, &bytes);
            return;
        }
    }
    let _ = rt::serve_respond(srv, id, rt::EIO, &[]);
}

fn main() {
    let catalog_text = read_file("/etc/pkg/catalog")
        .and_then(|b| String::from_utf8(b).ok())
        .unwrap_or_default();
    let catalog = pkgcore::Catalog::parse(&catalog_text);
    let base = read_file("/etc/pkg/registry")
        .and_then(|b| String::from_utf8(b).ok())
        .map(|s| String::from(s.trim()))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| String::from(DEFAULT_REGISTRY));

    let srv = match rt::serve("/pkg") {
        Ok(fd) => fd,
        Err(_) => {
            rt::eprint("pkgfsd: serve failed\n");
            rt::exit(1);
        }
    };

    // `serve` mounts `/pkg` in OUR namespace, so only tasks WE spawn (after the serve) can reach it
    // — the §7.1 "pkgfsd spawns the agent" model. Any argv after `pkgfsd` is that consumer (e.g.
    // `pkgfsd sh`): spawn it now, then serve its `/pkg` reads forever. With no argv, run as a pure
    // daemon.
    let mut argbuf = [0u8; 1024];
    let n = rt::args_into(&mut argbuf);
    if let Some(first_nul) = argbuf[..n].iter().position(|&b| b == 0) {
        let child = &argbuf[first_nul + 1..n];
        if !child.is_empty() {
            let _ = rt::spawn(child, rt::STDIN, rt::STDOUT, rt::STDERR);
        }
    }

    let mut buf = [0u8; 1024];
    loop {
        let n = match rt::serve_recv(srv, &mut buf) {
            Ok(n) => n,
            Err(_) => break, // channel closed / fatal → the daemon exits
        };
        let (id, op, path) = match rt::parse_serve_request(&buf[..n]) {
            Some(r) => (r.id, r.op, String::from(r.path)),
            None => continue,
        };
        match op {
            rt::SERVE_OP_READDIR => handle_readdir(srv, id, &path, &catalog),
            rt::SERVE_OP_STAT => handle_stat(srv, id, &path, &catalog),
            rt::SERVE_OP_OPEN => handle_open(srv, id, &path, &catalog, &base),
            _ => {
                let _ = rt::serve_respond(srv, id, rt::ENOSYS, &[]);
            }
        }
    }
}

rt::entry!(main);
