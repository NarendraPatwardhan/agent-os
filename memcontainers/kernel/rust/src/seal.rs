//! Embedded provenance seal.
//!
//! The attribution line is stored XOR-obfuscated with an LCG keystream — *not*
//! as a plaintext string — so it does not show up under `strings`/grep over the
//! compiled `kernel.wasm`, and is decoded fresh at runtime on every boot. A
//! compile-time checksum of the original bytes gates the print: zeroing or
//! patching the ciphertext in a stolen binary is detectable, so a tampered seal
//! simply refuses to emit rather than printing a garbled line.
//!
//! This raises the cost of stripping attribution from a *binary*; it is not
//! claimed to be unbreakable against an attacker who also has the source.
//!
//! To change the displayed line, edit `PLAINTEXT` and rebuild — the obfuscated
//! bytes are recomputed at compile time.

use crate::bridge;

/// The provenance line. Consumed ONLY at compile time (by `obfuscate` and
/// `checksum`); it is never referenced at runtime, so the plaintext is not
/// emitted into the wasm data section — only the ciphertext `SEAL` is.
const PLAINTEXT: &str = "memcontainers v0.1.0 · © 2026 opyt.cloud · BSL-1.1";

const N: usize = PLAINTEXT.len();

/// Keystream seed. Any nonzero constant; changing it re-obfuscates on rebuild.
const SEED: u64 = 0x9E37_79B9_7F4A_7C15;

/// One step of a 64-bit LCG (Knuth/MMIX multiplier + odd increment).
const fn step(state: u64) -> u64 {
    state
        .wrapping_mul(6_364_136_223_846_793_005)
        .wrapping_add(1_442_695_040_888_963_407)
}

/// FNV-ish rolling checksum (so tampering with the bytes is detectable).
const fn checksum(bytes: &[u8]) -> u32 {
    let mut sum: u32 = 0x811C_9DC5;
    let mut i = 0;
    while i < bytes.len() {
        sum = sum.wrapping_add(bytes[i] as u32).wrapping_mul(0x0100_0193);
        i += 1;
    }
    sum
}

/// XOR each plaintext byte with the high byte of the evolving keystream.
const fn obfuscate() -> [u8; N] {
    let src = PLAINTEXT.as_bytes();
    let mut out = [0u8; N];
    let mut s = SEED;
    let mut i = 0;
    while i < N {
        s = step(s);
        out[i] = src[i] ^ (s >> 56) as u8;
        i += 1;
    }
    out
}

/// Ciphertext baked into the binary (the only form the plaintext takes here).
const SEAL: [u8; N] = obfuscate();
/// Expected checksum of the decoded line.
const CHECK: u32 = checksum(PLAINTEXT.as_bytes());

/// Decode the seal and write it to stdout once, on boot. If the ciphertext was
/// tampered with in the binary, the checksum won't match and the (garbled) line
/// is suppressed rather than printed.
#[inline(never)]
pub fn emit() {
    let mut buf = [0u8; N];
    let mut s = SEED;
    let mut i = 0;
    while i < N {
        s = step(s);
        buf[i] = SEAL[i] ^ (s >> 56) as u8;
        i += 1;
    }
    if checksum(&buf) == CHECK {
        let nl = b"\r\n";
        // SAFETY: same host-call the boot banner uses; `buf`/`nl` outlive the call.
        unsafe {
            bridge::mc_stdout_write(buf.as_ptr(), buf.len());
            bridge::mc_stdout_write(nl.as_ptr(), nl.len());
        }
    }
}
