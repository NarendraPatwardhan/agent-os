//! loom — the Luau interpreter (/bin/luau) + type checker (/bin/luau-analyze) as one-binary domain
//! services, exercised on memcontainers/web's cdp-luau-verify.ts recipes verbatim: the
//! `batteries.luau` demo (require-driven json/hash/time + the string :split/:trim extensions, under
//! the fuel budget) and the typed_ok/typed_bad checks. Both run end-to-end on the real kernel — the
//! batteries through the embedded .luau libs + the Zig json/hash bindings, the type errors through the
//! full Luau Analysis engine (file:line:col diagnostics).

use host::MapHostCall;

use crate::{boot_loom, boot_loom_with_tools};

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

/// Bare `luau` reads + runs stdin (the non-interactive REPL) — `echo 'code' | luau`.
#[test]
fn luau_runs_stdin() {
    let mut s = boot_loom();
    assert_eq!(s.run_for_output("echo 'print(6*7)' | luau"), "42\r\n");
}

/// The kernel trap-unwind (mc_sys_pcall ⇒ __mc_pcall_run, restoring __stack_pointer) under
/// ADVERSARIAL nesting: a pcall inside a pcall, an error raised inside an xpcall HANDLER
/// (error-in-error), a value-returning pcall, and 100 consecutive pcall failures. Each must unwind
/// cleanly back to its catcher and leave the VM usable — codex #4 (the unwind path the kernel now
/// also gates by requiring the __mc_pcall_run/__stack_pointer export PAIR).
#[test]
fn luau_pcall_nested_and_error_in_error() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/pcall.luau",
            concat!(
                "local function deep() error(\"boom\") end\n",
                "local ok1 = pcall(function()\n",
                "  local ok2 = pcall(deep)\n",
                "  assert(not ok2, \"inner pcall should have failed\")\n",
                "  error(\"rethrow\")\n",
                "end)\n",
                "print(\"nested=\" .. tostring(ok1 == false))\n",
                "local ok3 = xpcall(function() error(\"orig\") end, function() error(\"handler_err\") end)\n",
                "print(\"errinerr=\" .. tostring(ok3 == false))\n",
                "local ok4, a, b = pcall(function() return 10, 20 end)\n",
                "print(\"vals=\" .. tostring(ok4 and a == 10 and b == 20))\n",
                "local n = 0\n",
                "for i = 1, 100 do if not pcall(function() error(i) end) then n = n + 1 end end\n",
                "print(\"stress=\" .. tostring(n == 100))\n",
                "print(2 + 2)\n", // VM still alive after 100 unwinds
            )
            .as_bytes(),
        )
        .expect("seed /demo/pcall.luau");
    let out = s.run_for_output("luau /demo/pcall.luau");
    assert!(out.contains("nested=true"), "nested pcall unwind:\n{out}");
    assert!(
        out.contains("errinerr=true"),
        "error raised inside xpcall handler:\n{out}"
    );
    assert!(out.contains("vals=true"), "value-returning pcall:\n{out}");
    assert!(
        out.contains("stress=true"),
        "100 consecutive pcall unwinds:\n{out}"
    );
    assert!(out.contains("4"), "VM dead after the unwind stress:\n{out}");
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
    assert!(
        !out.to_lowercase().contains("fuel"),
        "ran out of fuel — raise mc_budget:\n{out}"
    );
    assert!(
        out.contains(r#"{"hello":"world","n":42}"#),
        "json.encode:\n{out}"
    );
    assert!(out.contains("sha256 ="), "hash.sha256:\n{out}");
    assert!(
        out.contains("1970-01-01T00:00:00Z"),
        "time.format(0):\n{out}"
    );
    assert!(out.contains("trim   =\thi"), "string :trim:\n{out}");
    assert!(out.contains("split2 =\tb"), "string :split:\n{out}");
}

