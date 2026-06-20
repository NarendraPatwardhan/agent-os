//! A minimal no_std POSIX-ustar writer — the exact inverse of `tarfs::parse_header`
//! (so a committed layer round-trips through `TarFs::new`). Used by `CowFs::
//! commit_layer` to serialize a live CoW overlay (the diff since boot) into a
//! content-addressed `.tar` layer, with OCI `.wh.<name>` whiteouts for deletions.
//!
//! Field layout (512-byte header), matching the reader byte-for-byte:
//!   name 0-99 · mode 100-107 (octal) · uid 108-115 · gid 116-123 ·
//!   size 124-135 (octal, bytes) · mtime 136-147 (octal, SECONDS) ·
//!   checksum 148-155 · typeflag 156 ('0' file/'2' symlink/'5' dir) ·
//!   linkname 157-256 · magic "ustar\0" 257-262 · version "00" 263-264
//!
//! Limitation: a path must fit the ustar name+prefix fields (100+155 bytes) and a
//! linkname must fit the 100-byte field; longer values are truncated. Sizes up to
//! 2^33 fit the 11-octal-digit size field.

use alloc::string::String;
use alloc::vec::Vec;

const BLOCK: usize = 512;

const TYPE_FILE: u8 = b'0';
const TYPE_HARDLINK: u8 = b'1';
const TYPE_SYMLINK: u8 = b'2';
const TYPE_DIR: u8 = b'5';

pub struct TarWriter {
    out: Vec<u8>,
}

impl TarWriter {
    pub fn new() -> Self {
        TarWriter { out: Vec::new() }
    }

    /// A regular file with its bytes.
    pub fn append_file(&mut self, path: &str, data: &[u8], mode: u16, mtime_secs: i64) {
        self.header(
            &rel(path),
            TYPE_FILE,
            data.len() as u64,
            mode,
            mtime_secs,
            "",
        );
        self.out.extend_from_slice(data);
        self.pad(data.len());
    }

    /// A directory (size 0; name carries a trailing `/` by tar convention).
    pub fn append_dir(&mut self, path: &str, mode: u16, mtime_secs: i64) {
        let mut name = rel(path);
        if !name.ends_with('/') {
            name.push('/');
        }
        self.header(&name, TYPE_DIR, 0, mode, mtime_secs, "");
    }

    /// A symbolic link (target in the linkname field; mode 0o777, size 0).
    pub fn append_symlink(&mut self, path: &str, target: &str, mtime_secs: i64) {
        self.header(&rel(path), TYPE_SYMLINK, 0, 0o777, mtime_secs, target);
    }

    /// A hard link: a 0-byte entry (typeflag `1`) whose linkname names an EARLIER
    /// regular-file entry in the same archive. `tarfs::build_index` resolves both
    /// names to that entry's bytes, so the content is stored exactly once and the
    /// link relationship survives the commit. `target` must already have been
    /// emitted via `append_file`; share the inode's `mode`/`mtime` (both names do).
    pub fn append_hardlink(&mut self, path: &str, target: &str, mode: u16, mtime_secs: i64) {
        self.header(&rel(path), TYPE_HARDLINK, 0, mode, mtime_secs, &rel(target));
    }

    /// An OCI whiteout marking `path` deleted in lower layers: a 0-byte file
    /// `<parent>/.wh.<name>`.
    pub fn append_whiteout(&mut self, path: &str) {
        let trimmed = path.trim_end_matches('/');
        let (parent, name) = match trimmed.rfind('/') {
            Some(0) => ("", &trimmed[1..]),
            Some(i) => (&trimmed[..i], &trimmed[i + 1..]),
            None => ("", trimmed),
        };
        let wh = alloc::format!("{}/.wh.{}", parent, name);
        self.header(&rel(&wh), TYPE_FILE, 0, 0o644, 0, "");
    }

