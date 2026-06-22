//! mc-stamp — append the kernel's load-time `mc_tier` + `mc_budget` WASM custom sections to a guest.
//!
//! Usage: mc-stamp <in.wasm> <out.wasm> <tier> <mem_bytes> <fuel> <table>
//!
//! A WASM custom section is `0x00 <uleb body_len> <uleb name_len> <name> <payload>`, appended to the
//! module (the kernel's parser walks every top-level section, so trailing sections are found). The
//! payload layouts are the load-time contract with the kernel (mirrors the sysroot's
//! declare_tier!/declare_budget!): mc_tier = the raw UTF-8 tier; mc_budget =
//! [u32 version=1][u64 mem][u64 fuel][u32 table], little-endian (24 bytes).

use std::process::exit;

fn uleb(mut n: u64, out: &mut Vec<u8>) {
    loop {
        let b = (n & 0x7f) as u8;
        n >>= 7;
        if n != 0 {
            out.push(b | 0x80);
        } else {
            out.push(b);
            break;
        }
    }
}

fn append_custom(name: &[u8], payload: &[u8], out: &mut Vec<u8>) {
    let mut body = Vec::new();
    uleb(name.len() as u64, &mut body);
    body.extend_from_slice(name);
    body.extend_from_slice(payload);
    out.push(0); // custom section id
    uleb(body.len() as u64, out);
    out.extend_from_slice(&body);
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 7 {
        eprintln!("usage: mc-stamp <in.wasm> <out.wasm> <tier> <mem_bytes> <fuel> <table>");
        exit(2);
    }
    let parse = |s: &str| -> u64 {
        s.parse().unwrap_or_else(|_| {
            eprintln!("mc-stamp: not a number: {s}");
            exit(2)
        })
    };
    let tier = a[3].as_bytes();
    let mem = parse(&a[4]);
    let fuel = parse(&a[5]);
    let table = parse(&a[6]) as u32;

    let mut wasm = std::fs::read(&a[1]).unwrap_or_else(|e| {
        eprintln!("mc-stamp: read {}: {e}", a[1]);
        exit(1)
    });
    if wasm.len() < 8 || &wasm[..4] != b"\0asm" {
        eprintln!("mc-stamp: {} is not a wasm module", a[1]);
        exit(1);
    }

    append_custom(b"mc_tier", tier, &mut wasm);

    let mut budget = Vec::with_capacity(24);
    budget.extend_from_slice(&1u32.to_le_bytes()); // version
    budget.extend_from_slice(&mem.to_le_bytes());
    budget.extend_from_slice(&fuel.to_le_bytes());
    budget.extend_from_slice(&table.to_le_bytes());
    append_custom(b"mc_budget", &budget, &mut wasm);

    std::fs::write(&a[2], &wasm).unwrap_or_else(|e| {
        eprintln!("mc-stamp: write {}: {e}", a[2]);
        exit(1)
    });
}
