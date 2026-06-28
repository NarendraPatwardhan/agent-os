//! loom — the Luau interpreter (/bin/luau) + type checker (/bin/luau-analyze) as one-binary domain
//! services, exercised on memcontainers/web's cdp-luau-verify.ts recipes verbatim: the
//! `batteries.luau` demo (require-driven json/hash/time + the string :split/:trim extensions, under
//! the fuel budget) and the typed_ok/typed_bad checks. Both run end-to-end on the real kernel — the
//! batteries through the embedded .luau libs + the Zig json/hash bindings, the type errors through the
//! full Luau Analysis engine (file:line:col diagnostics).

use host::{ConnectionRegistry, MapHostCall, RealNet};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::thread;
use std::time::Duration;

use crate::{boot_loom, boot_loom_with_net, boot_loom_with_net_and_tools, boot_loom_with_tools};

// ── smoke: the VM, the trap-unwind, and boot.

fn one_shot_http_server(body: &'static [u8]) -> (String, mpsc::Receiver<String>) {
    sequence_http_server(vec![body])
}

fn sequence_http_server(bodies: Vec<&'static [u8]>) -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind local upstream");
    let addr = listener.local_addr().expect("local upstream addr");
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        for body in bodies {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
            let raw = read_http_request(&mut stream);
            let _ = tx.send(String::from_utf8_lossy(&raw).into_owned());
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(head.as_bytes());
            let _ = stream.write_all(body);
        }
    });
    (format!("http://{addr}"), rx)
}

fn read_http_request(stream: &mut TcpStream) -> Vec<u8> {
    let mut raw = Vec::new();
    let mut buf = [0u8; 1024];
    let mut header_end = None;
    loop {
        match stream.read(&mut buf) {
            Ok(0) => return raw,
            Ok(n) => {
                raw.extend_from_slice(&buf[..n]);
                if header_end.is_none() {
                    header_end = raw.windows(4).position(|w| w == b"\r\n\r\n").map(|i| i + 4);
                }
                if let Some(end) = header_end {
                    let content_length = content_length(&raw[..end]);
                    if raw.len() >= end + content_length {
                        return raw;
                    }
                }
            }
            Err(_) => return raw,
        }
    }
}

fn content_length(head: &[u8]) -> usize {
    let text = String::from_utf8_lossy(head);
    for line in text.lines() {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        if name.eq_ignore_ascii_case("content-length") {
            return value.trim().parse().unwrap_or(0);
        }
    }
    0
}

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
        s.host
            .read_file("/tmp/greet.json")
            .expect("saved tool file"),
        br#"{"message":"hello file"}"#
    );
}

/// A lower-authority caller may discover `/svc/tools`, but `call` must not let the full-tier service
/// launder `mc_sys_host_call` authority on its behalf. The denied path is checked against direct
/// `sys.host.call`, which is the policy baseline.
#[test]
fn luau_tools_calls_require_caller_net_authority() {
    let called = Arc::new(AtomicBool::new(false));
    let marker = Arc::clone(&called);
    let mut tools = MapHostCall::new();
    tools.register(
        "greet",
        Box::new(move |_args: &str| {
            marker.store(true, Ordering::SeqCst);
            Ok(b"{\"message\":\"should not run\"}".to_vec())
        }),
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
            "/demo/low-tools.luau",
            br#"local sys = require("sys")
local tools = require("tools")
local page = assert(tools.search("greet", { limit = 1 }))
print("search", page.items[1].address)
local res = tools.call("host.org.main.greet", "world")
print("tool", tostring(res.ok), res.err.code)
local raw, host_err = sys.host.call("greet", "world")
print("host", tostring(raw), tostring(host_err))
"#,
        )
        .expect("seed low-authority tool script");
    s.host
        .write_file(
            "/demo/spawn-low-tools.luau",
            br#"local sys = require("sys")
local pid = assert(sys.proc.spawn({ argv = { "luau", "/demo/low-tools.luau" }, tier = "read-only" }))
local status = assert(sys.proc.wait(pid))
assert(status == 0, status)
"#,
        )
        .expect("seed parent tool script");
    assert_eq!(
        s.run_for_output("luau /demo/spawn-low-tools.luau"),
        "search\thost.org.main.greet\r\ntool\tfalse\tpermission_denied\r\nhost\tnil\tEPERM\r\n"
    );
    assert!(
        !called.load(Ordering::SeqCst),
        "low-authority /svc/tools call must not reach the host handler"
    );
}

