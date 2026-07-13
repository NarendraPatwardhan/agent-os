// crates/kernel/src/init.rs
// Boot sequence — initialize system, load base image, mount filesystems.

use alloc::boxed::Box;
use alloc::vec::Vec;

use crate::bridge;
use crate::fs::{CowFs, DevFs, MemFs, OverlayFs, PersistFs, TarFs};
use crate::task::Scheduler;
use crate::vfs::traits::FileSystem;
use crate::vfs::{KPath, Namespace, SYSTEM_CALLER};

/// Boot the system and mount its filesystems. The canonical guest `/bin/sh` is
/// started later by `lib.rs::init_system`, once the wasm engine exists.
pub fn boot_system() -> Result<(Namespace, Scheduler), BootError> {
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

    let _ = namespace.mkdir(SYSTEM_CALLER, &KPath::new("/home"));
    let _ = namespace.mkdir(SYSTEM_CALLER, &KPath::new("/home/user"));

    let _ = namespace.mkdir(SYSTEM_CALLER, &KPath::new("/tmp"));
    let tmp_msg = "Mounting /tmp (tmpfs)... ok\r\n";
    unsafe {
        bridge::mc_stdout_write(tmp_msg.as_ptr(), tmp_msg.len());
    }
    namespace.mount_labeled("/tmp", Box::new(MemFs::new()), "tmpfs", false);

    // /var/persist — capability-backed persistence. The mount
    // is always present; when the host denies the capability, operations
    // surface as PermissionDenied.
    let _ = namespace.mkdir(SYSTEM_CALLER, &KPath::new("/var"));
    let _ = namespace.mkdir(SYSTEM_CALLER, &KPath::new("/var/persist"));
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
    let _ = namespace.mkdir(SYSTEM_CALLER, &KPath::new("/proc"));

    let boot_complete_msg = "\r\n";
    unsafe {
        bridge::mc_stdout_write(boot_complete_msg.as_ptr(), boot_complete_msg.len());
    }

    Ok((namespace, scheduler))
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

#[derive(Debug)]
#[allow(dead_code)]
pub enum BootError {
    HostLoadFailed,
    InvalidBaseImage,
}
