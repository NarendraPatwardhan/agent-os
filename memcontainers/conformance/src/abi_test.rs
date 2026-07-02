use std::collections::{BTreeMap, BTreeSet};

use mc_rust::SYSCALL_NAMES;
use wasm_imports::imported_function_symbols_by_module;

const IMAGES: &[(&str, &str)] = &[
    ("minimal", "_main/memcontainers/images/minimal.tar"),
    ("posix", "_main/memcontainers/images/posix.tar"),
    ("svc_test", "_main/memcontainers/images/svc_test.tar"),
    ("atlas", "_main/memcontainers/images/atlas.tar"),
    ("paper", "_main/memcontainers/images/paper.tar"),
];

// A declared syscall may be absent from the shipped images only when the reason
// is tied to a specific subsystem, not because the conformance gate has not
// caught up yet. If a guest starts importing one of these, remove the exclusion.
const COVERAGE_EXCLUSIONS: &[(&str, &str)] = &[
    (
        "mc_sys_dup",
        "fd-table primitive reserved for POSIX duplication semantics; no shipped guest currently calls dup directly",
    ),
    (
        "mc_sys_dup2",
        "fd-table primitive reserved for explicit descriptor-number duplication; no shipped guest currently calls dup2 directly",
    ),
];

#[derive(Debug)]
struct Guest {
    image: &'static str,
    path: String,
    bytes: Vec<u8>,
}

fn runfile(path: &str) -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r
        .rlocation(path)
        .unwrap_or_else(|| panic!("{path} not found in runfiles"));
    std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

fn parse_octal(field: &[u8]) -> usize {
    let text = field
        .iter()
        .take_while(|b| **b != 0 && **b != b' ')
        .map(|b| *b as char)
        .collect::<String>();
    if text.trim().is_empty() {
        0
    } else {
        usize::from_str_radix(text.trim(), 8)
            .unwrap_or_else(|e| panic!("bad tar octal field {text:?}: {e}"))
    }
}

fn tar_name(header: &[u8]) -> String {
    fn cstr(bytes: &[u8]) -> String {
        let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
        String::from_utf8_lossy(&bytes[..end]).into_owned()
    }

    let name = cstr(&header[0..100]);
    let prefix = cstr(&header[345..500]);
    if prefix.is_empty() {
        name
    } else {
        format!("{prefix}/{name}")
    }
}

fn wasm_guests(image: &'static str, tar: &[u8]) -> Vec<Guest> {
    let mut out = Vec::new();
    let mut off = 0usize;
    while off + 512 <= tar.len() {
        let header = &tar[off..off + 512];
        if header.iter().all(|b| *b == 0) {
            break;
        }
        let size = parse_octal(&header[124..136]);
        let kind = header[156];
        let data_start = off + 512;
        let data_end = data_start
            .checked_add(size)
            .filter(|end| *end <= tar.len())
            .unwrap_or_else(|| panic!("{image}: tar entry extends past end at offset {off}"));
        let data = &tar[data_start..data_end];
        if matches!(kind, 0 | b'0') && data.starts_with(b"\0asm") {
            out.push(Guest {
                image,
                path: tar_name(header),
                bytes: data.to_vec(),
            });
        }
        off = data_start + size.div_ceil(512) * 512;
    }
    out
}

fn all_guests() -> Vec<Guest> {
    let mut guests = Vec::new();
    for (image, path) in IMAGES {
        guests.extend(wasm_guests(image, &runfile(path)));
    }
    guests
}

fn declared_syscalls() -> BTreeSet<String> {
    SYSCALL_NAMES.iter().map(|s| (*s).to_string()).collect()
}

fn exclusions() -> BTreeMap<&'static str, &'static str> {
    COVERAGE_EXCLUSIONS.iter().copied().collect()
}

#[test]
fn shipped_guests_import_only_the_declared_mc_surface() {
    let declared = declared_syscalls();
    let guests = all_guests();
    assert!(!guests.is_empty(), "no wasm guests found in conformance images");

    let mut failures = Vec::new();
    for guest in guests {
        let modules = imported_function_symbols_by_module(&guest.bytes)
            .unwrap_or_else(|e| panic!("{}:{}: read imports: {e}", guest.image, guest.path));

        let non_mc: BTreeMap<_, _> = modules
            .iter()
            .filter(|(module, _)| module.as_str() != "mc")
            .collect();
        if !non_mc.is_empty() {
            failures.push(format!(
                "{}:{} imports non-mc functions: {non_mc:?}",
                guest.image, guest.path
            ));
        }

        let mc = modules.get("mc").cloned().unwrap_or_default();
        if mc.is_empty() {
            failures.push(format!(
                "{}:{} imports no mc functions; the guest boundary was not exercised",
                guest.image, guest.path
            ));
        }

        let undeclared: Vec<_> = mc.difference(&declared).cloned().collect();
        if !undeclared.is_empty() {
            failures.push(format!(
                "{}:{} imports undeclared mc syscalls: {undeclared:?}",
                guest.image, guest.path
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "guest import conformance failed:\n{}",
        failures.join("\n")
    );
}

#[test]
fn declared_syscalls_are_covered_or_explicitly_excluded() {
    let declared = declared_syscalls();
    let excluded = exclusions();
    let mut covered = BTreeSet::new();
    let mut sources: BTreeMap<String, Vec<String>> = BTreeMap::new();

    for guest in all_guests() {
        let modules = imported_function_symbols_by_module(&guest.bytes)
            .unwrap_or_else(|e| panic!("{}:{}: read imports: {e}", guest.image, guest.path));
        for syscall in modules.get("mc").into_iter().flatten() {
            covered.insert(syscall.clone());
            sources
                .entry(syscall.clone())
                .or_default()
                .push(format!("{}:{}", guest.image, guest.path));
        }
    }

    let unknown_exclusions: Vec<_> = excluded
        .keys()
        .filter(|syscall| !declared.contains(**syscall))
        .copied()
        .collect();
    assert!(
        unknown_exclusions.is_empty(),
        "coverage exclusions name syscalls not declared in contracts/syscalls.kdl: {unknown_exclusions:?}"
    );

    let stale_exclusions: Vec<_> = excluded
        .keys()
        .filter(|syscall| covered.contains(**syscall))
        .map(|syscall| (*syscall, sources.get(*syscall).cloned().unwrap_or_default()))
        .collect();
    assert!(
        stale_exclusions.is_empty(),
        "coverage exclusions are stale because shipped guests now import them: {stale_exclusions:?}"
    );

    let missing: Vec<_> = declared
        .iter()
        .filter(|syscall| !covered.contains(*syscall) && !excluded.contains_key(syscall.as_str()))
        .cloned()
        .collect();
    assert!(
        missing.is_empty(),
        "declared syscalls lack a shipped guest import and have no documented conformance exclusion: {missing:?}"
    );
}
