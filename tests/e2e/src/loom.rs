//! loom — the Luau interpreter (/bin/luau) + type checker (/bin/luau-analyze) as one-binary domain
//! services (§16.5), exercised on memcontainers/web's cdp-luau-verify.ts recipes verbatim: the
//! `batteries.luau` demo (require-driven json/hash/time + the string :split/:trim extensions, under
//! the fuel budget) and the typed_ok/typed_bad checks. Both run end-to-end on the real kernel — the
//! batteries through the embedded .luau libs + the Zig json/hash bindings, the type errors through the
//! full Luau Analysis engine (file:line:col diagnostics).

use crate::boot_loom;

// ── smoke: the VM, the trap-unwind, and boot.

/// luau evaluates a `-e` one-liner: parse + compile + run bytecode, the script under lua_pcall so the
/// kernel trap-unwind (mc_sys_pcall ⇒ __mc_pcall_run) is exercised.
#[test]
fn luau_evaluates_arithmetic() {
    let mut s = boot_loom();
    assert_eq!(s.run_for_output("luau -e 'print(1+1)'"), "2\r\n");
}

/// luau --version: the no-VM path (arg parse + one write), confirming the binary loads, mc_tier/
/// mc_budget parse, and argv reaches the guest through the wasi→mc adapter.
#[test]
fn luau_reports_version() {
    let mut s = boot_loom();
    assert!(s.run_for_output("luau --version").contains("Luau 0.725"));
}

// ── the REAL bar (memcontainers/web cdp-luau-verify.ts) — verbatim fixtures.

/// The batteries demo: require("json"/"hash"/"time") + the string :split/:trim extensions, under the
/// mc_budget fuel cap. The exact script + assertions from cdp-luau-verify.ts.
#[test]
fn luau_runs_the_batteries_demo() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/batteries.luau",
            concat!(
                "local json = require(\"json\")\n",
                "local hash = require(\"hash\")\n",
                "local time = require(\"time\")\n",
                "local parts = (\"a,b,c\"):split(\",\")\n",
                "print(json.encode({ hello = \"world\", n = 42 }))\n",
                "print(\"sha256 =\", hash.sha256(\"memcontainers\"))\n",
                "print(\"epoch  =\", time.format(0))\n",
                "print(\"trim   =\", (\"  hi  \"):trim())\n",
                "print(\"split2 =\", parts[2])\n",
            )
            .as_bytes(),
        )
        .expect("seed /demo/batteries.luau");
    let out = s.run_for_output("luau /demo/batteries.luau");
    assert!(!out.to_lowercase().contains("fuel"), "ran out of fuel — raise mc_budget:\n{out}");
    assert!(out.contains(r#"{"hello":"world","n":42}"#), "json.encode:\n{out}");
    assert!(out.contains("sha256 ="), "hash.sha256:\n{out}");
    assert!(out.contains("1970-01-01T00:00:00Z"), "time.format(0):\n{out}");
    assert!(out.contains("trim   =\thi"), "string :trim:\n{out}");
    assert!(out.contains("split2 =\tb"), "string :split:\n{out}");
}

/// sys.fs is the real syscall surface: a guest writes a file via sys.fs.write + reads it back via
/// sys.fs.read, and the HOST sees the same bytes in the kernel VFS — proving sys.zig drives mc_sys_*
/// (open/write/read/close) for real, not a stub.
#[test]
fn sys_fs_writes_a_file_the_host_can_read() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/syswrite.luau",
            b"assert(sys.fs.write(\"/tmp/sysout.txt\", \"written-by-sys-fs\"))\nlocal c = assert(sys.fs.read(\"/tmp/sysout.txt\"))\nprint(\"readback=\" .. c)\n",
        )
        .expect("seed");
    let out = s.run_for_output("luau /demo/syswrite.luau");
    assert_eq!(out, "readback=written-by-sys-fs\r\n", "sys.fs read-back:\n{out}");
    assert_eq!(
        s.host.read_file("/tmp/sysout.txt").expect("host reads the guest-written file"),
        b"written-by-sys-fs",
        "the guest's sys.fs.write must reach the kernel VFS",
    );
}

/// Well-typed strict module: luau-analyze reports nothing.
#[test]
fn luau_check_passes_clean() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/typed_ok.luau",
            b"--!strict\nlocal function add(a: number, b: number): number\n    return a + b\nend\nprint(add(2, 3))\n",
        )
        .expect("seed /demo/typed_ok.luau");
    let out = s.run_for_output("luau-analyze /demo/typed_ok.luau");
    assert!(!out.to_lowercase().contains("error"), "expected no diagnostics:\n{out}");
}

/// A strict type error: luau-analyze reports it as file:line:col (here line 2 — the bad assignment).
#[test]
fn luau_check_reports_type_error() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/typed_bad.luau",
            b"--!strict\nlocal x: number = \"not a number\"\nprint(x)\n",
        )
        .expect("seed /demo/typed_bad.luau");
    let out = s.run_for_output("luau-analyze /demo/typed_bad.luau");
    assert!(out.contains("/demo/typed_bad.luau:2:"), "expected a file:line:col diagnostic at line 2:\n{out}");
    assert!(out.contains("'number'") && out.contains("'string'"), "expected the number-vs-string error:\n{out}");
}
