// @generated from contracts/snapshot.kdl by //contracts/codegen:projector — do not edit.
#![no_std]

pub const SNAPSHOT_MAGIC: u32 = 1314079565;
pub const SNAPSHOT_VERSION: u32 = 2;
pub const SNAPSHOT_HEADER_LEN: usize = 128;
pub const SNAPSHOT_PAGE_SIZE: usize = 65536;
pub const SNAPSHOT_MAX_MEMORY_LEN: usize = 1073741824;
pub const SNAPSHOT_DIGEST_LEN: usize = 32;
pub const SNAPSHOT_KIND_FULL: u32 = 1;
pub const SNAPSHOT_KIND_INCREMENTAL: u32 = 2;

pub type SnapshotDigest = [u8; SNAPSHOT_DIGEST_LEN];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SnapshotKind { Full, Incremental }

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SnapshotError {
    TooShort, BadMagic, UnsupportedVersion, UnknownKind, BadHeaderLength, BadPageSize,
    EmptyMemory, MemoryTooLarge, MisalignedMemory, ReservedNonzero, MissingDigest, UnexpectedBase,
    MissingBase, UnexpectedChangedPages, BadBitmap, LengthMismatch,
}

impl core::fmt::Display for SnapshotError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let code = match self {
            Self::TooShort => "too_short", Self::BadMagic => "bad_magic",
            Self::UnsupportedVersion => "unsupported_version", Self::UnknownKind => "unknown_kind",
            Self::BadHeaderLength => "bad_header_length", Self::BadPageSize => "bad_page_size",
            Self::EmptyMemory => "empty_memory", Self::MemoryTooLarge => "memory_too_large",
            Self::MisalignedMemory => "misaligned_memory",
            Self::ReservedNonzero => "reserved_nonzero", Self::MissingDigest => "missing_digest",
            Self::UnexpectedBase => "unexpected_base", Self::MissingBase => "missing_base",
            Self::UnexpectedChangedPages => "unexpected_changed_pages", Self::BadBitmap => "bad_bitmap",
            Self::LengthMismatch => "length_mismatch",
        };
        f.write_str(code)
    }
}

#[derive(Clone, Copy)]
pub struct SnapshotView<'a> {
    pub kind: SnapshotKind,
    pub memory_len: usize,
    pub changed_pages: usize,
    pub kernel_digest: SnapshotDigest,
    pub memory_digest: SnapshotDigest,
    pub base_snapshot_digest: SnapshotDigest,
    pub bitmap: &'a [u8],
    pub pages: &'a [u8],
}

fn u32_at(bytes: &[u8], off: usize) -> u32 {
    u32::from_le_bytes([bytes[off], bytes[off + 1], bytes[off + 2], bytes[off + 3]])
}
fn digest_at(bytes: &[u8], off: usize) -> SnapshotDigest {
    let mut out = [0; SNAPSHOT_DIGEST_LEN];
    out.copy_from_slice(&bytes[off..off + SNAPSHOT_DIGEST_LEN]);
    out
}
fn missing(d: &SnapshotDigest) -> bool { d.iter().all(|b| *b == 0) }

pub fn snapshot_bitmap_len(memory_len: usize) -> usize {
    let pages = memory_len / SNAPSHOT_PAGE_SIZE;
    pages.div_ceil(8)
}

