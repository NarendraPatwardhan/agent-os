//! Host persistence capability — the real thing, no mocks.
//!
//! `DeniedPersist` is the default policy gate: every call returns `-1` (the
//! default-deny invariant, A9). `DiskPersist` stores key/value pairs as real
//! files in a directory, so data survives a kernel restart. It is installed
//! only under `--persist-dir PATH`. The kernel reaches this through
//! `mc_persist_*` and surfaces it to the agent as the `/var/persist`
//! filesystem (`persistfs`) — the agent never sees a host path or handle.
//!
//! Return-value contract (mirrored by the kernel wrapper and bridge docs):
//!   - `get(key, out)`  → `-1` denied/error · `-2` not found · `n>=0` the FULL
//!     value length (writes `min(n, out.len())` bytes; `0` = present-but-empty).
//!   - `put(key, val)`  → `-1` denied/error · `0` ok.
//!   - `delete(key)`    → `-1` denied/error · `0` ok (missing key is ok).
//!   - `list(prefix, out)` → `-1` denied/error · `n>=0` the FULL byte length of
//!     the NUL-separated matching keys (writes `min(n, out.len())`).

use std::fs;
use std::path::PathBuf;

/// The four persistence bridge calls, behind the host's capability policy.
pub trait PersistCapability: Send + 'static {
    fn get(&mut self, key: &[u8], out: &mut [u8]) -> i32;
    fn put(&mut self, key: &[u8], val: &[u8]) -> i32;
    fn delete(&mut self, key: &[u8]) -> i32;
    fn list(&mut self, prefix: &[u8], out: &mut [u8]) -> i32;
}

/// Refuse every persistence call (the default-deny gate, A9). The kernel
/// degrades gracefully — `persistfs` surfaces denial as `PermissionDenied`.
pub struct DeniedPersist;

impl PersistCapability for DeniedPersist {
    fn get(&mut self, _key: &[u8], _out: &mut [u8]) -> i32 {
        -1
    }
    fn put(&mut self, _key: &[u8], _val: &[u8]) -> i32 {
        -1
    }
    fn delete(&mut self, _key: &[u8]) -> i32 {
        -1
    }
    fn list(&mut self, _prefix: &[u8], _out: &mut [u8]) -> i32 {
        -1
    }
}

/// A real on-disk key/value store. Each key's bytes are hex-encoded into a
/// single flat filename under `dir`, so arbitrary key bytes (including `/`)
/// are stored safely with no path traversal, and `list` can recover the keys.
pub struct DiskPersist {
    dir: PathBuf,
}

impl DiskPersist {
    /// Open (creating if needed) a store rooted at `dir`.
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        let dir = dir.into();
        let _ = fs::create_dir_all(&dir);
        DiskPersist { dir }
    }

    fn path_for(&self, key: &[u8]) -> PathBuf {
        self.dir.join(hex_encode(key))
    }
}

impl PersistCapability for DiskPersist {
    fn get(&mut self, key: &[u8], out: &mut [u8]) -> i32 {
        match fs::read(self.path_for(key)) {
            Ok(value) => {
                let n = value.len().min(out.len());
                out[..n].copy_from_slice(&value[..n]);
                // Return the FULL length so the kernel can resize + retry when
                // its probe buffer was too small.
                value.len() as i32
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => -2,
            Err(_) => -1,
        }
    }

    fn put(&mut self, key: &[u8], val: &[u8]) -> i32 {
        // Atomic publish: write a temp file then rename over the key.
        let final_path = self.path_for(key);
        let tmp_path = self.dir.join(format!("{}.tmp", hex_encode(key)));
        if fs::write(&tmp_path, val).is_err() {
            return -1;
        }
        match fs::rename(&tmp_path, &final_path) {
            Ok(()) => 0,
            Err(_) => {
                let _ = fs::remove_file(&tmp_path);
                -1
            }
        }
    }

    fn delete(&mut self, key: &[u8]) -> i32 {
        match fs::remove_file(self.path_for(key)) {
            Ok(()) => 0,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => 0, // missing is ok
            Err(_) => -1,
        }
    }

    fn list(&mut self, prefix: &[u8], out: &mut [u8]) -> i32 {
        let entries = match fs::read_dir(&self.dir) {
            Ok(e) => e,
            Err(_) => return -1,
        };
        // Collect matching keys as a NUL-separated blob (sorted for a stable,
        // deterministic listing).
        let mut keys: Vec<Vec<u8>> = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if name.ends_with(".tmp") {
                continue; // skip in-flight writes
            }
            if let Some(key) = hex_decode(name.as_bytes()) {
                if key.starts_with(prefix) {
                    keys.push(key);
                }
            }
        }
        keys.sort();
        let mut blob = Vec::new();
        for key in keys {
            blob.extend_from_slice(&key);
            blob.push(0);
        }
        let n = blob.len().min(out.len());
        out[..n].copy_from_slice(&blob[..n]);
        blob.len() as i32
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0xf) as usize] as char);
    }
    s
}

fn hex_decode(bytes: &[u8]) -> Option<Vec<u8>> {
    if bytes.len() % 2 != 0 {
        return None;
    }
    fn nib(c: u8) -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks(2) {
        out.push((nib(pair[0])? << 4) | nib(pair[1])?);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disk_persist_roundtrips_on_disk() {
        let dir = std::env::temp_dir().join(format!("mc-persist-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let mut p = DiskPersist::new(&dir);

        // not found
        let mut buf = [0u8; 64];
        assert_eq!(p.get(b"missing", &mut buf), -2);

        // put + get
        assert_eq!(p.put(b"alpha", b"hello"), 0);
        let n = p.get(b"alpha", &mut buf);
        assert_eq!(n, 5);
        assert_eq!(&buf[..5], b"hello");

        // a key with a slash and a binary byte round-trips
        assert_eq!(p.put(b"a/b\x00c", b"v"), 0);
        assert_eq!(p.get(b"a/b\x00c", &mut buf), 1);
        assert_eq!(&buf[..1], b"v");

        // list with prefix (NUL-separated, sorted)
        assert_eq!(p.put(b"alfred", b"x"), 0);
        let mut lbuf = [0u8; 256];
        let ln = p.list(b"al", &mut lbuf) as usize;
        let blob = &lbuf[..ln];
        let listed: Vec<&[u8]> = blob.split(|&b| b == 0).filter(|s| !s.is_empty()).collect();
        assert_eq!(listed, vec![&b"alfred"[..], &b"alpha"[..]]);

        // delete
        assert_eq!(p.delete(b"alpha"), 0);
        assert_eq!(p.get(b"alpha", &mut buf), -2);
        assert_eq!(p.delete(b"alpha"), 0); // idempotent

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn denied_persist_refuses() {
        let mut p = DeniedPersist;
        let mut buf = [0u8; 8];
        assert_eq!(p.get(b"k", &mut buf), -1);
        assert_eq!(p.put(b"k", b"v"), -1);
        assert_eq!(p.delete(b"k"), -1);
        assert_eq!(p.list(b"", &mut buf), -1);
    }
}
