//! Host persistence capability — async ABI, synchronous local implementation.
//!
//! The bridge shape is deliberately the same as host calls: `start` accepts an
//! op-tagged request blob and returns a handle, `poll` reports readiness, `body`
//! streams the result, and `close` releases the slot. `DiskPersist` still uses
//! ordinary blocking filesystem calls, but it performs them inside `start` and
//! stores the already-ready result behind the handle. That keeps the fast native
//! path simple while allowing BEAM/browser/remote hosts to answer later without
//! blocking a wasm import.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use constants_rust::{
    PERSIST_GET_ABSENT, PERSIST_GET_PRESENT, PERSIST_OP_DELETE, PERSIST_OP_GET, PERSIST_OP_LIST,
    PERSIST_OP_PUT,
};

pub const OP_GET: u32 = PERSIST_OP_GET;
pub const OP_PUT: u32 = PERSIST_OP_PUT;
pub const OP_DELETE: u32 = PERSIST_OP_DELETE;
pub const OP_LIST: u32 = PERSIST_OP_LIST;

const GET_ABSENT: u8 = PERSIST_GET_ABSENT as u8;
const GET_PRESENT: u8 = PERSIST_GET_PRESENT as u8;

pub trait PersistCapability: Send + 'static {
    /// Start an op-tagged request (`[op:u32][key_len:u32][key][value...]`).
    /// Return a handle >= 0, or -1 to deny/fail before a handle exists.
    fn start(&mut self, req: &[u8]) -> i32;
    /// `0` pending, `1` ready, `-1` failed or unknown handle.
    fn poll(&mut self, handle: i32) -> i32;
    /// Stream body bytes: `n > 0`, `0` EOF, `-1` failed.
    fn body(&mut self, handle: i32, buf: &mut [u8]) -> i32;
    fn close(&mut self, handle: i32);
}

pub struct DeniedPersist;

impl PersistCapability for DeniedPersist {
    fn start(&mut self, _req: &[u8]) -> i32 {
        -1
    }
    fn poll(&mut self, _handle: i32) -> i32 {
        -1
    }
    fn body(&mut self, _handle: i32, _buf: &mut [u8]) -> i32 {
        -1
    }
    fn close(&mut self, _handle: i32) {}
}

struct Slot {
    result: Vec<u8>,
    offset: usize,
    failed: bool,
}

/// A real on-disk key/value store. Each key's bytes are hex-encoded into a
/// single flat filename under `dir`, so arbitrary key bytes (including `/`) are
/// stored safely with no path traversal, and `list` can recover the keys.
pub struct DiskPersist {
    dir: PathBuf,
    slots: HashMap<i32, Slot>,
    next: i32,
}

impl DiskPersist {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        let dir = dir.into();
        let _ = fs::create_dir_all(&dir);
        Self {
            dir,
            slots: HashMap::new(),
            next: 1,
        }
    }

    fn path_for(&self, key: &[u8]) -> PathBuf {
        self.dir.join(hex_encode(key))
    }

    fn alloc_handle(&mut self, slot: Slot) -> i32 {
        let handle = self.next;
        self.next = self.next.wrapping_add(1).max(1);
        self.slots.insert(handle, slot);
        handle
    }

    fn run(&mut self, op: u32, key: &[u8], value: &[u8]) -> Slot {
        match op {
            OP_GET => match fs::read(self.path_for(key)) {
                Ok(value) => {
                    let mut body = Vec::with_capacity(value.len() + 1);
                    body.push(GET_PRESENT);
                    body.extend_from_slice(&value);
                    ok_slot(body)
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => ok_slot(vec![GET_ABSENT]),
                Err(_) => failed_slot(),
            },
            OP_PUT => {
                let final_path = self.path_for(key);
                let tmp_path = self.dir.join(format!("{}.tmp", hex_encode(key)));
                if fs::write(&tmp_path, value).is_err() {
                    return failed_slot();
                }
                match fs::rename(&tmp_path, &final_path) {
                    Ok(()) => ok_slot(Vec::new()),
                    Err(_) => {
                        let _ = fs::remove_file(&tmp_path);
                        failed_slot()
                    }
                }
            }
            OP_DELETE => match fs::remove_file(self.path_for(key)) {
                Ok(()) => ok_slot(Vec::new()),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => ok_slot(Vec::new()),
                Err(_) => failed_slot(),
            },
            OP_LIST => {
                let entries = match fs::read_dir(&self.dir) {
                    Ok(entries) => entries,
                    Err(_) => return failed_slot(),
                };
                let mut keys: Vec<Vec<u8>> = Vec::new();
                for entry in entries.flatten() {
                    let name = entry.file_name();
                    let name = name.to_string_lossy();
                    if name.ends_with(".tmp") {
                        continue;
                    }
                    if let Some(candidate) = hex_decode(name.as_bytes()) {
                        if candidate.starts_with(key) {
                            keys.push(candidate);
                        }
                    }
                }
                keys.sort();
                let mut body = Vec::new();
                for key in keys {
                    body.extend_from_slice(&key);
                    body.push(0);
                }
                ok_slot(body)
            }
            _ => failed_slot(),
        }
    }
}

impl PersistCapability for DiskPersist {
    fn start(&mut self, req: &[u8]) -> i32 {
        let Some((op, key, value)) = decode_request(req) else {
            return -1;
        };
        let slot = self.run(op, key, value);
        self.alloc_handle(slot)
    }

    fn poll(&mut self, handle: i32) -> i32 {
        match self.slots.get(&handle) {
            Some(slot) if slot.failed => -1,
            Some(_) => 1,
            None => -1,
        }
    }

    fn body(&mut self, handle: i32, buf: &mut [u8]) -> i32 {
        match self.slots.get_mut(&handle) {
            Some(slot) if slot.failed => -1,
            Some(slot) => {
                let remaining = &slot.result[slot.offset..];
                let n = remaining.len().min(buf.len());
                buf[..n].copy_from_slice(&remaining[..n]);
                slot.offset += n;
                n as i32
            }
            None => -1,
        }
    }

    fn close(&mut self, handle: i32) {
        self.slots.remove(&handle);
    }
}

fn ok_slot(result: Vec<u8>) -> Slot {
    Slot {
        result,
        offset: 0,
        failed: false,
    }
}

fn failed_slot() -> Slot {
    Slot {
        result: Vec::new(),
        offset: 0,
        failed: true,
    }
}

pub fn decode_request(req: &[u8]) -> Option<(u32, &[u8], &[u8])> {
    if req.len() < 8 {
        return None;
    }
    let op = u32::from_le_bytes([req[0], req[1], req[2], req[3]]);
    let key_len = u32::from_le_bytes([req[4], req[5], req[6], req[7]]) as usize;
    let key_start = 8usize;
    let key_end = key_start.checked_add(key_len)?;
    if key_end > req.len() {
        return None;
    }
    Some((op, &req[key_start..key_end], &req[key_end..]))
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
