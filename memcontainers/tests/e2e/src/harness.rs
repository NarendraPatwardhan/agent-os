//! Shared e2e harness — the boot helpers + the `Session` driver that BOTH suites obey:
//! the [`core`](crate) suite (fast, no-domain-service boots) and the sibling `extended` suite
//! (the heavy `sqlite`/`typst` domain services). Both crate roots `mod harness; pub use harness::*;`,
//! so the constitution is enforced once, in one place.
//!
//! TWO output paths, tested where each is correct (NOT interchangeable):
//!   - the **console / TTY** (`Session::run_for_output`, `send_raw`) — the interactive terminal,
//!     which applies ONLCR (`\n`→`\r\n`, kernel `io.rs`) for the agent's xterm.js. CRLF here is
//!     deliberate; the `tty`/`shell`/`coreutils` groups drive it and assert CRLF.
//!   - the **control channel** (`Session::host.exec`/`read_file`/`snapshot`) — a structured pipe,
//!     pure LF. The `kernel` group exercises it.
//!
//! `#![allow(dead_code)]`: this harness is shared by two binaries that each use a SUBSET of the
//! boot helpers (e.g. `boot_atlas`/`boot_paper` are extended-only), so an unused-in-one-crate
//! helper is by design, not rot.
#![allow(dead_code)]

use std::sync::{Arc, Mutex};

use host::{
    CaptureSink, DirEntry, DiskPersist, KernelHost, KernelHostBuilder, MapHostCall, NetCapability,
};

/// Generous tick budget for one shell operation (a pipeline can yield across many ticks).
const MAX_TICKS_PER_OP: usize = 200_000;

/// A far larger budget for a HEAVY guest op — a typst compile runs for millions of fuel slices under the
/// wasmi interpreter (font load + layout + PDF realization). This is a CEILING that only trips on a
/// genuine hang; a compile that completes exits at the prompt long before it (memcontainers' typst e2e
/// uses the same kind of raised budget).
const MAX_TICKS_PER_HEAVY_OP: usize = 12_000_000;

/// Locate a `data`-dep artifact in the test's runfiles by its workspace-relative path.
fn runfile(path: &str) -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r
        .rlocation(path)
        .unwrap_or_else(|| panic!("{path} not found in runfiles"));
    std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

/// The kernel.wasm under test, as a runfiles path — `rust_e2e_test` sets `MC_KERNEL_WASM` from the
/// `kernel` target, so the suite is kernel-AGNOSTIC (Rust by default, Zig optional).
fn kernel_rlocation() -> String {
    std::env::var("MC_KERNEL_WASM")
        .expect("MC_KERNEL_WASM unset — rust_e2e_test sets it from the `kernel` target")
}

pub fn kernel_under_test_rlocation() -> String {
    kernel_rlocation()
}

/// A booted VM under the real host: the kernel plus its captured terminal stdout. The console
/// methods drive the interactive TTY (CRLF); `host` is the structured control channel (LF).
pub struct Session {
    pub host: KernelHost,
    stdout: Arc<Mutex<Vec<u8>>>,
}

/// A host builder wired to a real image + deterministic clock/rng + a captured stdout. Internal —
/// the public entry points are [`boot`]/[`boot_posix`]/[`restore`].
fn builder(image: &str) -> (KernelHostBuilder, Arc<Mutex<Vec<u8>>>) {
    let (sink, stdout) = CaptureSink::new();
    let b = KernelHostBuilder::new(runfile(&kernel_rlocation()))
        .with_base_image(Some(runfile(image)))
        .with_stdout(Box::new(sink))
        .deterministic();
    (b, stdout)
}

/// Boot the base image (rootfs only: /etc/profile + the in-kernel rescue shell). For kernel /
/// control-channel tests that need no guest programs.
pub fn boot() -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/base.tar");
    let host = b
        .build()
        .expect("kernel booted under the host (base image)");
    Session { host, stdout }
}

/// Boot the `posix` image (base + the guest /bin/sh + the coreutils boxes). For shell / coreutils /
/// tty tests that run real guest programs through the interactive shell.
pub fn boot_posix() -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/posix.tar");
    let host = b
        .build()
        .expect("kernel booted under the host (posix image)");
    Session { host, stdout }
}

/// Boot the `minimal` image (base + the curated minimal coreutils boxes). For flavor tests that
/// assert the minimal SET boundary holds at runtime.
pub fn boot_minimal() -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/minimal.tar");
    let host = b.build().expect("kernel booted (minimal image)");
    Session { host, stdout }
}

/// Boot the `loom` image (posix + Luau + the lazy owned syntax service). For the domain-tool tests
/// that run real Luau bytecode and structural parsing on the real kernel via the trap-unwind.
pub fn boot_loom() -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/loom.tar");
    let host = b.build().expect("kernel booted (loom image)");
    Session { host, stdout }
}