/// The `tools` battery is the programmable tool-plane face: search/describe are warm service calls,
/// and dotted-property invocation dispatches through the same `/svc/tools` broker.
#[test]
fn luau_tools_battery_discovers_and_calls() {
    let mut tools = MapHostCall::new();
    tools.register(
        "greet",
        Box::new(|args: &str| Ok(format!("{{\"message\":\"hello {args}\"}}").into_bytes())),
    );
    let mut s = boot_loom_with_tools(tools);
    s.host.mkdir("/etc/tools").ok();
    s.host
        .write_file(
            "/etc/tools/catalog.json",
            br#"{"tools":[{"address":"host.org.main.greet","description":"Greet someone",
              "binding":{"type":"host_call","name":"greet","args":"raw"}}]}"#,
        )
        .expect("seed tool catalog");
    s.host
        .write_file(
            "/demo/tools.luau",
            br#"local tools = require("tools")
local sys = require("sys")
local page = assert(tools.search("greet", { limit = 1 }))
print(page.items[1].address)
local rec = assert(tools.describe("host.org.main.greet"))
print(rec.binding.name)
local res = tools.host.org.main.greet("world")
print(res.ok, res.data.message)
local saved = tools.save("host.org.main.greet", "file", "/tmp/greet.json")
print(saved.ok, saved.data._tag, saved.data.path)
local fd = assert(sys.svc.connect("tools"))
local denied = assert(sys.svc.call(fd, '{"op":"catalog.apply","tools":[]}'))
assert(sys.svc.close(fd))
print(denied:match('"code":"([^"]+)"'))
"#,
        )
        .expect("seed tools.luau");
    assert_eq!(
        s.run_for_output("luau /demo/tools.luau"),
        "host.org.main.greet\r\ngreet\r\ntrue\thello world\r\ntrue\tToolFile\t/tmp/greet.json\r\npermission_denied\r\n"
    );
    assert_eq!(
        s.host.read_file("/tmp/greet.json").expect("saved tool file"),
        br#"{"message":"hello file"}"#
    );
}

/// json.decode round-trips: parse an object with a nested array + table, read fields back, and
/// re-encode — exercising the decode path (object/array/number/string/nesting) the batteries demo
/// (encode-only) didn't cover.
#[test]
fn json_decode_round_trips() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/jsonrt.luau",
            b"local json = require(\"json\")\nlocal d = assert(json.decode('{\"a\":1,\"items\":[10,20,30],\"nested\":{\"k\":\"v\"}}'))\nprint(d.a, d.items[2], d.nested.k, json.encode(d.items))\n",
        )
        .expect("seed");
    let out = s.run_for_output("luau /demo/jsonrt.luau");
    assert!(
        out.contains("1\t20\tv\t[10,20,30]"),
        "json.decode round-trip:\n{out}"
    );
}

/// deflate.decompress is bounded: with the exact size it round-trips; with a cap smaller than the
/// real output it returns a catchable error (a decompression bomb can't OOM the guest). The cap is
/// the regression codex flagged — the port had decompressed into an unbounded buffer.
#[test]
fn deflate_caps_decompression() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/defl.luau",
            b"local deflate = require(\"deflate\")\nlocal data = string.rep(\"ABCD\", 500)\nlocal packed = deflate.compress(data)\nlocal ok = deflate.decompress(packed, 2000)\nlocal bomb, err = deflate.decompress(packed, 10)\nprint(\"ok=\" .. tostring(ok == data) .. \" capped=\" .. tostring(bomb == nil and err ~= nil))\n",
        )
        .expect("seed");
    let out = s.run_for_output("luau /demo/defl.luau");
    assert!(out.contains("ok=true capped=true"), "deflate cap:\n{out}");
}