pub fn parse_snapshot(bytes: &[u8]) -> Result<SnapshotView<'_>, SnapshotError> {
    if bytes.len() < SNAPSHOT_HEADER_LEN { return Err(SnapshotError::TooShort); }
    if u32_at(bytes, 0) != SNAPSHOT_MAGIC { return Err(SnapshotError::BadMagic); }
    if u32_at(bytes, 4) != SNAPSHOT_VERSION { return Err(SnapshotError::UnsupportedVersion); }
    let kind = match u32_at(bytes, 8) {
        SNAPSHOT_KIND_FULL => SnapshotKind::Full,
        SNAPSHOT_KIND_INCREMENTAL => SnapshotKind::Incremental,
        _ => return Err(SnapshotError::UnknownKind),
    };
    if u32_at(bytes, 12) as usize != SNAPSHOT_HEADER_LEN { return Err(SnapshotError::BadHeaderLength); }
    if u32_at(bytes, 16) as usize != SNAPSHOT_PAGE_SIZE { return Err(SnapshotError::BadPageSize); }
    let memory_len = u32_at(bytes, 20) as usize;
    if memory_len == 0 { return Err(SnapshotError::EmptyMemory); }
    if memory_len > SNAPSHOT_MAX_MEMORY_LEN { return Err(SnapshotError::MemoryTooLarge); }
    if memory_len % SNAPSHOT_PAGE_SIZE != 0 { return Err(SnapshotError::MisalignedMemory); }
    let changed_pages = u32_at(bytes, 24) as usize;
    if u32_at(bytes, 28) != 0 { return Err(SnapshotError::ReservedNonzero); }
    let kernel_digest = digest_at(bytes, 32);
    let memory_digest = digest_at(bytes, 64);
    let base_snapshot_digest = digest_at(bytes, 96);
    if missing(&kernel_digest) || missing(&memory_digest) { return Err(SnapshotError::MissingDigest); }
    let payload = &bytes[SNAPSHOT_HEADER_LEN..];
    match kind {
        SnapshotKind::Full => {
            if !missing(&base_snapshot_digest) { return Err(SnapshotError::UnexpectedBase); }
            if changed_pages != 0 { return Err(SnapshotError::UnexpectedChangedPages); }
            if payload.len() != memory_len { return Err(SnapshotError::LengthMismatch); }
            Ok(SnapshotView { kind, memory_len, changed_pages, kernel_digest, memory_digest,
                base_snapshot_digest, bitmap: &[], pages: payload })
        }
        SnapshotKind::Incremental => {
            if missing(&base_snapshot_digest) { return Err(SnapshotError::MissingBase); }
            let bitmap_len = snapshot_bitmap_len(memory_len);
            if payload.len() < bitmap_len { return Err(SnapshotError::LengthMismatch); }
            let bitmap = &payload[..bitmap_len];
            let memory_pages = memory_len / SNAPSHOT_PAGE_SIZE;
            if memory_pages % 8 != 0 && bitmap.last().is_some_and(|b| *b >> (memory_pages % 8) != 0) {
                return Err(SnapshotError::BadBitmap);
            }
            let pop = bitmap.iter().map(|b| b.count_ones() as usize).sum::<usize>();
            if pop != changed_pages { return Err(SnapshotError::BadBitmap); }
            let page_bytes = changed_pages.checked_mul(SNAPSHOT_PAGE_SIZE).ok_or(SnapshotError::LengthMismatch)?;
            if payload.len() != bitmap_len + page_bytes { return Err(SnapshotError::LengthMismatch); }
            Ok(SnapshotView { kind, memory_len, changed_pages, kernel_digest, memory_digest,
                base_snapshot_digest, bitmap, pages: &payload[bitmap_len..] })
        }
    }
}

pub fn write_snapshot_header(out: &mut [u8], kind: SnapshotKind, memory_len: usize,
    changed_pages: usize, kernel_digest: &SnapshotDigest, memory_digest: &SnapshotDigest,
    base_snapshot_digest: &SnapshotDigest) -> Result<(), SnapshotError> {
    if out.len() < SNAPSHOT_HEADER_LEN { return Err(SnapshotError::TooShort); }
    if memory_len == 0 { return Err(SnapshotError::EmptyMemory); }
    if memory_len > SNAPSHOT_MAX_MEMORY_LEN { return Err(SnapshotError::MemoryTooLarge); }
    if memory_len % SNAPSHOT_PAGE_SIZE != 0 { return Err(SnapshotError::MisalignedMemory); }
    if missing(kernel_digest) || missing(memory_digest) { return Err(SnapshotError::MissingDigest); }
    match kind {
        SnapshotKind::Full if !missing(base_snapshot_digest) => return Err(SnapshotError::UnexpectedBase),
        SnapshotKind::Full if changed_pages != 0 => return Err(SnapshotError::UnexpectedChangedPages),
        SnapshotKind::Incremental if missing(base_snapshot_digest) => return Err(SnapshotError::MissingBase),
        SnapshotKind::Incremental if changed_pages > memory_len / SNAPSHOT_PAGE_SIZE =>
            return Err(SnapshotError::LengthMismatch),
        _ => {}
    }
    let memory_len = u32::try_from(memory_len).map_err(|_| SnapshotError::LengthMismatch)?;
    let changed_pages = u32::try_from(changed_pages).map_err(|_| SnapshotError::LengthMismatch)?;
    out[..SNAPSHOT_HEADER_LEN].fill(0);
    out[0..0 + 4].copy_from_slice(&SNAPSHOT_MAGIC.to_le_bytes());
    out[4..4 + 4].copy_from_slice(&SNAPSHOT_VERSION.to_le_bytes());
    out[8..8 + 4].copy_from_slice(&(match kind { SnapshotKind::Full => SNAPSHOT_KIND_FULL,
        SnapshotKind::Incremental => SNAPSHOT_KIND_INCREMENTAL }).to_le_bytes());
    out[12..12 + 4].copy_from_slice(&(SNAPSHOT_HEADER_LEN as u32).to_le_bytes());
    out[16..16 + 4].copy_from_slice(&(SNAPSHOT_PAGE_SIZE as u32).to_le_bytes());
    out[20..20 + 4].copy_from_slice(&memory_len.to_le_bytes());
    out[24..24 + 4].copy_from_slice(&changed_pages.to_le_bytes());
    out[32..32 + SNAPSHOT_DIGEST_LEN].copy_from_slice(kernel_digest);
    out[64..64 + SNAPSHOT_DIGEST_LEN].copy_from_slice(memory_digest);
    out[96..96 + SNAPSHOT_DIGEST_LEN].copy_from_slice(base_snapshot_digest);
    Ok(())
}
