// crates/kernel/src/init.rs
// Boot sequence — initialize system, load base image, mount filesystems.

use alloc::boxed::Box;
use alloc::string::String;
use alloc::vec::Vec;

use crate::bridge;
use crate::builtins::{
    Builtin, BuiltinCtx, BuiltinStep, false_factory, tail_factory, true_factory, umount_factory,
};
use crate::fs::{CowFs, DevFs, MemFs, OverlayFs, PersistFs, TarFs};
use crate::io::{EmptySource, TerminalSink};
use crate::shell::{Executor, parse_line};
use crate::task::Scheduler;
use crate::vfs::traits::FileSystem;
use crate::vfs::{KPath, Namespace, SYSTEM_CALLER};

/// Boot the system: mount the filesystems and source `/etc/profile`. The login
/// shell (the guest `/bin/sh` as pid 1, or the in-kernel rescue shell) is
/// started later by `lib.rs::init_system`, once the wasm engine exists.
pub fn boot_system() -> Result<(Namespace, Scheduler, Executor), BootError> {
    // Provenance seal — the boot banner line (product, version, owner,
    // license), decoded at runtime from obfuscated bytes (see `crate::seal`);
    // intentionally not a plaintext string in the binary. Printed first.
    crate::seal::emit();

    let boot_msg = "Booting ...\r\n";
    unsafe {
        bridge::mc_stdout_write(boot_msg.as_ptr(), boot_msg.len());
    }

    let namespace = Namespace::new();
    match load_base_image() {
        Ok(payload) => {
            // The image payload is an ordered layer STACK (lowest→highest); a
            // single base.tar is one layer (today's exact behavior). Build a
            // `TarFs` per layer and merge with `OverlayFs` (top-wins + whiteouts)
            // when there are several — `CowFs(OverlayFs([TarFs…]))`.
            let layers = parse_layers(payload).unwrap_or_default();
            let total: usize = layers.iter().map(|l| l.len()).sum();
            let loading_msg = alloc::format!(
                "Loading image ({} layers, {} bytes)... ",
                layers.len(),
                total
            );
            unsafe {
                bridge::mc_stdout_write(loading_msg.as_ptr(), loading_msg.len());
            }

            let mut tar_layers: Vec<TarFs> = Vec::new();
            let mut valid = !layers.is_empty();
            for tar in layers {
                match TarFs::new(tar) {
                    Ok(t) => tar_layers.push(t),
                    Err(_) => {
                        valid = false;
                        break;
                    }
                }
            }

            if valid {
                let base: Box<dyn FileSystem> = if tar_layers.len() == 1 {
                    Box::new(tar_layers.pop().expect("one layer"))
                } else {
                    Box::new(OverlayFs::new(tar_layers))
                };
                namespace.mount_labeled("/", Box::new(CowFs::new(base)), "cowfs", false);
                let ok_msg = "ok\r\n";
                unsafe {
                    bridge::mc_stdout_write(ok_msg.as_ptr(), ok_msg.len());
                }
            } else {
                let err_msg = "invalid; using empty root\r\n";
                unsafe {
                    bridge::mc_stderr_write(err_msg.as_ptr(), err_msg.len());
                }
                namespace.mount_labeled("/", Box::new(MemFs::new()), "memfs", false);
            }
        }
        Err(_) => {
            let no_image_msg = "No base image provided, using empty root\r\n";
            unsafe {
                bridge::mc_stdout_write(no_image_msg.as_ptr(), no_image_msg.len());
            }
            namespace.mount_labeled("/", Box::new(MemFs::new()), "memfs", false);
        }
    }

    let dev_msg = "Mounting /dev... ok\r\n";
    unsafe {
        bridge::mc_stdout_write(dev_msg.as_ptr(), dev_msg.len());
    }
    namespace.mount_labeled("/dev", Box::new(DevFs::new()), "devfs", false);

    let _ = namespace.mkdir(&KPath::new("/home"), SYSTEM_CALLER);
    let _ = namespace.mkdir(&KPath::new("/home/user"), SYSTEM_CALLER);

    let _ = namespace.mkdir(&KPath::new("/tmp"), SYSTEM_CALLER);
    let tmp_msg = "Mounting /tmp (tmpfs)... ok\r\n";
    unsafe {
        bridge::mc_stdout_write(tmp_msg.as_ptr(), tmp_msg.len());
    }
    namespace.mount_labeled("/tmp", Box::new(MemFs::new()), "tmpfs", false);

    // /var/persist — capability-backed persistence. The mount
    // is always present; when the host denies the capability, operations
    // surface as PermissionDenied.
    let _ = namespace.mkdir(&KPath::new("/var"), SYSTEM_CALLER);
    let _ = namespace.mkdir(&KPath::new("/var/persist"), SYSTEM_CALLER);
    let persist_msg = "Mounting /var/persist (persistfs)... ok\r\n";
    unsafe {
        bridge::mc_stdout_write(persist_msg.as_ptr(), persist_msg.len());
    }
    namespace.mount_labeled(
        "/var/persist",
        Box::new(PersistFs::new()),
        "persistfs",
        false,
    );

    let scheduler = Scheduler::new();
    let _ = namespace.mkdir(&KPath::new("/proc"), SYSTEM_CALLER);

    let mut executor = Executor::new();
    register_builtins(&mut executor);

    let profile_msg = "Sourcing /etc/profile... ";
    unsafe {
        bridge::mc_stdout_write(profile_msg.as_ptr(), profile_msg.len());
    }
    match source_profile(&namespace, &executor, &scheduler) {
        Ok(_) => unsafe {
            let ok_msg = "ok\r\n";
            bridge::mc_stdout_write(ok_msg.as_ptr(), ok_msg.len());
        },
        Err(_) => unsafe {
            let skip_msg = "skipped\r\n";
            bridge::mc_stdout_write(skip_msg.as_ptr(), skip_msg.len());
        },
    }

    let boot_complete_msg = "\r\n";
    unsafe {
        bridge::mc_stdout_write(boot_complete_msg.as_ptr(), boot_complete_msg.len());
    }

    Ok((namespace, scheduler, executor))
}

