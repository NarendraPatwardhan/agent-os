//! wasm-imports — the wasm import-section oracle shared by conformance (SYSTEMS.md) and
//! capability attestation (SYSTEMS.md).
//!
//! Both gates do the *same* thing to a guest `.wasm`: walk its import section and look at
//! the FUNCTION symbols it imports from one module (the `mc` syscall module, or the `env`
//! bridge). They diverge only in the *set* they check those symbols against:
//!
//!   - Conformance (SYSTEMS.md section 9.3) checks a guest's `mc` imports ⊆ the declared syscall table
//!     (SAFETY: no guest imports an undeclared `mc::` symbol) and, across all guests, that
//!     every declared syscall is imported by ≥1 guest (COVERAGE).
//!   - Attestation (SYSTEMS.md section 9.3) checks a guest's `mc` imports ⊆ its tier's allowed syscalls
//!     (the capability × syscall matrix) — capability drift caught at build time,
//!     an enforcement of default-deny (A9) at authoring time, not just at exec.
//!
//! Because the only difference is the comparison set, there is exactly ONE primitive here:
//! [`imported_function_symbols`], which returns the sorted, de-duplicated set of imported
//! *function* symbol names a module pulls from a wasm binary. Memory, table, and global
//! imports are intentionally ignored — a syscall/bridge surface is functions. Callers layer
//! the set comparison (⊆ a table, ⊆ a tier, coverage union) on top; the walk lives here.
//!
//! Malformed input is data, not a crash: every fallible path returns [`Result`] so a
//! truncated or non-wasm file surfaces as an error a build rule can report, never a panic.

use std::collections::BTreeSet;

use anyhow::{Context, Result};
use wasmparser::{Parser, Payload, TypeRef};

/// The function symbols a wasm module imports from one named module, sorted and unique.
///
/// `BTreeSet<String>` is the load-bearing type: iteration is sorted (so the CLI's
/// line-per-symbol output and any golden file are stable) and membership is the natural
/// shape for the ⊆ / coverage checks conformance and attestation perform — neither has to
/// re-sort or re-dedup. Construct it via [`ImportedSymbols::from_wasm`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportedSymbols {
    /// The module these symbols were imported *from* (e.g. `"mc"` or `"env"`).
    pub module: String,
    /// The imported function symbol names, sorted and de-duplicated.
    pub names: BTreeSet<String>,
}

impl ImportedSymbols {
    /// Walk `wasm` and collect the FUNCTION imports whose import module equals `module`.
    ///
    /// Only the import section is parsed; every other section is skipped. Only
    /// [`TypeRef::Func`] imports count — table/memory/global imports from the same module
    /// are ignored, because a syscall/bridge surface is functions.
    pub fn from_wasm(wasm: &[u8], module: &str) -> Result<Self> {
        let names = imported_function_symbols(wasm, module)?;
        Ok(Self {
            module: module.to_string(),
            names,
        })
    }

    /// Borrowing iterator over the symbol names in sorted order.
    pub fn iter(&self) -> impl Iterator<Item = &str> {
        self.names.iter().map(String::as_str)
    }

    /// `true` if `symbol` is among the imported function symbols.
    pub fn contains(&self, symbol: &str) -> bool {
        self.names.contains(symbol)
    }

    /// The symbols required by `required` that this module does NOT import.
    ///
    /// The coverage / `--require` direction: the caller hands the set it expects to be
    /// present (a tier's mandatory syscalls, an `env` bridge's symbols) and gets back what
    /// is missing. An empty result means every required symbol is imported.
    pub fn missing<'a, I, S>(&self, required: I) -> BTreeSet<String>
    where
        I: IntoIterator<Item = &'a S>,
        S: AsRef<str> + 'a + ?Sized,
    {
        required
            .into_iter()
            .map(|s| s.as_ref())
            .filter(|s| !self.names.contains(*s))
            .map(str::to_string)
            .collect()
    }

    /// The imported symbols that are NOT in `allowed` — the safety / attestation direction.
    ///
    /// The caller hands the permitted set (the declared syscall table, a tier's allowed
    /// syscalls); the result is the symbols this module imports that fall *outside* it. An
    /// empty result means `imports ⊆ allowed` — the property both SYSTEMS.md section 9.3 safety and
    /// attestation assert.
    pub fn disallowed<'a, I, S>(&self, allowed: I) -> BTreeSet<String>
    where
        I: IntoIterator<Item = &'a S>,
        S: AsRef<str> + 'a + ?Sized,
    {
        let allowed: BTreeSet<&str> = allowed.into_iter().map(|s| s.as_ref()).collect();
        self.names
            .iter()
            .filter(|s| !allowed.contains(s.as_str()))
            .cloned()
            .collect()
    }
}