    /// Finish the archive: two trailing zero blocks (the reader stops on the
    /// first all-zero block).
    pub fn finish(mut self) -> Vec<u8> {
        self.out.resize(self.out.len() + 2 * BLOCK, 0);
        self.out
    }

    fn header(
        &mut self,
        name: &str,
        typeflag: u8,
        size: u64,
        mode: u16,
        mtime_secs: i64,
        link: &str,
    ) {
        let mut h = [0u8; BLOCK];
        put_path(&mut h, name);
        put_octal(&mut h, 100, 8, (mode & 0o7777) as u64); // mode
        put_octal(&mut h, 108, 8, 0); // uid
        put_octal(&mut h, 116, 8, 0); // gid
        put_octal(&mut h, 124, 12, size);
        put_octal(&mut h, 136, 12, mtime_secs.max(0) as u64);
        h[156] = typeflag;
        put_str(&mut h, 157, 100, link);
        h[257..263].copy_from_slice(b"ustar\0");
        h[263] = b'0';
        h[264] = b'0';
        // Checksum: sum all bytes with the checksum field taken as 8 spaces, then
        // write 6 octal digits + NUL + space (the conventional encoding).
        for b in &mut h[148..156] {
            *b = b' ';
        }
        let sum: u32 = h.iter().map(|&b| b as u32).sum();
        let cs = alloc::format!("{:06o}", sum);
        let cb = cs.as_bytes();
        h[148..148 + cb.len().min(6)].copy_from_slice(&cb[..cb.len().min(6)]);
        h[154] = 0;
        h[155] = b' ';
        self.out.extend_from_slice(&h);
    }

    /// Pad the just-written `n` data bytes up to a 512 boundary with zeros.
    fn pad(&mut self, n: usize) {
        let rem = n % BLOCK;
        if rem != 0 {
            self.out.resize(self.out.len() + (BLOCK - rem), 0);
        }
    }
}

/// Strip a leading `/` to a tar-relative name (the reader re-adds it).
fn rel(path: &str) -> String {
    String::from(path.strip_prefix('/').unwrap_or(path))
}

/// Copy `s` into `h[start..start+len]` (truncating to the field width; the rest
/// of the field is already zero).
fn put_str(h: &mut [u8; BLOCK], start: usize, len: usize, s: &str) {
    let b = s.as_bytes();
    let n = b.len().min(len);
    h[start..start + n].copy_from_slice(&b[..n]);
}

/// Write a ustar path using `name` (100 bytes) and, for nested long paths,
/// `prefix` (155 bytes). Falls back to truncating the name field only if the
/// path cannot be split into the ustar shape.
fn put_path(h: &mut [u8; BLOCK], path: &str) {
    if path.as_bytes().len() <= 100 {
        put_str(h, 0, 100, path);
        return;
    }

    let mut split_at = None;
    for (idx, ch) in path.char_indices() {
        if ch != '/' {
            continue;
        }
        let prefix_len = idx;
        let name_len = path[idx + 1..].as_bytes().len();
        if prefix_len <= 155 && name_len <= 100 {
            split_at = Some(idx);
        }
    }

    if let Some(idx) = split_at {
        put_str(h, 0, 100, &path[idx + 1..]);
        put_str(h, 345, 155, &path[..idx]);
    } else {
        put_str(h, 0, 100, path);
    }
}

/// Write `val` as zero-padded octal ASCII into a `len`-byte field, NUL-terminated
/// (so `len-1` octal digits). Mirrors `tarfs`'s `from_str_radix(trim, 8)` read.
fn put_octal(h: &mut [u8; BLOCK], start: usize, len: usize, val: u64) {
    let digits = len - 1;
    let s = alloc::format!("{:0width$o}", val, width = digits);
    let b = s.as_bytes();
    // If the value somehow overflows the field, keep the low-order digits.
    let take = b.len().min(digits);
    let off = b.len() - take;
    h[start..start + take].copy_from_slice(&b[off..]);
    h[start + digits] = 0;
}