/// Load the host-provided base image into an exactly-sized buffer.
///
/// `mc_load_base_image` reports the FULL image length (copying only what fits the
/// passed buffer), so we probe that length with a zero-length read, then read the
/// whole image into a buffer sized to match. This avoids any fixed cap — a single
/// converted WASI tool (e.g. `grep` on ripgrep's engine) is already ~1.8 MiB, and
/// the image grows with each tool — without permanently reserving a worst-case
/// buffer in the kernel's linear memory. Returns `Err` only when no image was
/// provided (`with_image=false`).
fn load_base_image() -> Result<Vec<u8>, BootError> {
    // Probe: a zero-length read copies nothing but returns the image length.
    let mut probe = [0u8; 1];
    let size = unsafe { bridge::mc_load_base_image(probe.as_mut_ptr(), 0) };
    if size < 0 {
        return Err(BootError::HostLoadFailed);
    }
    let size = size as usize;

    let mut buffer = alloc::vec![0u8; size];
    let read = unsafe { bridge::mc_load_base_image(buffer.as_mut_ptr(), buffer.len()) };
    if read < 0 {
        return Err(BootError::HostLoadFailed);
    }
    buffer.truncate((read as usize).min(size));
    Ok(buffer)
}

/// Split the host's image payload into ordered layer tars (lowest→highest). An
/// `MCLS`-magic frame (`"MCLS" [u32 count] ([u32 len][bytes])…`, little-endian)
/// carries a layer stack; any other payload is a single bare `.tar` (one layer),
/// so direct `image: <bytes>` and a host that doesn't frame both still boot.
/// A malformed frame returns `None`, making boot treat the image as invalid
/// rather than silently accepting a partial stack.
fn parse_layers(buf: Vec<u8>) -> Option<Vec<Vec<u8>>> {
    if buf.len() >= 8 && &buf[0..4] == b"MCLS" {
        let count = u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]) as usize;
        if count == 0 {
            return None;
        }
        let mut layers = Vec::new();
        let mut off = 8;
        for _ in 0..count {
            if off + 4 > buf.len() {
                return None;
            }
            let len =
                u32::from_le_bytes([buf[off], buf[off + 1], buf[off + 2], buf[off + 3]]) as usize;
            off += 4;
            if off + len > buf.len() {
                return None;
            }
            layers.push(buf[off..off + len].to_vec());
            off += len;
        }
        if off != buf.len() {
            return None;
        }
        Some(layers)
    } else {
        Some(alloc::vec![buf])
    }
}