/// json.decode parses numbers per the JSON grammar and rejects what strtod would over-accept
/// (inf/nan/bad-exponent). Replaces the strtod-over-a-slice the review flagged.
#[test]
fn json_number_grammar() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/jsonnum.luau",
            b"local json = require(\"json\")\nlocal a = assert(json.decode(\"[1, -2.5, 30000, 0.0015, 1e3]\"))\nprint(\"nums=\" .. tostring(a[1]==1 and a[2]==-2.5 and a[3]==30000 and a[4]==0.0015 and a[5]==1000))\nprint(\"rej-exp=\" .. tostring((json.decode(\"[1e]\")) == nil))\nprint(\"rej-inf=\" .. tostring((json.decode(\"[inf]\")) == nil))\nprint(\"rej-nan=\" .. tostring((json.decode(\"[nan]\")) == nil))\n",
        )
        .expect("seed");
    let out = s.run_for_output("luau /demo/jsonnum.luau");
    assert!(out.contains("nums=true"), "json numbers:\n{out}");
    assert!(
        out.contains("rej-exp=true")
            && out.contains("rej-inf=true")
            && out.contains("rej-nan=true"),
        "json grammar:\n{out}"
    );
}

/// re — the Pike-VM regex battery (the 3rd native module): anchors, char classes + negation,
/// quantifiers (?, {m,n}), capture groups, alternation, the `i` flag, replace ($N templates), and
/// gmatch. The script asserts each case internally; the host checks the summary is all-true.
#[test]
fn re_regex_engine() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/re.luau",
            concat!(
                "local re = require(\"re\")\n",
                "local out = {}\n",
                "local function ck(n, c) out[#out+1] = n .. \"=\" .. tostring(c) end\n",
                "ck(\"anchor\", re.test(\"^a.c$\", \"abc\") and not re.test(\"^a.c$\", \"abXc\"))\n",
                "ck(\"class\", re.test(\"[a-z]+\", \"hello\") and not re.test(\"^[^0-9]+$\", \"123\"))\n",
                "ck(\"quest\", re.test(\"colou?r\", \"color\") and re.test(\"colou?r\", \"colour\"))\n",
                "ck(\"repeat\", re.test(\"^a{2,3}$\", \"aaa\") and not re.test(\"^a{2,3}$\", \"a\"))\n",
                "ck(\"alt\", re.test(\"cat|dog\", \"dog\"))\n",
                "ck(\"icase\", re.test(\"hello\", \"HELLO\", \"i\"))\n",
                "local m = re.match(\"(\\\\w+)@(\\\\w+)\", \"user@host\")\n",
                "ck(\"groups\", m ~= nil and m.groups[1] == \"user\" and m.groups[2] == \"host\")\n",
                "local r, c = re.compile(\"\\\\d+\"):replace(\"a1b22c333\", \"#\")\n",
                "ck(\"replace\", r == \"a#b#c#\" and c == 3)\n",
                "ck(\"template\", re.compile(\"(\\\\w+)=(\\\\w+)\"):replace(\"a=1 b=2\", \"$2:$1\") == \"1:a 2:b\")\n",
                "local g = {}\n",
                "for mm in re.compile(\"\\\\d+\"):gmatch(\"a1b22c333\") do g[#g+1] = mm.match end\n",
                "ck(\"gmatch\", table.concat(g, \",\") == \"1,22,333\")\n",
                "print(table.concat(out, \" \"))\n",
            )
            .as_bytes(),
        )
        .expect("seed");
    let out = s.run_for_output("luau /demo/re.luau");
    assert!(!out.contains("=false"), "a re case failed:\n{out}");
    assert!(out.contains("gmatch=true"), "re did not complete:\n{out}");
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
    assert_eq!(
        out, "readback=written-by-sys-fs\r\n",
        "sys.fs read-back:\n{out}"
    );
    assert_eq!(
        s.host
            .read_file("/tmp/sysout.txt")
            .expect("host reads the guest-written file"),
        b"written-by-sys-fs",
        "the guest's sys.fs.write must reach the kernel VFS",
    );
}