/// Boot the `loom` image with a host-call tool registry installed. This is the Luau `require("tools")`
/// proof: the language battery talks to the base `/svc/tools` broker, which then egresses through the
/// opted-in host-call map.
pub fn boot_loom_with_tools(tools: MapHostCall) -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/loom.tar");
    let host = b
        .with_host_call(Box::new(tools))
        .build()
        .expect("kernel booted (loom image with tools)");
    Session { host, stdout }
}

/// Boot the `loom` image with a real host network capability installed.
pub fn boot_loom_with_net(net: Box<dyn NetCapability>) -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/loom.tar");
    let host = b
        .with_net(net)
        .build()
        .expect("kernel booted (loom image with net)");
    Session { host, stdout }
}

/// Boot the `loom` image with both network and host-call tools installed. Adapter-backed tools use this
/// exact shape: `/svc/adapters` reaches the network, while host-call tools still route through the
/// configured host-call registry.
pub fn boot_loom_with_net_and_tools(net: Box<dyn NetCapability>, tools: MapHostCall) -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/loom.tar");
    let host = b
        .with_net(net)
        .with_host_call(Box::new(tools))
        .build()
        .expect("kernel booted (loom image with net and tools)");
    Session { host, stdout }
}

/// Boot the `svc_test` image (loom + the `kv` + `crashloop` example services + generated
/// /etc/services.d fragments). For the svc-primitive proof: kv reached from the CLI (`kv get`) and Luau
/// (`sys.svc`), warm across calls, crash-only recovery, oversize survival, and crashloop's bounded
/// activation failure.
pub fn boot_svc_test() -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/svc_test.tar");
    let host = b.build().expect("kernel booted (svc_test image)");
    Session { host, stdout }
}

/// Boot the `atlas` image (loom + the sqlite resident service + the require("sqlite") library +
/// /etc/services.d fragment). For the sqlite e2e: the warm typed data layer, transactions, and the
/// sqlite→xlsx composition.
pub fn boot_atlas() -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/atlas.tar");
    let host = b.build().expect("kernel booted (atlas image)");
    Session { host, stdout }
}

/// Boot the `paper` image (loom + the typst resident service + require("typst") + the /usr/share/fonts
/// baseline faces + /etc/services.d fragment). For the typst e2e: the warm compiler, the CLI + library faces,
/// streamed PDFs, and diagnostics.
pub fn boot_paper() -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/paper.tar");
    let host = b.build().expect("kernel booted (paper image)");
    Session { host, stdout }
}

/// Boot the `posix` image with a host-call tool registry installed (the tool-plane tests). The host
/// refuses host calls by default (A9, `DeniedHostCall`); this opts in with a tool map.
pub fn boot_posix_with_tools(tools: MapHostCall) -> Session {
    let (b, stdout) = builder("_main/memcontainers/images/posix.tar");
    let host = b
        .with_host_call(Box::new(tools))
        .build()
        .expect("kernel booted with host tools");
    Session { host, stdout }
}

/// Boot the `posix` image with a disk-backed persist capability over `dir` (the `pkgfsd` cache
/// test). The host denies persistence by default (A9, `DeniedPersist`); this opts in so writes to
/// `/var/persist` round-trip through real disk.
pub fn boot_posix_with_persist(dir: std::path::PathBuf) -> Session {
    std::fs::create_dir_all(&dir).expect("create persist backing dir");
    let (b, stdout) = builder("_main/memcontainers/images/posix.tar");
    let host = b
        .with_persist(Box::new(DiskPersist::new(dir)))
        .build()
        .expect("kernel booted with persist");
    Session { host, stdout }
}

/// Rehydrate a fresh VM from a snapshot blob — a new host (new sinks + deterministic sources) whose
/// kernel state IS the snapshot, not a boot. No image: the rootfs already lives in the snapshot.
pub fn restore(snapshot: &[u8]) -> Session {
    let (sink, stdout) = CaptureSink::new();
    let host = KernelHostBuilder::new(runfile(&kernel_rlocation()))
        .with_stdout(Box::new(sink))
        .deterministic()
        .restore(snapshot)
        .expect("restore from snapshot");
    Session { host, stdout }
}

/// Rehydrate a cumulative page delta against its exact full baseline.
pub fn restore_incremental(snapshot: &[u8], base: &[u8]) -> Session {
    let (sink, stdout) = CaptureSink::new();
    let host = KernelHostBuilder::new(runfile(&kernel_rlocation()))
        .with_stdout(Box::new(sink))
        .deterministic()
        .restore_incremental(snapshot, base)
        .expect("restore incremental snapshot");
    Session { host, stdout }
}

