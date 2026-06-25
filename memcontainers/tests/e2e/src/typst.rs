//! typst resident-service e2e (the `paper` flavor): the `require("typst")` library + the `$ typst` CLI
//! over the warm compiler — inline + file compiles, structured diagnostics, the streamed PDF, lazy
//! activation, sequential clients, and warm-state survival across snapshot/restore. All driven through
//! the real shell on the real kernel (B6, no mocks): the kernel activates the typst service on first
//! svc_connect, it scans /usr/share/fonts once, and every caller reuses the warm fonts. Compiles are
//! HEAVY under wasmi (font load + layout + PDF realization), so the compile tests use
//! `run_for_output_heavy` (a raised tick ceiling); `--version`/`-h` stay on the normal budget.

use crate::{boot_paper, restore};

/// The library face: inline source → PDF bytes. A real PDF comes back (the `%PDF-` magic + the `%%EOF`
/// trailer) and is non-trivial — the warm service compiled it and streamed it back intact.
#[test]
fn typst_library_compiles_a_pdf() {
    let mut s = boot_paper();
    s.host
        .write_file(
            "/tmp/c.luau",
            br#"local typst = require("typst")
local pdf = typst.compile("= Hello\n\nA warm typst service.")
print(string.sub(pdf, 1, 5), string.find(pdf, "%%EOF", 1, true) ~= nil, #pdf > 1000)
"#,
        )
        .expect("write c.luau");
    assert_eq!(
        s.run_for_output_heavy("luau /tmp/c.luau"),
        "%PDF-\ttrue\ttrue\r\n"
    );
}

/// `compile_file` with an explicit project root keeps the main file's path relative to that root. A nested
/// main must be `/tmp/project/chapters/main.typ`, not flattened to `/tmp/project/main.typ`.
#[test]
fn typst_library_compile_file_respects_explicit_root() {
    let mut s = boot_paper();
    assert_eq!(s.run_for_output("mkdir -p /tmp/project/chapters"), "");
    s.host
        .write_file(
            "/tmp/project/chapters/main.typ",
            b"= Rooted\n\n#include \"body.typ\"",
        )
        .expect("write main.typ");
    s.host
        .write_file("/tmp/project/chapters/body.typ", b"Nested body.")
        .expect("write body.typ");
    s.host
        .write_file(
            "/tmp/rooted.luau",
            br#"local typst = require("typst")
local pdf = typst.compile_file("/tmp/project/chapters/main.typ", { root = "/tmp/project" })
print(string.sub(pdf, 1, 5), string.find(pdf, "%%EOF", 1, true) ~= nil)
"#,
        )
        .expect("write rooted.luau");
    assert_eq!(
        s.run_for_output_heavy("luau /tmp/rooted.luau"),
        "%PDF-\ttrue\r\n"
    );
}

/// The CLI face (SERVICES.md §3.3): `$ typst compile <in.typ> <out.pdf>` is a thin svc_connect/svc_call
/// client of the SAME warm service the library drives. Success is silent on the terminal (diagnostics go
/// to stderr only on error); the written PDF is real (magic + trailer + non-trivial size).
#[test]
fn typst_cli_compiles_a_file_to_pdf() {
    let mut s = boot_paper();
    s.host
        .write_file("/tmp/doc.typ", b"= Report\n\nGenerated entirely in the VM.")
        .expect("write doc.typ");
    assert_eq!(
        s.run_for_output_heavy("typst compile /tmp/doc.typ /tmp/doc.pdf"),
        ""
    );
    let pdf = s.host.read_file("/tmp/doc.pdf").expect("pdf written");
    assert!(
        pdf.starts_with(b"%PDF-"),
        "not a PDF: {:?}",
        &pdf[..pdf.len().min(8)]
    );
    assert!(pdf.windows(5).any(|w| w == b"%%EOF"), "no %%EOF trailer");
    assert!(pdf.len() > 1000, "PDF too small: {} bytes", pdf.len());
}

/// A compilation error fails the CLI (non-zero exit) and writes NO PDF. The located diagnostic
/// (`error: <file>:line:col: unknown variable: …`) goes to stderr — the harness routes a guest's stderr
/// to the host's, not the captured console — so here we assert the observable shell behavior: the `||`
/// fallback fires (non-zero exit) and no output file is created. (The diagnostic TEXT is asserted via the
/// library path in `typst_library_raises_on_compile_error`.)
#[test]
fn typst_reports_errors_and_writes_no_pdf() {
    let mut s = boot_paper();
    s.host
        .write_file("/tmp/bad.typ", b"= Title\n\n#nonexistent_variable")
        .expect("write bad.typ");
    // The compile exits non-zero → the `||` branch runs (the diagnostic itself rides stderr, uncaptured).
    assert_eq!(
        s.run_for_output_heavy("typst compile /tmp/bad.typ /tmp/bad.pdf || echo FAILED"),
        "FAILED\r\n"
    );
    assert!(
        s.host.read_file("/tmp/bad.pdf").is_err(),
        "no PDF should be written when the compile fails"
    );
}

/// The library raises a structured error on a compile failure (catchable with `pcall`): the diagnostic
/// message carries the typst error text, so a script can react to it rather than getting silent garbage.
#[test]
fn typst_library_raises_on_compile_error() {
    let mut s = boot_paper();
    s.host
        .write_file(
            "/tmp/e.luau",
            br##"local typst = require("typst")
local ok, err = pcall(typst.compile, "#nonexistent_variable")
print(tostring(ok), string.find(err, "unknown variable", 1, true) ~= nil)
"##,
        )
        .expect("write e.luau");
    assert_eq!(
        s.run_for_output_heavy("luau /tmp/e.luau"),
        "false\ttrue\r\n"
    );
}

/// Streamed PDF: a multi-page document's PDF exceeds the kernel's 64 KiB high-water, so the service
/// streams it in chunks — producing until the buffer fills (`respond` → EAGAIN), then resuming on the
/// `DrainReady` the kernel delivers as the client drains. The library reassembles it whole: a valid PDF
/// larger than the high-water, proving the chunked path round-trips the bytes intact.
#[test]
fn typst_streams_a_large_pdf() {
    let mut s = boot_paper();
    s.host
        .write_file(
            "/tmp/big.luau",
            br#"local typst = require("typst")
local parts = {}
for i = 1, 40 do parts[#parts + 1] = "= Section " .. i .. "\n\n#lorem(250)\n\n#pagebreak()" end
local pdf = typst.compile(table.concat(parts, "\n"))
print(string.sub(pdf, 1, 5), #pdf)
"#,
        )
        .expect("write big.luau");
    let out = s.run_for_output_heavy("luau /tmp/big.luau");
    assert!(out.starts_with("%PDF-\t"), "not a PDF: {out:?}");
    let size: usize = out
        .trim()
        .split('\t')
        .nth(1)
        .and_then(|n| n.parse().ok())
        .unwrap_or_else(|| panic!("could not parse the PDF size from {out:?}"));
    assert!(
        size > 65536,
        "the PDF must exceed the 64 KiB high-water to force the streamed (EAGAIN/DrainReady) path, got {size} bytes"
    );
}

/// `/svc` reflects LAZY activation: typst is absent until a client connects, then present — and it stays
/// (the warm service, with its fonts loaded, outlives the client that triggered it).
#[test]
fn typst_appears_in_svc_only_after_first_use() {
    let mut s = boot_paper();
    assert_eq!(
        s.run_for_output("ls /svc"),
        "",
        "typst is lazy — nothing is registered until it is used"
    );
    s.host
        .write_file(
            "/tmp/touch.luau",
            br#"local _ = require("typst").version()"#,
        )
        .expect("write touch.luau");
    let _ = s.run_for_output_heavy("luau /tmp/touch.luau");
    assert_eq!(
        s.run_for_output("ls /svc"),
        "typst\r\n",
        "now a live, listed service"
    );
}

/// `--version` and `-h` are standalone CLI fast paths — they report without activating the service, so
/// they stay on the normal budget. Version names the embedded compiler; help shows the usage.
#[test]
fn typst_version_and_help() {
    let mut s = boot_paper();
    assert!(
        s.run_for_output("typst --version").contains("0.14.2"),
        "version should name the embedded typst compiler"
    );
    assert!(
        s.run_for_output("typst -h")
            .contains("Usage: typst compile"),
        "help should show the usage line"
    );
    assert_eq!(
        s.run_for_output("typst compile /tmp/a.typ /tmp/a.pdf extra || echo BADARGS"),
        "BADARGS\r\n",
        "extra compile operands should be rejected as usage errors"
    );
}

/// Warm survival across snapshot/restore (SERVICES.md §1, §3.5): the typst service loads its fonts ONCE
/// into linear memory, so that warm state rides a VM snapshot. A document compiled before the snapshot
/// leaves the service warm AND quiescent (the call completed → it idles in svc_recv, so the snapshot
/// proceeds); after restoring into a FRESH VM, a second compile still produces a valid PDF — the warm
/// fonts came back with the snapshot, no re-scan, no cold start. A host process pool outside the snapshot
/// could not do this.
#[test]
fn typst_warm_state_survives_snapshot_and_restore() {
    let mut s = boot_paper();
    s.host
        .write_file(
            "/tmp/before.luau",
            br#"print(string.sub(require("typst").compile("= Before snapshot"), 1, 5))"#,
        )
        .expect("write before.luau");
    assert_eq!(s.run_for_output_heavy("luau /tmp/before.luau"), "%PDF-\r\n");

    let snap = s.host.snapshot().expect("snapshot"); // quiescent: the compile completed, the service idles
    let mut restored = restore(&snap);

    // The warm typst service (fonts + library) rode the snapshot — a compile in the fresh VM works at once.
    restored
        .host
        .write_file(
            "/tmp/after.luau",
            br#"local pdf = require("typst").compile("= After restore")
print(string.sub(pdf, 1, 5), string.find(pdf, "%%EOF", 1, true) ~= nil)
"#,
        )
        .expect("write after.luau");
    assert_eq!(
        restored.run_for_output_heavy("luau /tmp/after.luau"),
        "%PDF-\ttrue\r\n"
    );
}

/// The warm service serves sequential clients without state bleed: two compiles in one script each return
/// a valid PDF, and the two are DISTINCT — the per-request `World` + the streamed-response bookkeeping
/// reset cleanly between calls (a leak would corrupt the second compile or return the first's bytes again).
#[test]
fn typst_serves_sequential_compiles_cleanly() {
    let mut s = boot_paper();
    s.host
        .write_file(
            "/tmp/seq.luau",
            br#"local typst = require("typst")
local a = typst.compile("= First document")
local b = typst.compile("= Second\n\n#lorem(80)")
print(string.sub(a, 1, 5), string.sub(b, 1, 5), a ~= b)
"#,
        )
        .expect("write seq.luau");
    // Both are PDFs, and the second differs from the first → no cross-call bleed or stale reuse.
    assert_eq!(
        s.run_for_output_heavy("luau /tmp/seq.luau"),
        "%PDF-\t%PDF-\ttrue\r\n"
    );
}