/// The core walk: the sorted, unique set of FUNCTION symbol names imported from `module`.
///
/// This is the single primitive both gates build on. It parses only the import section of
/// `wasm`; a module importing the same function name twice (legal but odd) collapses to one
/// entry. Returns an error — never panics — on a truncated or otherwise malformed binary.
pub fn imported_function_symbols(wasm: &[u8], module: &str) -> Result<BTreeSet<String>> {
    let mut names = BTreeSet::new();

    for payload in Parser::new(0).parse_all(wasm) {
        // A parse error here is a malformed/truncated wasm; surface it, don't unwrap.
        let payload = payload.context("parsing wasm payload")?;
        if let Payload::ImportSection(reader) = payload {
            // `into_imports()` flattens every import-group encoding (single + the two
            // compact forms) into individual `Import { module, name, ty }` entries, so we
            // never have to match the grouping variants ourselves.
            for import in reader.into_imports() {
                let import = import.context("reading an import entry")?;
                // Functions only — a syscall/bridge surface is functions; table/memory/
                // global imports from the same module are not part of it.
                if matches!(import.ty, TypeRef::Func(_)) && import.module == module {
                    names.insert(import.name.to_string());
                }
            }
            // The import section is unique in a core module; once seen we are done.
            break;
        }
    }

    Ok(names)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal hand-rolled wasm module:
    ///   (import "mc" "sys_write" (func))      ; a function import we want
    ///   (import "mc" "shared_mem" (memory 1)) ; a NON-function import from the same module
    ///   (import "env" "now" (func))           ; a function import from a different module
    /// Plus a single function type. Encoded by hand so the unit tests need no toolchain.
    fn fixture_wasm() -> Vec<u8> {
        let mut m = Vec::new();
        m.extend_from_slice(b"\0asm"); // magic
        m.extend_from_slice(&1u32.to_le_bytes()); // version 1

        // Type section (id 1): one type, `() -> ()`.
        //   count=1; form=0x60 (func); params=0; results=0
        let type_sec = [0x01u8, 0x60, 0x00, 0x00];
        m.push(0x01);
        m.push(type_sec.len() as u8);
        m.extend_from_slice(&type_sec);

        // Import section (id 2): three imports.
        let mut imports = Vec::new();
        imports.push(0x03u8); // count = 3

        // ("mc","sys_write") func type 0  → desc 0x00, typeidx 0
        push_name(&mut imports, "mc");
        push_name(&mut imports, "sys_write");
        imports.extend_from_slice(&[0x00, 0x00]);

        // ("mc","shared_mem") memory {min=1} → desc 0x02, limits flag 0x00, min 1
        push_name(&mut imports, "mc");
        push_name(&mut imports, "shared_mem");
        imports.extend_from_slice(&[0x02, 0x00, 0x01]);

        // ("env","now") func type 0 → desc 0x00, typeidx 0
        push_name(&mut imports, "env");
        push_name(&mut imports, "now");
        imports.extend_from_slice(&[0x00, 0x00]);

        m.push(0x02);
        m.push(imports.len() as u8);
        m.extend_from_slice(&imports);
        m
    }

    /// Encode a wasm name: u8 length (these fixtures stay < 128 bytes) then the UTF-8 bytes.
    fn push_name(buf: &mut Vec<u8>, s: &str) {
        assert!(s.len() < 0x80, "fixture names stay single-byte LEB length");
        buf.push(s.len() as u8);
        buf.extend_from_slice(s.as_bytes());
    }

    #[test]
    fn collects_function_imports_from_the_named_module() {
        let got = imported_function_symbols(&fixture_wasm(), "mc").unwrap();
        let want: BTreeSet<String> = ["sys_write"].iter().map(|s| s.to_string()).collect();
        assert_eq!(got, want, "only the mc *function* import should be returned");
    }

    #[test]
    fn ignores_non_function_imports() {
        // `shared_mem` is a memory import from "mc"; it must never appear.
        let got = imported_function_symbols(&fixture_wasm(), "mc").unwrap();
        assert!(!got.contains("shared_mem"), "memory imports are not syscalls");
    }

    #[test]
    fn scopes_to_the_requested_module() {
        let env = imported_function_symbols(&fixture_wasm(), "env").unwrap();
        assert_eq!(env.len(), 1);
        assert!(env.contains("now"), "env module exposes only `now`");
        // A module no import names → empty set, not an error.
        let none = imported_function_symbols(&fixture_wasm(), "nonexistent").unwrap();
        assert!(none.is_empty());
    }

    #[test]
    fn subset_and_coverage_helpers_agree() {
        let syms = ImportedSymbols::from_wasm(&fixture_wasm(), "mc").unwrap();
        // imports ⊆ allowed  ⇒ disallowed() empty.
        assert!(syms.disallowed(&["sys_write", "sys_read"]).is_empty());
        // an import outside the allowed set is flagged.
        assert_eq!(
            syms.disallowed(&["sys_read"]),
            ["sys_write"].iter().map(|s| s.to_string()).collect()
        );
        // a required symbol that is present is not missing; an absent one is.
        assert!(syms.missing(&["sys_write"]).is_empty());
        assert_eq!(
            syms.missing(&["sys_write", "sys_close"]),
            ["sys_close"].iter().map(|s| s.to_string()).collect()
        );
    }

    #[test]
    fn malformed_input_is_an_error_not_a_panic() {
        // Right magic, truncated section → parse error, surfaced as Err.
        let mut bad = b"\0asm".to_vec();
        bad.extend_from_slice(&1u32.to_le_bytes());
        bad.push(0x02); // import section id …
        bad.push(0x05); // … claims 5 bytes …
        bad.extend_from_slice(&[0x01, 0x02]); // … but only 2 follow.
        assert!(imported_function_symbols(&bad, "mc").is_err());

        // Not a wasm file at all.
        assert!(imported_function_symbols(b"this is not wasm", "mc").is_err());
    }
}
