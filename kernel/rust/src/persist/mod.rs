//! Kernel-side wrappers over the host persistence capability imports. The host
//! KV store is reachable only through these calls; the agent observes it solely
//! as the `/var/persist` filesystem (`fs::persistfs`), never a host path or
//! handle. Every buffer crossing the bridge is bounds-checked, and a denied
//! capability (`-1`) becomes `PersistError::Denied` so the filesystem can
//! surface `PermissionDenied`.
//!
//! Values are whole-value get/put (KV semantics, not streaming). `get`/`list`
//! return the FULL length even when it exceeds the probe buffer, so these
//! helpers grow and retry once to read the complete value.

#![allow(dead_code)]

use alloc::vec::Vec;

use crate::bridge;

/// Initial probe buffer for `get`/`list`. Most persisted values are small;
/// larger ones trigger a single resize-and-retry.
const PROBE: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PersistError {
    /// The host refused the capability, or an unrecoverable store error.
    Denied,
}

/// Read the whole value for `key`. `Ok(None)` means the key does not exist;
/// `Ok(Some(empty))` is a stored empty value.
pub fn get(key: &[u8]) -> Result<Option<Vec<u8>>, PersistError> {
    let mut buf = Vec::new();
    buf.resize(PROBE, 0);
    let n = unsafe { bridge::mc_persist_get(key.as_ptr(), key.len(), buf.as_mut_ptr(), buf.len()) };
    match n {
        -1 => Err(PersistError::Denied),
        -2 => Ok(None),
        n if n >= 0 => {
            let total = n as usize;
            if total <= buf.len() {
                buf.truncate(total);
                return Ok(Some(buf));
            }
            // Value larger than the probe: size exactly and retry once.
            buf.resize(total, 0);
            let n2 = unsafe {
                bridge::mc_persist_get(key.as_ptr(), key.len(), buf.as_mut_ptr(), buf.len())
            };
            if n2 < 0 {
                return Err(PersistError::Denied);
            }
            buf.truncate((n2 as usize).min(buf.len()));
            Ok(Some(buf))
        }
        _ => Err(PersistError::Denied),
    }
}

/// Store `val` under `key` (whole-value).
pub fn put(key: &[u8], val: &[u8]) -> Result<(), PersistError> {
    let n = unsafe { bridge::mc_persist_put(key.as_ptr(), key.len(), val.as_ptr(), val.len()) };
    if n < 0 {
        Err(PersistError::Denied)
    } else {
        Ok(())
    }
}

/// Delete `key`. Deleting a missing key succeeds.
pub fn delete(key: &[u8]) -> Result<(), PersistError> {
    let n = unsafe { bridge::mc_persist_delete(key.as_ptr(), key.len()) };
    if n < 0 {
        Err(PersistError::Denied)
    } else {
        Ok(())
    }
}

/// List every key beginning with `prefix`, as a `Vec<Vec<u8>>`.
pub fn list(prefix: &[u8]) -> Result<Vec<Vec<u8>>, PersistError> {
    let mut buf = Vec::new();
    buf.resize(PROBE, 0);
    let n = unsafe {
        bridge::mc_persist_list(prefix.as_ptr(), prefix.len(), buf.as_mut_ptr(), buf.len())
    };
    if n < 0 {
        return Err(PersistError::Denied);
    }
    let total = n as usize;
    if total > buf.len() {
        buf.resize(total, 0);
        let n2 = unsafe {
            bridge::mc_persist_list(prefix.as_ptr(), prefix.len(), buf.as_mut_ptr(), buf.len())
        };
        if n2 < 0 {
            return Err(PersistError::Denied);
        }
        buf.truncate((n2 as usize).min(buf.len()));
    } else {
        buf.truncate(total);
    }
    // NUL-separated keys; drop the trailing empty field.
    Ok(buf
        .split(|&b| b == 0)
        .filter(|k| !k.is_empty())
        .map(|k| k.to_vec())
        .collect())
}