impl Session {
    /// The full terminal transcript so far (CRLF and all).
    pub fn transcript(&self) -> String {
        String::from_utf8_lossy(&self.stdout.lock().unwrap()).into_owned()
    }

    fn len(&self) -> usize {
        self.stdout.lock().unwrap().len()
    }

    /// Mark the current transcript length, to capture a slice across several raw sends.
    pub fn mark(&self) -> usize {
        self.len()
    }

    /// The terminal slice from a [`mark`](Self::mark) to now (CRLF and control bytes intact).
    pub fn since(&self, mark: usize) -> String {
        String::from_utf8_lossy(&self.stdout.lock().unwrap()[mark..]).into_owned()
    }

    /// Send raw bytes to the terminal as if typed (no implicit newline). The caller drives ticks.
    pub fn send_raw(&mut self, bytes: &[u8]) {
        self.host.send_input(bytes).expect("send_input");
    }

    /// Pump ticks until stdout has grown since `baseline` and ends in the prompt `"$ "`, or until
    /// the budget is exhausted (a panic with the transcript — a hang is a test failure, not a skip).
    pub fn drive_until_prompt(&mut self, baseline: usize) {
        self.drive_until_prompt_budget(baseline, MAX_TICKS_PER_OP);
    }

    /// [`drive_until_prompt`](Self::drive_until_prompt) with an explicit tick ceiling — the heavy
    /// variant raises it for typst compiles.
    fn drive_until_prompt_budget(&mut self, baseline: usize, max_ticks: usize) {
        for _ in 0..max_ticks {
            if !self.host.tick().expect("tick") {
                return;
            }
            let buf = self.stdout.lock().unwrap();
            if buf.len() > baseline && buf.ends_with(b"$ ") {
                return;
            }
        }
        panic!(
            "timed out waiting for the shell prompt; transcript:\n{}",
            self.transcript()
        );
    }

    /// Type `line` + Enter at the console and wait for the next prompt; return the raw terminal
    /// slice emitted after entry (the echo + the output + the next prompt, CRLF).
    pub fn send_line(&mut self, line: &str) -> String {
        self.send_line_budget(line, MAX_TICKS_PER_OP)
    }

    /// [`send_line`](Self::send_line) with an explicit tick ceiling.
    fn send_line_budget(&mut self, line: &str, max_ticks: usize) -> String {
        let before = self.len();
        self.send_raw(line.as_bytes());
        self.send_raw(b"\n");
        self.drive_until_prompt_budget(before, max_ticks);
        String::from_utf8_lossy(&self.stdout.lock().unwrap()[before..]).into_owned()
    }

    /// Run `line` through the interactive shell and return JUST the command's output — the bytes
    /// between the line-discipline echo (`{line}\r\n`) and the trailing prompt (`$ `). This is what
    /// the agent's terminal actually shows as the response, CRLF intact.
    pub fn run_for_output(&mut self, line: &str) -> String {
        let response = self.send_line(line);
        Self::extract_body(response, line)
    }

    /// [`run_for_output`](Self::run_for_output) with the HEAVY tick budget — for typst compiles, which
    /// run for millions of fuel slices under wasmi.
    pub fn run_for_output_heavy(&mut self, line: &str) -> String {
        let response = self.send_line_budget(line, MAX_TICKS_PER_HEAVY_OP);
        Self::extract_body(response, line)
    }

    /// Slice a `send_line` response down to the command's output (between the typed-line echo and the
    /// trailing prompt).
    fn extract_body(response: String, line: &str) -> String {
        let echo = format!("{line}\r\n");
        let after_echo = response
            .find(&echo)
            .map(|i| i + echo.len())
            .unwrap_or_else(|| panic!("no typed-line echo {echo:?} in response:\n{response:?}"));
        let body_and_prompt = &response[after_echo..];
        let prompt_at = body_and_prompt
            .rfind("$ ")
            .unwrap_or_else(|| panic!("no trailing prompt in response:\n{response:?}"));
        body_and_prompt[..prompt_at].to_string()
    }

    /// Send `line` + Enter and drive a FIXED tick budget — NOT waiting for a prompt. For daemons
    /// (e.g. `pkgfsd`) that serve forever and never return the shell to a prompt: capture what the
    /// consumer they spawn emits within the budget. Returns the terminal slice since entry.
    pub fn send_line_async(&mut self, line: &str, ticks: usize) -> String {
        let before = self.len();
        self.send_raw(line.as_bytes());
        self.send_raw(b"\n");
        for _ in 0..ticks {
            if !self.host.tick().expect("tick") {
                break;
            }
        }
        self.since(before)
    }
}

/// The names in a control-channel directory listing.
pub fn names(entries: &[DirEntry]) -> Vec<&str> {
    entries.iter().map(|e| e.name.as_str()).collect()
}
