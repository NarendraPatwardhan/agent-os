//! mc-abi-gate — drift gate for the HAND-KEPT Zig syscall externs in third_party/luau/glue/mc.zig.
//!
//! mc.zig declares `pub extern "mc" fn mc_sys_*` by hand (Zig has no way to GENERATE callable extern
//! decls, so the projector can't emit them like it does the Rust/zig DESCRIPTOR tables). This test
//! pins those hand-written signatures to the projected contract: for every syscall mc.zig declares,
//! its parameter types and return type must match contracts/gen/mc.gen.zig's descriptor. A contract
//! change that mc.zig doesn't mirror — or a typo — fails the build, the gate codex #9 asked for.
//! (`mc_sys_exit` is the one documented exception: the contract marks it `noreturn`, but the kernel
//! registers the import as `(i32) -> i32`, so mc.zig declares `i32`; the gate allows exactly that.)
//!
//! Both files arrive via `compile_data` and are embedded with `include_str!` — no runfiles, no deps.

const MC_ZIG: &str = include_str!("../../../third_party/luau/glue/mc.zig");
const CONTRACT: &str = include_str!("../../../contracts/gen/mc.gen.zig");

/// One syscall signature: ordered parameter types and the return type, as written.
#[derive(Debug, PartialEq, Eq)]
struct Sig {
    params: Vec<String>,
    ret: String,
}

/// Parse mc.zig's `pub extern "mc" fn mc_sys_NAME(a: T1, b: T2, ...) RET;` lines.
fn parse_mc_zig(src: &str) -> Vec<(String, Sig)> {
    let mut out = Vec::new();
    for line in src.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("pub extern \"mc\" fn mc_sys_") else {
            continue;
        };
        let name_end = rest.find('(').expect("extern decl has '('");
        let name = format!("mc_sys_{}", &rest[..name_end]);
        let after = &rest[name_end + 1..];
        let params_end = after.find(')').expect("extern decl has ')'");
        let params: Vec<String> = after[..params_end]
            .split(',')
            .filter(|p| !p.trim().is_empty())
            .map(|p| p.split(':').nth(1).expect("param has a type").trim().to_string())
            .collect();
        let ret = after[params_end + 1..].trim_end_matches(';').trim().to_string();
        out.push((name, Sig { params, ret }));
    }
    out
}

/// Pull `"..."` after `key` starting at/after `from`, returning (value, index just past the close).
fn quoted_after(s: &str, key: &str, from: usize) -> Option<(String, usize)> {
    let k = s[from..].find(key)? + from + key.len();
    let q = s[k..].find('"')? + k + 1;
    let e = s[q..].find('"')? + q;
    Some((s[q..e].to_string(), e + 1))
}

/// Parse contracts/gen/mc.gen.zig's descriptor lines: one `.{ .name="mc_sys_X", ... .args = &.{
/// .{ .name=.., .ty="T" }, ... }, .ret = "R" }` per syscall. The FIRST `.name` is the syscall; every
/// `.ty` is an arg type (in order); `.ret` is the return.
fn parse_contract(src: &str) -> Vec<(String, Sig)> {
    let mut out = Vec::new();
    for line in src.lines() {
        if !line.contains(".name = \"mc_sys_") {
            continue;
        }
        let (name, _) = quoted_after(line, ".name = ", 0).unwrap();
        let ret_at = line.find(".ret = ").expect("descriptor has .ret");
        // Arg types: every `.ty = "T"` occurring before `.ret` (all of them, in the args block).
        let mut params = Vec::new();
        let mut pos = 0;
        while let Some(rel) = line[pos..].find(".ty = ") {
            let at = pos + rel;
            if at > ret_at {
                break;
            }
            let (ty, next) = quoted_after(line, ".ty = ", at).unwrap();
            params.push(ty);
            pos = next;
        }
        let (ret, _) = quoted_after(line, ".ret = ", ret_at).unwrap();
        out.push((name, Sig { params, ret }));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn mc_zig_externs_match_the_contract() {
        let contract: HashMap<String, Sig> = parse_contract(CONTRACT).into_iter().collect();
        let externs = parse_mc_zig(MC_ZIG);
        assert!(externs.len() >= 30, "parsed too few externs ({}) — parser broke", externs.len());

        let mut errs = Vec::new();
        for (name, sig) in &externs {
            let Some(want) = contract.get(name) else {
                errs.push(format!("{name}: declared in mc.zig but ABSENT from the contract"));
                continue;
            };
            if sig.params != want.params {
                errs.push(format!("{name}: params {:?} != contract {:?}", sig.params, want.params));
            }
            // `noreturn` in the contract is registered by the kernel as an i32-returning import.
            let ret_ok = sig.ret == want.ret || (want.ret == "noreturn" && sig.ret == "i32");
            if !ret_ok {
                errs.push(format!("{name}: ret `{}` != contract `{}`", sig.ret, want.ret));
            }
        }
        assert!(errs.is_empty(), "mc.zig drifted from the contract:\n{}", errs.join("\n"));
    }
}