/// The real complex example: generate a genuine .xlsx with the embedded xlsx/opc/zip/xml libs +
/// the deflate binding, write it via sys.fs, and have the HOST verify it's a valid OOXML zip
/// (PK header + the part names). This is the document-generator path memcontainers/web showcases —
/// the proof the batteries are real, not a stub. (memcontainers/web app.ts REPORT_SAMPLE_LUA.)
#[test]
fn luau_generates_a_real_xlsx() {
    let mut s = boot_loom();
    s.host
        .write_file(
            "/demo/genxlsx.luau",
            concat!(
                "local xlsx = require(\"xlsx\")\n",
                "local wb = xlsx.new()\n",
                "local ws = wb:addWorksheet(\"Sales\")\n",
                "ws:setCell(\"A1\", \"Region\")\n",
                "ws:setCell(\"B1\", \"Revenue\")\n",
                "ws:setCell(\"A2\", \"EMEA\")\n",
                "ws:setCell(\"B2\", 1234)\n",
                "assert(sys.fs.write(\"/tmp/gen.xlsx\", wb:toBytes()))\n",
                "print(\"wrote xlsx\")\n",
            )
            .as_bytes(),
        )
        .expect("seed");
    let out = s.run_for_output("luau /demo/genxlsx.luau");
    assert!(out.contains("wrote xlsx"), "generation failed:\n{out}");
    let xlsx = s
        .host
        .read_file("/tmp/gen.xlsx")
        .expect("host reads the generated xlsx");
    assert!(
        xlsx.starts_with(b"PK\x03\x04"),
        "not a zip — head {:?}",
        &xlsx[..xlsx.len().min(8)]
    );
    let body = String::from_utf8_lossy(&xlsx);
    assert!(
        body.contains("[Content_Types].xml"),
        "missing the OOXML content-types part"
    );
    assert!(
        body.contains("xl/worksheets/"),
        "missing the worksheet part"
    );
    assert!(
        xlsx.len() > 1000,
        "xlsx suspiciously small: {} bytes",
        xlsx.len()
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
    let out = s.run_for_output("luau --check /demo/typed_ok.luau");
    assert!(
        !out.to_lowercase().contains("error"),
        "expected no diagnostics:\n{out}"
    );
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
    let out = s.run_for_output("luau --check /demo/typed_bad.luau");
    assert!(
        out.contains("/demo/typed_bad.luau:2:"),
        "expected a file:line:col diagnostic at line 2:\n{out}"
    );
    assert!(
        out.contains("'number'") && out.contains("'string'"),
        "expected the number-vs-string error:\n{out}"
    );
}

/// Pathological input degrades GRACEFULLY. The analyzer's only non-data failure modes are the
/// `-fno-exceptions` throw→mc_analysis_abort sites (resource/recursion/ICE limits, codex #5) — a
/// CLEAN exit(70) with a categorized message, never UB or a hung guest. An 8000-deep type+value is
/// the kind of adversarial input that probes those limits; the analyzer must either type-check it
/// (the constraint solver handles it lazily) or abort gracefully — and the kernel + shell must
/// survive either way. We prove survival: the deep check returns to a prompt, and a normal command
/// runs right after (the guest didn't wedge the VM, leak it, or trap uncaught).
#[test]
fn luau_analyze_survives_pathological_depth() {
    let mut s = boot_loom();
    let n = 8000;
    let mut src = String::from("--!strict\nlocal d: ");
    src.push_str(&"{x:".repeat(n));
    src.push_str("number");
    src.push_str(&"}".repeat(n));
    src.push_str(" = ");
    src.push_str(&"{x=".repeat(n));
    src.push_str("false"); // a leaf mismatch only deep traversal would find
    src.push_str(&"}".repeat(n));
    src.push_str("\nprint(d)\n");
    s.host
        .write_file("/demo/deep.luau", src.as_bytes())
        .expect("seed /demo/deep.luau");

    // No panic here ⇒ luau-analyze returned the shell to a prompt (no hang/crash). If it took an
    // abort path, the message is a categorized one; either way it's clean.
    let out = s.run_for_output("luau --check /demo/deep.luau");
    assert!(
        !out.contains("internal compiler error"),
        "deep input must not ICE:\n{out}"
    );

    // The kernel + shell survived the pathological guest: a normal command still works.
    assert_eq!(
        s.run_for_output("luau -e 'print(1+1)'"),
        "2\r\n",
        "VM dead after deep-input check"
    );
}