fn source_profile(
    namespace: &Namespace,
    executor: &Executor,
    scheduler: &Scheduler,
) -> Result<(), BootError> {
    namespace
        .stat(&KPath::new("/etc/profile"))
        .map_err(|_| BootError::ProfileNotFound)?;

    let mut profile_content = Vec::new();
    {
        let mut handle = namespace
            .open(&KPath::new("/etc/profile"), crate::vfs::OpenFlags::READ)
            .map_err(|_| BootError::ProfileReadFailed)?;

        let mut buf = [0u8; 4096];
        loop {
            match handle.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => profile_content.extend_from_slice(&buf[..n]),
                Err(_) => return Err(BootError::ProfileReadFailed),
            }
        }
    }

    let profile_str = String::from_utf8_lossy(&profile_content);

    // Drive each profile line through the registered builtin with empty
    // stdin and discarded stdout/stderr. The shell features needed for
    // `export ...` etc. live in the guest `/bin/sh`; for now profile sourcing
    // is a best-effort scan that ignores missing builtins.
    for line in profile_str.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some(seq) = parse_line(line) else {
            continue;
        };
        for (pipeline, _sep) in &seq.stages {
            let Some(cmd) = pipeline.commands.first() else {
                continue;
            };
            let Some(factory) = executor.lookup(&cmd.cmd) else {
                continue;
            };
            let mut prog: Box<dyn Builtin> = factory(cmd.args.clone());
            let mut cwd = String::from("/home/user");
            let mut stdin = EmptySource;
            let mut stdout: Box<dyn crate::io::WriteSink> = Box::new(DiscardSink);
            let mut stderr: Box<dyn crate::io::WriteSink> = Box::new(DiscardSink);
            loop {
                let mut ctx = BuiltinCtx {
                    ns: namespace,
                    root_ns: namespace,
                    cwd: &mut cwd,
                    stdin: &mut stdin,
                    stdout: stdout.as_mut(),
                    stderr: stderr.as_mut(),
                    sched: scheduler,
                    pid: 0,
                };
                match prog.step(&mut ctx) {
                    BuiltinStep::Exit(_) => break,
                    BuiltinStep::BlockedOnStdin => break, // no stdin source for profile
                    BuiltinStep::BlockedOnStdout => continue,
                    BuiltinStep::Pending => break, // boot must not wait on a capability
                    BuiltinStep::BlockedOn(_) => break,
                }
            }
        }
    }
    Ok(())
}

struct DiscardSink;
impl crate::io::WriteSink for DiscardSink {
    fn write(&mut self, buf: &[u8]) -> Result<usize, crate::vfs::FsError> {
        Ok(buf.len())
    }
}

fn register_builtins(executor: &mut Executor) {
    let _ = TerminalSink::Stdout; // keep the symbol imported for callers
    // Shell-integral builtins only. The POSIX coreutils
    // (cat/ls/echo/wc/head/mkdir/rm/cp/mv/touch/pwd) AND the network clients
    // (fetch/wscat, via `mc_sys_http_request`/`mc_sys_ws_open`) are wasm
    // guests on `$PATH`. What remains: `tail` must
    // buffer its whole input (no-alloc guests can't); `true`/`false` are
    // control primitives; `umount` is a privileged mount-table op guests must
    // not perform.
    executor.register("umount", umount_factory);
    executor.register("tail", tail_factory);
    executor.register("true", true_factory);
    executor.register("false", false_factory);
}

#[derive(Debug)]
#[allow(dead_code)]
pub enum BootError {
    HostLoadFailed,
    InvalidBaseImage,
    ProfileNotFound,
    ProfileReadFailed,
}
