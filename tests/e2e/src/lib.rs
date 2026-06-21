//! End-to-end suite (B6, §9.1) — the testing constitution every test here obeys:
//!
//! 1. **No mocks.** Each test boots the REAL `kernel.wasm` inside the REAL wasmtime host and
//!    asserts on REAL bytes. Booting is itself the first assertion: a kernel trap or a
//!    generated-bridge mismatch surfaces as a host error, never a silent skip.
//! 2. **Load-bearing data edge (B1, §7.2).** The kernel + images are `data` deps, so a test always
//!    runs the artifact its sources produce — the death of the memcontainers staleness class.
//! 3. **Deterministic.** Fixed clock + seeded rng (`.deterministic()`), so bytes are reproducible.
//! 4. **One invariant per test**, named `<subject>_<behavior>`, with a WHY/GUARANTEES note.
//! 5. **One binary** (kernel compiled once, ~1.6 ms per boot), grouped into modules by layer.
//!
//! TWO output paths, tested where each is correct (NOT interchangeable):
//!   - the **console / TTY** (`Session::run_for_output`, `send_raw`) — the interactive terminal,
//!     which applies ONLCR (`\n`→`\r\n`, kernel `io.rs`) for the agent's xterm.js. CRLF here is
//!     deliberate; the `tty`/`shell`/`coreutils` groups drive it and assert CRLF.
//!   - the **control channel** (`Session::host.exec`/`read_file`/`snapshot`) — a structured pipe,
//!     pure LF. The `kernel` group exercises it.
//!
//! Groups: [`boot`] (the nest is alive), [`tty`] (line discipline + ONLCR), [`shell`] (sh control
//! flow), [`coreutils`] (the guest /bin behaviors), [`kernel`] (control channel + snapshot).

use std::sync::{Arc, Mutex};

use host::{CaptureSink, DirEntry, KernelHost, KernelHostBuilder, MapHostCall};

mod boot;
mod coreutils;
mod kernel;
mod shell;
mod system;
mod tty;

/// Generous tick budget for one shell operation (a pipeline can yield across many ticks).
const MAX_TICKS_PER_OP: usize = 200_000;

/// Locate a `data`-dep artifact in the test's runfiles by its workspace-relative path.
fn runfile(path: &str) -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r.rlocation(path).unwrap_or_else(|| panic!("{path} not found in runfiles"));
    std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

/// The kernel.wasm under test, as a runfiles path — `rust_e2e_test` sets `MC_KERNEL_WASM` from the
/// `kernel` target, so the suite is kernel-AGNOSTIC (Rust by default, Zig under the §9.6 gate).
fn kernel_rlocation() -> String {
    std::env::var("MC_KERNEL_WASM")
        .expect("MC_KERNEL_WASM unset — rust_e2e_test sets it from the `kernel` target")
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
    let (b, stdout) = builder("_main/images/base.tar");
    let host = b.build().expect("kernel booted under the host (base image)");
    Session { host, stdout }
}

/// Boot the `posix` image (base + the guest /bin/sh + the coreutils boxes). For shell / coreutils /
/// tty tests that run real guest programs through the interactive shell.
pub fn boot_posix() -> Session {
    let (b, stdout) = builder("_main/images/posix.tar");
    let host = b.build().expect("kernel booted under the host (posix image)");
    Session { host, stdout }
}

/// Boot the `posix` image with a host-call tool registry installed (the `invoke` tests). The host
/// refuses host calls by default (A9, `DeniedHostCall`); this opts in with a tool map.
pub fn boot_posix_with_tools(tools: MapHostCall) -> Session {
    let (b, stdout) = builder("_main/images/posix.tar");
    let host = b.with_host_call(Box::new(tools)).build().expect("kernel booted with host tools");
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
        for _ in 0..MAX_TICKS_PER_OP {
            if !self.host.tick().expect("tick") {
                return;
            }
            let buf = self.stdout.lock().unwrap();
            if buf.len() > baseline && buf.ends_with(b"$ ") {
                return;
            }
        }
        panic!("timed out waiting for the shell prompt; transcript:\n{}", self.transcript());
    }

    /// Type `line` + Enter at the console and wait for the next prompt; return the raw terminal
    /// slice emitted after entry (the echo + the output + the next prompt, CRLF).
    pub fn send_line(&mut self, line: &str) -> String {
        let before = self.len();
        self.send_raw(line.as_bytes());
        self.send_raw(b"\n");
        self.drive_until_prompt(before);
        String::from_utf8_lossy(&self.stdout.lock().unwrap()[before..]).into_owned()
    }

    /// Run `line` through the interactive shell and return JUST the command's output — the bytes
    /// between the line-discipline echo (`{line}\r\n`) and the trailing prompt (`$ `). This is what
    /// the agent's terminal actually shows as the response, CRLF intact.
    pub fn run_for_output(&mut self, line: &str) -> String {
        let response = self.send_line(line);
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
}

/// The names in a control-channel directory listing.
pub(crate) fn names(entries: &[DirEntry]) -> Vec<&str> {
    entries.iter().map(|e| e.name.as_str()).collect()
}