/// WHY: `/svc/adapters` is the single resident compiler/invoker for adapter-backed tool formats. OpenAPI
/// is the first internal adapter: it compiles a spec to normal catalog records, `/svc/tools` loads those
/// records, and generated service bindings call back into `/svc/adapters invoke`. The call exits through
/// real `mc_http_request`; the host injects credentials from its registry, while the guest catalog/result
/// never contains the secret.
#[test]
fn adapters_compile_openapi_catalog_and_tools_call_it() {
    let (base_url, seen) = one_shot_http_server(br#"{"received":true}"#);
    let net = RealNet::new().with_connections(
        ConnectionRegistry::new()
            .with_bearer("petstore.org.main", "e2e-secret-token", [base_url.clone()])
            .expect("connection registry"),
    );
    let mut s = boot_loom_with_net(Box::new(net));
    s.host.mkdir("/etc/tools").ok();
    let spec = format!(
        r#"{{
              "openapi": "3.0.3",
              "info": {{ "title": "Pets", "version": "1.0.0" }},
              "servers": [{{ "url": "{base_url}/v1" }}],
              "paths": {{
                "/pets": {{
                  "get": {{
                    "operationId": "listPets",
                    "summary": "List pets",
                    "parameters": [
                      {{ "name": "limit", "in": "query", "schema": {{ "type": "integer" }} }}
                    ],
                    "responses": {{
                      "200": {{
                        "description": "ok",
                        "content": {{
                          "application/json": {{
                            "schema": {{
                              "type": "object",
                              "properties": {{ "received": {{ "type": "boolean" }} }}
                            }}
                          }}
                        }}
                      }}
                    }}
                  }}
                }},
                "/pets/{{petId}}": {{
                  "get": {{
                    "summary": "Show pet",
                    "parameters": [
                      {{ "name": "petId", "in": "path", "required": true, "schema": {{ "type": "string" }} }}
                    ],
                    "responses": {{ "200": {{ "description": "ok" }} }}
                  }}
                }}
              }},
              "components": {{
                "schemas": {{
                  "Pet": {{
                    "type": "object",
                    "required": ["id"],
                    "properties": {{
                      "id": {{ "type": "string" }},
                      "name": {{ "type": "string", "nullable": true }}
                    }}
                  }}
                }}
              }}
            }}"#
    );
    s.host
        .write_file("/tmp/petstore.openapi.json", spec.as_bytes())
        .expect("seed OpenAPI fixture");
    s.host
        .write_file(
            "/demo/openapi_compile.luau",
            br#"local sys = require("sys")
local json = require("json")
local source = assert(sys.fs.read("/tmp/petstore.openapi.json"))
local fd = assert(sys.svc.connect("adapters"))
local registryRaw = assert(sys.svc.call(fd, json.encode({ op = "registry.list" })))
local registry = assert(json.decode(registryRaw))
assert(registry.ok, registry.err and registry.err.message)
assert(#registry.data.items == 85, tostring(#registry.data.items))
local petstoreRaw = assert(sys.svc.call(fd, json.encode({ op = "registry.get", id = "petstore" })))
local petstore = assert(json.decode(petstoreRaw))
assert(petstore.ok and petstore.data.url == "https://petstore3.swagger.io/api/v3/openapi.json")
local raw = assert(sys.svc.call(fd, json.encode({
  op = "compile",
  format = "openapi",
  source_format = "json",
  source = source,
  integration = "petstore",
  owner = "org",
  connection = "main",
  auth = "bearer",
})))
assert(sys.svc.close(fd))
local res = assert(json.decode(raw))
assert(res.ok, res.err and res.err.message)
assert(#res.data.diagnostics == 0, json.encode(res.data.diagnostics))
assert(#res.data.tools == 2, tostring(#res.data.tools))
local text = json.encode({ tools = res.data.tools })
assert(not string.find(string.lower(text), "authorization", 1, true))
assert(not string.find(text, "e2e-secret-token", 1, true))
assert(sys.fs.write("/etc/tools/catalog.json", text))
print(res.data.tools[1].address)
print(res.data.tools[2].address)
"#,
        )
        .expect("seed adapter compile script");

    let compile = s.run_for_output("luau /demo/openapi_compile.luau");
    assert!(
        compile.contains("petstore.org.main.get.pets.petId")
            && compile.contains("petstore.org.main.listPets"),
        "OpenAPI compiler should emit both tools; got {compile:?}"
    );
    let catalog = s
        .host
        .read_file("/etc/tools/catalog.json")
        .expect("compiled catalog");
    let catalog = String::from_utf8_lossy(&catalog);
    assert!(
        catalog.contains("\"service\":\"adapters\"")
            && catalog.contains("\"adapter\":\"openapi\"")
            && catalog.contains("\"auth\":\"bearer\"")
            && !catalog.to_ascii_lowercase().contains("authorization")
            && !catalog.contains("e2e-secret-token"),
        "compiled catalog should carry only non-secret service bindings; got {catalog}"
    );

    let out = s.run_for_output("tools call petstore.org.main.listPets '{\"query\":{\"limit\":3}}'");
    assert!(
        out.contains("\"ok\":true")
            && out.contains("\"received\":true")
            && !out.to_ascii_lowercase().contains("authorization")
            && !out.contains("e2e-secret-token"),
        "generated OpenAPI tool should invoke through /svc/adapters and hide credentials; got {out:?}"
    );
    let request = seen.recv().expect("local upstream request");
    assert!(
        request.starts_with("GET /v1/pets?limit=3 "),
        "upstream request path mismatch: {request:?}"
    );
    assert!(
        request
            .to_ascii_lowercase()
            .contains("authorization: bearer e2e-secret-token"),
        "host did not inject bearer credential: {request:?}"
    );
    assert!(
        !request.to_ascii_lowercase().contains("x-mc-connection"),
        "host marker leaked onto the wire: {request:?}"
    );
}

/// WHY: connection refs are host credentials, not ambient bearer tokens. A CAP_NET guest can craft a
/// raw `mc_http_request` with `X-MC-Connection`; the host must still bind that credential to its
/// configured destination origin before any secret is attached.
#[test]
fn host_connection_credentials_are_origin_bound() {
    let (base_url, seen) = one_shot_http_server(br#"{"received":true}"#);
    let net = RealNet::new().with_connections(
        ConnectionRegistry::new()
            .with_bearer(
                "petstore.org.main",
                "e2e-secret-token",
                ["https://allowed.example"],
            )
            .expect("connection registry"),
    );
    let mut s = boot_loom_with_net(Box::new(net));

    let _ = s.run_for_output(&format!(
        "fetch -H 'X-MC-Connection: petstore.org.main' {base_url}/v1/pets"
    ));
    match seen.recv_timeout(Duration::from_millis(200)) {
        Err(mpsc::RecvTimeoutError::Timeout) => {}
        other => panic!("origin-mismatched credential request reached upstream: {other:?}"),
    }
}

/// WHY: Microsoft Graph is not a separate runtime. `/svc/adapters` should trim the large Graph OpenAPI
/// source by registry workload presets, emit ordinary service-backed tool records, and let the host
/// splice OAuth credentials only at `mc_http_request` egress.
#[test]
fn adapters_compile_microsoft_graph_preset_and_tools_call_it() {
    let (base_url, seen) = one_shot_http_server(br#"{"mail":true}"#);
    let net = RealNet::new().with_connections(
        ConnectionRegistry::new()
            .with_bearer("microsoft.org.work", "ms-secret-token", [base_url.clone()])
            .expect("connection registry"),
    );
    let mut s = boot_loom_with_net(Box::new(net));
    s.host.mkdir("/etc/tools").ok();
    let spec = format!(
        r#"{{
              "openapi": "3.0.3",
              "info": {{ "title": "Microsoft Graph", "version": "v1.0" }},
              "servers": [{{ "url": "{base_url}/v1.0" }}],
              "paths": {{
                "/me/messages": {{
                  "get": {{
                    "operationId": "listMessages",
                    "description": "List signed-in user's messages.",
                    "responses": {{
                      "200": {{
                        "description": "ok",
                        "content": {{
                          "application/json": {{
                            "schema": {{
                              "type": "object",
                              "properties": {{ "mail": {{ "type": "boolean" }} }}
                            }}
                          }}
                        }}
                      }}
                    }}
                  }}
                }},
                "/me/events": {{
                  "get": {{
                    "operationId": "listEvents",
                    "description": "List signed-in user's events.",
                    "responses": {{ "200": {{ "description": "ok" }} }}
                  }}
                }}
              }}
            }}"#
    );
    s.host
        .write_file("/tmp/graph.openapi.json", spec.as_bytes())
        .expect("seed Microsoft Graph fixture");
    s.host
        .write_file(
            "/demo/graph_compile.luau",
            br#"local sys = require("sys")
local json = require("json")
local source = assert(sys.fs.read("/tmp/graph.openapi.json"))
local fd = assert(sys.svc.connect("adapters"))
local raw = assert(sys.svc.call(fd, json.encode({
  op = "compile",
  format = "microsoft-graph",
  source_format = "json",
  source = source,
  integration = "microsoft",
  owner = "org",
  connection = "work",
  auth = "bearer",
  preset_ids = { "mail" },
})))
assert(sys.svc.close(fd))
local res = assert(json.decode(raw))
assert(res.ok, res.err and res.err.message)
assert(#res.data.diagnostics == 0, json.encode(res.data.diagnostics))
assert(#res.data.tools == 1, tostring(#res.data.tools))
local text = json.encode({ tools = res.data.tools })
assert(string.find(text, "microsoft%-graph"))
assert(not string.find(text, "listEvents", 1, true))
assert(not string.find(string.lower(text), "authorization", 1, true))
assert(not string.find(text, "ms-secret-token", 1, true))
assert(sys.fs.write("/etc/tools/catalog.json", text))
print(res.data.tools[1].address)
"#,
        )
        .expect("seed Microsoft Graph compile script");

    assert_eq!(
        s.run_for_output("luau /demo/graph_compile.luau"),
        "microsoft.org.work.listMessages\r\n"
    );
    let out = s.run_for_output("tools call microsoft.org.work.listMessages '{}'");
    assert!(
        out.contains("\"ok\":true")
            && out.contains("\"mail\":true")
            && !out.to_ascii_lowercase().contains("authorization")
            && !out.contains("ms-secret-token"),
        "generated Microsoft Graph tool should hide credentials; got {out:?}"
    );
    let request = seen.recv().expect("local Microsoft Graph request");
    assert!(
        request.starts_with("GET /v1.0/me/messages "),
        "Graph request path mismatch: {request:?}"
    );
    assert!(
        request
            .to_ascii_lowercase()
            .contains("authorization: bearer ms-secret-token"),
        "host did not inject Microsoft Graph bearer credential: {request:?}"
    );
    assert!(
        !request.to_ascii_lowercase().contains("x-mc-connection"),
        "host marker leaked onto the wire: {request:?}"
    );
}

/// WHY: Google Discovery documents are a different public description format, but not a different
/// capability boundary. `/svc/adapters` normalizes Discovery into OpenAPI-shaped operations and the
/// generated tool still relies on host-side credential injection.
#[test]
fn adapters_compile_google_discovery_and_tools_call_it() {
    let (base_url, seen) = one_shot_http_server(br#"{"messages":["hello"]}"#);
    let net = RealNet::new().with_connections(
        ConnectionRegistry::new()
            .with_bearer("gmail.org.work", "google-secret-token", [base_url.clone()])
            .expect("connection registry"),
    );
    let mut s = boot_loom_with_net(Box::new(net));
    s.host.mkdir("/etc/tools").ok();
    let discovery = format!(
        r#"{{
              "kind": "discovery#restDescription",
              "name": "gmail",
              "version": "v1",
              "title": "Gmail API",
              "baseUrl": "{base_url}/",
              "schemas": {{
                "ListMessagesResponse": {{
                  "id": "ListMessagesResponse",
                  "type": "object",
                  "properties": {{
                    "messages": {{
                      "type": "array",
                      "items": {{ "type": "string" }}
                    }}
                  }}
                }}
              }},
              "resources": {{
                "users": {{
                  "resources": {{
                    "messages": {{
                      "methods": {{
                        "list": {{
                          "id": "gmail.users.messages.list",
                          "path": "gmail/v1/users/{{userId}}/messages",
                          "httpMethod": "GET",
                          "description": "Lists the messages in the user's mailbox.",
                          "parameters": {{
                            "userId": {{
                              "type": "string",
                              "required": true,
                              "location": "path"
                            }},
                            "maxResults": {{
                              "type": "integer",
                              "format": "uint32",
                              "location": "query"
                            }}
                          }},
                          "response": {{ "$ref": "ListMessagesResponse" }}
                        }}
                      }}
                    }}
                  }}
                }}
              }}
            }}"#
    );
    s.host
        .write_file("/tmp/gmail.discovery.json", discovery.as_bytes())
        .expect("seed Google Discovery fixture");
    s.host
        .write_file(
            "/demo/google_compile.luau",
            br#"local sys = require("sys")
local json = require("json")
local source = assert(sys.fs.read("/tmp/gmail.discovery.json"))
local fd = assert(sys.svc.connect("adapters"))
local raw = assert(sys.svc.call(fd, json.encode({
  op = "compile",
  format = "google-discovery",
  source_format = "json",
  source = source,
  integration = "gmail",
  owner = "org",
  connection = "work",
  auth = "bearer",
})))
assert(sys.svc.close(fd))
local res = assert(json.decode(raw))
assert(res.ok, res.err and res.err.message)
assert(#res.data.diagnostics == 0, json.encode(res.data.diagnostics))
assert(#res.data.tools == 1, tostring(#res.data.tools))
local text = json.encode({ tools = res.data.tools })
assert(string.find(text, "google%-discovery"))
assert(not string.find(string.lower(text), "authorization", 1, true))
assert(not string.find(text, "google-secret-token", 1, true))
assert(sys.fs.write("/etc/tools/catalog.json", text))
print(res.data.tools[1].address)
"#,
        )
        .expect("seed Google Discovery compile script");

    assert_eq!(
        s.run_for_output("luau /demo/google_compile.luau"),
        "gmail.org.work.gmail-users-messages-list\r\n"
    );
    let out = s.run_for_output(
        "tools call gmail.org.work.gmail-users-messages-list '{\"path\":{\"userId\":\"me\"},\"query\":{\"maxResults\":2}}'",
    );
    assert!(
        out.contains("\"ok\":true")
            && out.contains("\"messages\":[\"hello\"]")
            && !out.to_ascii_lowercase().contains("authorization")
            && !out.contains("google-secret-token"),
        "generated Google Discovery tool should hide credentials; got {out:?}"
    );
    let request = seen.recv().expect("local Google request");
    assert!(
        request.starts_with("GET /gmail/v1/users/me/messages?maxResults=2 "),
        "Google request path mismatch: {request:?}"
    );
    assert!(
        request
            .to_ascii_lowercase()
            .contains("authorization: bearer google-secret-token"),
        "host did not inject Google bearer credential: {request:?}"
    );
    assert!(
        !request.to_ascii_lowercase().contains("x-mc-connection"),
        "host marker leaked onto the wire: {request:?}"
    );
}

/// WHY: GraphQL joins the same `/svc/adapters` plane after Graph/Google: introspection produces
/// ordinary catalog records, queries invoke through HTTP POST, and mutations are annotated for the
/// `/svc/tools` approval path before network dispatch.
#[test]
fn adapters_compile_graphql_and_tools_call_it() {
    let introspection = br#"{"data":{"__schema":{
      "queryType":{"name":"Query"},
      "mutationType":{"name":"Mutation"},
      "types":[
        {"kind":"OBJECT","name":"Query","fields":[
          {"name":"viewer","description":"Viewer by id","args":[
            {"name":"id","description":"User id","type":{"kind":"NON_NULL","ofType":{"kind":"SCALAR","name":"ID"}}}
          ]}
        ]},
        {"kind":"OBJECT","name":"Mutation","fields":[
          {"name":"updateName","description":"Update display name","args":[
            {"name":"name","type":{"kind":"NON_NULL","ofType":{"kind":"SCALAR","name":"String"}}}
          ]}
        ]}
      ]}}}"#;
    let (base_url, seen) = sequence_http_server(vec![
        introspection,
        br#"{"data":{"viewer":{"login":"ada"}}}"#,
        br#"{"data":{"updateName":{"ok":true}}}"#,
    ]);
    let approvals = Arc::new(Mutex::new(0usize));
    let mut host_calls = MapHostCall::new();
    {
        let approvals = Arc::clone(&approvals);
        host_calls.register_raw(
            "/svc/tools/permission",
            Box::new(move |body: &[u8]| {
                let prompt = String::from_utf8_lossy(body);
                assert!(prompt.contains("\"kind\":\"tool_approval\""));
                assert!(prompt.contains("\"approvalDescription\":\"mutation updateName\""));
                *approvals.lock().unwrap() += 1;
                Ok(br#"{"allow":true}"#.to_vec())
            }),
        );
    }
    let mut s = boot_loom_with_net_and_tools(Box::new(RealNet::new()), host_calls);
    s.host.mkdir("/etc/tools").ok();
    let endpoint = format!("{base_url}/graphql");
    let script = format!(
        r#"local sys = require("sys")
local json = require("json")
local fd = assert(sys.svc.connect("adapters"))
local raw = assert(sys.svc.call(fd, json.encode({{
  op = "compile",
  format = "graphql",
  endpoint = "{endpoint}",
  integration = "gql",
  owner = "org",
  connection = "main",
  auth = "none",
}})))
assert(sys.svc.close(fd))
local res = assert(json.decode(raw))
assert(res.ok, res.err and res.err.message)
assert(#res.data.diagnostics == 0, json.encode(res.data.diagnostics))
assert(#res.data.tools == 2, tostring(#res.data.tools))
local text = json.encode({{ tools = res.data.tools }})
assert(string.find(text, "requires_approval", 1, true))
assert(sys.fs.write("/etc/tools/catalog.json", text))
print(res.data.tools[1].address)
print(res.data.tools[2].address)
"#
    );
    s.host
        .write_file("/demo/graphql_compile.luau", script.as_bytes())
        .expect("seed GraphQL compile script");

    let compile = s.run_for_output("luau /demo/graphql_compile.luau");
    assert!(
        compile.contains("gql.org.main.query.viewer")
            && compile.contains("gql.org.main.mutation.updateName"),
        "GraphQL compiler should emit query and mutation tools; got {compile:?}"
    );
    let query = s.run_for_output("tools call gql.org.main.query.viewer '{\"id\":\"ada\"}'");
    assert!(
        query.contains("\"ok\":true") && query.contains("\"login\":\"ada\""),
        "GraphQL query tool should return upstream JSON; got {query:?}"
    );
    let mutation = s.run_for_output("tools call gql.org.main.mutation.updateName '{\"name\":\"Ada\"}'");
    assert!(
        mutation.contains("\"ok\":true") && mutation.contains("\"updateName\":{\"ok\":true}"),
        "GraphQL mutation tool should run after approval; got {mutation:?}"
    );
    assert_eq!(*approvals.lock().unwrap(), 1);

    let introspection_req = seen.recv().expect("GraphQL introspection request");
    assert!(introspection_req.contains("__schema"));
    let query_req = seen.recv().expect("GraphQL query request");
    assert!(query_req.contains("query_viewer") && query_req.contains("\"id\":\"ada\""));
    let mutation_req = seen.recv().expect("GraphQL mutation request");
    assert!(mutation_req.contains("mutation_updateName") && mutation_req.contains("\"name\":\"Ada\""));
}

/// WHY: remote MCP is additive to the same adapter service: discovery performs the MCP HTTP handshake
/// and `tools/list`, catalog records keep MCP names/hints, and destructive MCP tools run only after
/// `/svc/tools` approval.
#[test]
fn adapters_compile_remote_mcp_and_tools_call_it() {
    let (base_url, seen) = sequence_http_server(vec![
        br#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{}}}"#,
        br#"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"repo.delete","description":"Delete docs","inputSchema":{"type":"object","required":["repo"],"properties":{"repo":{"type":"string"}}},"annotations":{"title":"Delete docs","destructiveHint":true}}]}}"#,
        br#"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"deleted"}]}}"#,
    ]);
    let approvals = Arc::new(Mutex::new(0usize));
    let mut host_calls = MapHostCall::new();
    {
        let approvals = Arc::clone(&approvals);
        host_calls.register_raw(
            "/svc/tools/permission",
            Box::new(move |body: &[u8]| {
                let prompt = String::from_utf8_lossy(body);
                assert!(prompt.contains("\"approvalDescription\":\"Delete docs\""));
                *approvals.lock().unwrap() += 1;
                Ok(br#"{"allow":true}"#.to_vec())
            }),
        );
    }
    let mut s = boot_loom_with_net_and_tools(Box::new(RealNet::new()), host_calls);
    s.host.mkdir("/etc/tools").ok();
    let endpoint = format!("{base_url}/mcp");
    let script = format!(
        r#"local sys = require("sys")
local json = require("json")
local fd = assert(sys.svc.connect("adapters"))
local raw = assert(sys.svc.call(fd, json.encode({{
  op = "compile",
  format = "mcp-remote",
  endpoint = "{endpoint}",
  integration = "deepwiki",
  owner = "org",
  connection = "main",
  auth = "none",
}})))
assert(sys.svc.close(fd))
local res = assert(json.decode(raw))
assert(res.ok, res.err and res.err.message)
assert(#res.data.diagnostics == 0, json.encode(res.data.diagnostics))
assert(#res.data.tools == 1, tostring(#res.data.tools))
local text = json.encode({{ tools = res.data.tools }})
assert(string.find(text, "repo.delete", 1, true))
assert(string.find(text, "requires_approval", 1, true))
assert(sys.fs.write("/etc/tools/catalog.json", text))
print(res.data.tools[1].address)
"#
    );
    s.host
        .write_file("/demo/mcp_compile.luau", script.as_bytes())
        .expect("seed MCP compile script");

    assert_eq!(
        s.run_for_output("luau /demo/mcp_compile.luau"),
        "deepwiki.org.main.repo-delete\r\n"
    );
    let out = s.run_for_output("tools call deepwiki.org.main.repo-delete '{\"repo\":\"acme/docs\"}'");
    assert!(
        out.contains("\"ok\":true") && out.contains("\"text\":\"deleted\""),
        "remote MCP tool should return tools/call result; got {out:?}"
    );
    assert_eq!(*approvals.lock().unwrap(), 1);

    let init = seen.recv().expect("MCP initialize request");
    assert!(init.contains("\"method\":\"initialize\""));
    let list = seen.recv().expect("MCP tools/list request");
    assert!(list.contains("\"method\":\"tools/list\""));
    let call = seen.recv().expect("MCP tools/call request");
    assert!(call.contains("\"method\":\"tools/call\""));
    assert!(call.contains("\"name\":\"repo.delete\"") && call.contains("\"repo\":\"acme/docs\""));
}

/// WHY: `/svc/adapters` is full-tier because invocation reaches host egress, so it must not become a
/// second authority-laundering path around `/svc/tools`. A read-only caller may connect and compile,
/// but direct `invoke` is denied before the adapter reaches the host network capability.
#[test]
fn adapters_invoke_requires_caller_net_authority() {
    let (base_url, seen) = one_shot_http_server(br#"{"should":"not run"}"#);
    let mut s = boot_loom_with_net(Box::new(RealNet::new()));
    let script = format!(
        r#"local sys = require("sys")
local json = require("json")
local fd = assert(sys.svc.connect("adapters"))
local raw = assert(sys.svc.call(fd, json.encode({{
  op = "invoke",
  adapter = "openapi",
  binding = {{
    method = "GET",
    url_template = "{base_url}/v1/pets",
    parameters = {{}},
    connection_ref = {{ auth = "none" }},
  }},
  args = {{}},
}})))
assert(sys.svc.close(fd))
local res = assert(json.decode(raw))
print(tostring(res.ok), res.err.code)
"#
    );
    s.host
        .write_file("/demo/low-adapters.luau", script.as_bytes())
        .expect("seed low-authority adapters script");
    s.host
        .write_file(
            "/demo/spawn-low-adapters.luau",
            br#"local sys = require("sys")
local pid = assert(sys.proc.spawn({ argv = { "luau", "/demo/low-adapters.luau" }, tier = "read-only" }))
local status = assert(sys.proc.wait(pid))
assert(status == 0, status)
"#,
        )
        .expect("seed low-authority adapters parent");

    assert_eq!(
        s.run_for_output("luau /demo/spawn-low-adapters.luau"),
        "false\tpermission_denied\r\n"
    );
    assert!(
        seen.recv_timeout(Duration::from_millis(100)).is_err(),
        "low-authority /svc/adapters invoke must not reach host network egress"
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
