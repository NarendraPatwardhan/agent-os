//! System programs — the non-coreutils binaries that aren't part of the mcbox multicall: `tools`
//! (the `/svc/tools` broker over `mc_host_call`) and `pkgfsd` (the `/pkg` serve daemon). These
//! exercise host_call + resident-service + serve machinery, not just a tool's output.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use host::MapHostCall;
use serde_json::{json, Map, Value};

use crate::{boot_posix, boot_posix_with_persist, boot_posix_with_tools, Session};

fn seed_catalog(s: &mut Session, json: &str) {
    let doc: Value = serde_json::from_str(json).expect("catalog fixture JSON");
    let tools = doc
        .get("tools")
        .and_then(Value::as_array)
        .expect("catalog fixture tools");
    s.host.mkdir("/etc/tools").ok();
    s.host.mkdir("/etc/tools/catalog").ok();
    s.host.mkdir("/etc/tools/catalog/records").ok();
    let mut entries = Vec::new();
    for record in tools {
        let obj = record.as_object().expect("tool record object");
        let address = obj
            .get("address")
            .and_then(Value::as_str)
            .expect("tool address");
        let integration = obj
            .get("integration")
            .and_then(Value::as_str)
            .unwrap_or_else(|| address.split('.').next().unwrap_or("host"));
        let description = obj.get("description").and_then(Value::as_str).unwrap_or("");
        let mut shard = Map::new();
        for key in ["input_schema", "output_schema", "annotations", "binding"] {
            if let Some(value) = obj.get(key) {
                shard.insert(key.to_string(), value.clone());
            }
        }
        let shard = serde_json::to_vec(&Value::Object(shard)).expect("encode shard");
        let sha = pkgcore::sha256_hex(&shard);
        s.host
            .write_file(&format!("/etc/tools/catalog/records/{sha}"), &shard)
            .expect("seed tool shard");
        entries.push(json!({
            "address": address,
            "integration": integration,
            "description": description,
            "sha": sha,
        }));
    }
    entries.sort_by(|a, b| {
        a.get("address")
            .and_then(Value::as_str)
            .cmp(&b.get("address").and_then(Value::as_str))
    });
    let index = serde_json::to_vec(&json!({
        "generation": 0,
        "tools": entries,
    }))
    .expect("encode index");
    let digest = pkgcore::sha256_hex(&index);
    s.host
        .write_file("/etc/tools/catalog/index.json", &index)
        .expect("seed catalog index");
    s.host
        .write_file(
            "/etc/tools/catalog/index.sha256",
            format!("{digest}\n").as_bytes(),
        )
        .expect("seed catalog digest");
}

/// WHY: `/svc/tools` is the guest→host tool broker — it discovers an addressed catalog record, validates
/// args, packs the binding as `name\0args`, fires `mc_host_call`, and wraps the host handler's result in
/// the branchable envelope. GUARANTEES: with a tool registered on the host (`MapHostCall`), `tools call`
/// reaches the handler WITH the args and prints a JSON envelope over the terminal (ONLCR → CRLF).
#[test]
fn tools_calls_a_registered_host_tool() {
    let mut tools = MapHostCall::new();
    tools.register(
        "greet",
        Box::new(|args: &str| Ok(format!("hello {args}\n").into_bytes())),
    );
    let mut s = boot_posix_with_tools(tools);
    seed_catalog(
        &mut s,
        r#"{"tools":[{"address":"host.org.main.greet","description":"Greet someone",
          "binding":{"type":"host_call","name":"greet","args":"raw"}}]}"#,
    );
    assert_eq!(
        s.run_for_output("tools call host.org.main.greet world"),
        "{\"ok\":true,\"data\":\"hello world\\n\"}\r\n"
    );
}

/// WHY: default-deny at the catalog layer — an unknown address must be REFUSED, not silently fall
/// through. GUARANTEES: the broker returns a structured `tool_not_found` error envelope.
#[test]
fn tools_refuses_an_unregistered_tool() {
    let tools = MapHostCall::new(); // empty registry → every call refused
    let mut s = boot_posix_with_tools(tools);
    seed_catalog(&mut s, r#"{"tools":[]}"#);
    assert_eq!(
        s.run_for_output("tools call host.org.main.nope {}"),
        "{\"ok\":false,\"err\":{\"code\":\"tool_not_found\",\"message\":\"no tool with that address\"}}\r\n"
    );
}

/// WHY: catalog discovery is the new first-class surface. GUARANTEES: `search` deterministically ranks a
/// matching addressed tool, and `describe` returns the same schema-bearing catalog record.
#[test]
fn tools_searches_and_describes_the_catalog() {
    let mut s = boot_posix_with_tools(MapHostCall::new());
    seed_catalog(
        &mut s,
        r#"{"tools":[
          {"address":"github.org.main.createIssue","description":"Create a GitHub issue",
           "input_schema":{"type":"object","required":["repo","title"],"properties":{"repo":{"type":"string"},"title":{"type":"string"}}},
           "binding":{"type":"host_call","name":"github.issue","args":"json"}},
          {"address":"sentry.org.main.listIssues","description":"List Sentry issues",
           "binding":{"type":"host_call","name":"sentry.list","args":"json"}}
        ]}"#,
    );
    let search = s.run_for_output("tools search create github issue --limit 1");
    assert!(
        search.contains("\"address\":\"github.org.main.createIssue\""),
        "search should surface the createIssue tool; got {search:?}"
    );
    let describe = s.run_for_output("tools describe github.org.main.createIssue");
    assert!(
        describe.contains("\"input_schema\"") && describe.contains("\"repo\""),
        "describe should return schemas; got {describe:?}"
    );
}

/// WHY: `/tools` is the Plan-9 file face of the catalog, globally mounted by base rather than hidden in
/// one service task's namespace. GUARANTEES: ordinary file tools can progressively browse the same
/// addressed records that `/svc/tools describe` returns, with no egress and no Luau dependency.
#[test]
fn tools_catalog_is_browsable_as_files() {
    let mut s = boot_posix_with_tools(MapHostCall::new());
    seed_catalog(
        &mut s,
        r#"{"tools":[
          {"address":"github.org.main.createIssue","description":"Create a GitHub issue",
           "input_schema":{"type":"object","required":["repo","title"],"properties":{"repo":{"type":"string"},"title":{"type":"string"}}},
           "binding":{"type":"host_call","name":"github.issue","args":"json"}},
          {"address":"github.org.main.listPullRequests","description":"List pull requests",
           "binding":{"type":"host_call","name":"github.prs","args":"json"}},
          {"address":"sentry.org.main.listIssues","description":"List Sentry issues",
           "binding":{"type":"host_call","name":"sentry.list","args":"json"}}
        ]}"#,
    );

    assert_eq!(s.run_for_output("ls /tools"), "github/\r\nsentry/\r\n");
    assert_eq!(
        s.run_for_output("ls /tools/github/org/main"),
        "createIssue\r\nlistPullRequests\r\n"
    );
    let describe = s.run_for_output("cat /tools/github/org/main/createIssue");
    assert!(
        describe.contains("\"address\":\"github.org.main.createIssue\"")
            && describe.contains("\"input_schema\"")
            && describe.contains("\"binding\""),
        "cat /tools/... should return the catalog record; got {describe:?}"
    );

    seed_catalog(
        &mut s,
        r#"{"tools":[
          {"address":"linear.org.main.createIssue","description":"Create a Linear issue",
           "binding":{"type":"host_call","name":"linear.issue","args":"json"}}
        ]}"#,
    );
    assert_eq!(s.run_for_output("ls /tools"), "linear/\r\n");
    let updated = s.run_for_output("cat /tools/linear/org/main/createIssue");
    assert!(
        updated.contains("\"address\":\"linear.org.main.createIssue\"")
            && updated.contains("\"integration\":\"linear\"")
            && updated.contains("\"binding\":{\"type\":\"host_call\",\"name\":\"linear.issue\""),
        "cat /tools/... should reflect the rewritten catalog; got {updated:?}"
    );
}

/// WHY: CLI JSON args should be passed through exactly enough for host-side handlers to parse/validate.
/// GUARANTEES: object args reach the handler as compact JSON and the broker parses a JSON result into
/// envelope `data`, not an opaque stdout string.
#[test]
fn tools_call_passes_json_args_and_parses_json_results() {
    let mut tools = MapHostCall::new();
    tools.register(
        "api call",
        Box::new(|args: &str| Ok(args.as_bytes().to_vec())),
    );
    let mut s = boot_posix_with_tools(tools);
    seed_catalog(
        &mut s,
        r#"{"tools":[{"address":"host.org.main.api.call","description":"Call an API",
          "input_schema":{"type":"object","required":["city"],"properties":{"city":{"type":"string"},"count":{"type":"integer"},"live":{"type":"boolean"},"ratio":{"type":"number"}}},
          "binding":{"type":"host_call","name":"api call","args":"json"}}]}"#,
    );
    let out = s.run_for_output("tools call host.org.main.api.call '{\"city\":\"London\",\"count\":3,\"live\":true,\"ratio\":0.5}'");
    assert_eq!(
        out,
        "{\"ok\":true,\"data\":{\"city\":\"London\",\"count\":3,\"live\":true,\"ratio\":0.5}}\r\n"
    );
}

/// WHY: binary host-tool results must never be reduced to unrecoverable metadata or base64 text.
/// GUARANTEES: non-UTF8 output is materialized as a normal guest file with size and sha256 metadata,
/// and the file bytes are readable through the VM filesystem.
#[test]
fn tools_materializes_binary_results_as_guest_files() {
    let payload = vec![0, 159, 146, 150, b'O', b'K'];
    let sha = pkgcore::sha256_hex(&payload);
    let mut tools = MapHostCall::new();
    let served = payload.clone();
    tools.register("binary", Box::new(move |_args: &str| Ok(served.clone())));
    let mut s = boot_posix_with_tools(tools);
    seed_catalog(
        &mut s,
        r#"{"tools":[{"address":"host.org.main.binary","description":"Binary bytes",
          "binding":{"type":"host_call","name":"binary","args":"json"}}]}"#,
    );

    assert_eq!(
        s.run_for_output("tools call host.org.main.binary {}"),
        format!(
            "{{\"ok\":true,\"data\":{{\"_tag\":\"ToolFile\",\"path\":\"/tmp/tools/results/0\",\"byteLength\":{},\"sha256\":\"{sha}\"}}}}\r\n",
            payload.len()
        )
    );
    assert_eq!(
        s.host
            .read_file("/tmp/tools/results/0")
            .expect("materialized ToolFile"),
        payload
    );

    assert_eq!(
        s.run_for_output("tools gc"),
        "{\"ok\":true,\"data\":{\"removed\":1}}\r\n"
    );
    assert!(
        s.host.read_file("/tmp/tools/results/0").is_err(),
        "tools gc should remove broker-managed result files"
    );
}

/// WHY: large text/JSON-ish outputs are still bytes first; the broker must avoid unbounded service
/// memory growth and hand back a retrievable file once the inline cap is crossed.
#[test]
fn tools_spills_large_results_to_guest_files() {
    let payload = vec![b'x'; 1024 * 1024 + 17];
    let sha = pkgcore::sha256_hex(&payload);
    let mut tools = MapHostCall::new();
    let served = payload.clone();
    tools.register("large", Box::new(move |_args: &str| Ok(served.clone())));
    let mut s = boot_posix_with_tools(tools);
    seed_catalog(
        &mut s,
        r#"{"tools":[{"address":"host.org.main.large","description":"Large result",
          "binding":{"type":"host_call","name":"large","args":"json"}}]}"#,
    );

    let out = s.run_for_output("tools call host.org.main.large {}");
    assert!(
        out.contains("\"_tag\":\"ToolFile\"")
            && out.contains("\"path\":\"/tmp/tools/results/0\"")
            && out.contains(&format!("\"byteLength\":{}", payload.len()))
            && out.contains(&format!("\"sha256\":\"{sha}\"")),
        "large result should be a ToolFile, got {out:?}"
    );
    assert_eq!(
        s.host
            .read_file("/tmp/tools/results/0")
            .expect("large ToolFile"),
        payload
    );
}

/// WHY: callers that already know they want a file should be able to stream directly into a chosen
/// guest path. GUARANTEES: `--output` returns a ToolFile for that path and writes the exact bytes.
#[test]
fn tools_call_output_writes_to_requested_guest_path() {
    let payload = b"written through --output\n".to_vec();
    let sha = pkgcore::sha256_hex(&payload);
    let mut tools = MapHostCall::new();
    let served = payload.clone();
    tools.register("export", Box::new(move |_args: &str| Ok(served.clone())));
    let mut s = boot_posix_with_tools(tools);
    seed_catalog(
        &mut s,
        r#"{"tools":[{"address":"host.org.main.export","description":"Export bytes",
          "binding":{"type":"host_call","name":"export","args":"json"}}]}"#,
    );

    assert_eq!(
        s.run_for_output("tools call host.org.main.export --output /tmp/export.bin {}"),
        format!(
            "{{\"ok\":true,\"data\":{{\"_tag\":\"ToolFile\",\"path\":\"/tmp/export.bin\",\"byteLength\":{},\"sha256\":\"{sha}\"}}}}\r\n",
            payload.len()
        )
    );
    assert_eq!(
        s.host
            .read_file("/tmp/export.bin")
            .expect("requested output"),
        payload
    );
}

/// WHY: destructive approval moved out of the guest broker to the host egress boundary. GUARANTEES:
/// catalog annotations remain descriptive metadata only; `/svc/tools` validates and dispatches without
/// a guest-side approval host-call.
#[test]
fn tools_treats_approval_annotations_as_descriptive_metadata() {
    let calls = Arc::new(Mutex::new(0usize));

    let mut tools = MapHostCall::new();
    {
        let calls = Arc::clone(&calls);
        tools.register(
            "danger.delete",
            Box::new(move |_args: &str| {
                *calls.lock().unwrap() += 1;
                Ok(br#"{"deleted":true}"#.to_vec())
            }),
        );
    }

    let mut s = boot_posix_with_tools(tools);
    seed_catalog(
        &mut s,
        r#"{"tools":[{"address":"host.org.main.deleteThing","description":"Delete a thing",
          "annotations":{"requires_approval":true,"approval_description":"DELETE /things/{id}"},
          "input_schema":{"type":"object","required":["id"],"properties":{"id":{"type":"integer"}}},
          "binding":{"type":"host_call","name":"danger.delete","args":"json"}}]}"#,
    );

    assert_eq!(
        s.run_for_output("tools call host.org.main.deleteThing '{\"id\":1}'"),
        "{\"ok\":true,\"data\":{\"deleted\":true}}\r\n"
    );
    assert_eq!(*calls.lock().unwrap(), 1);
}

/// WHY: SDK-created `/bin/<alias>` symlinks point to one `tools` binary and dispatch by argv[0].
/// GUARANTEES: an alias reaches the unique catalog record for that host binding's leading token.
#[test]
fn tools_alias_dispatches_by_argv0() {
    let mut tools = MapHostCall::new();
    tools.register(
        "greet",
        Box::new(|args: &str| Ok(format!("hello {args}\n").into_bytes())),
    );
    let mut s = boot_posix_with_tools(tools);
    seed_catalog(
        &mut s,
        r#"{"tools":[{"address":"host.org.main.greet","description":"Greet someone",
          "binding":{"type":"host_call","name":"greet","args":"raw"}}]}"#,
    );
    s.host
        .symlink("tools", "/bin/greet")
        .expect("alias /bin/greet -> tools");
    assert_eq!(
        s.run_for_output("greet world"),
        "{\"ok\":true,\"data\":\"hello world\\n\"}\r\n"
    );
}

/// WHY: `pkgfsd` is the demand-load file server for /pkg — a daemon that `serve("/pkg")`s,
/// then spawns its consumer in that namespace. GUARANTEES: given a baked catalog, `pkgfsd ls
/// /pkg/bin` spawns `ls` in pkgfsd's namespace, ls reads the SERVED readdir, and the catalog's tools
/// appear — proving the serve protocol (servedfs) + the spawn-into-namespace model end to end
/// (pkgfsd exits when the consumer closes the channel). The NAME is cheap + offline; no fetch here.
#[test]
fn pkgfsd_serves_the_catalog_over_pkg() {
    let mut s = boot_posix();
    s.host.mkdir("/etc/pkg").ok(); // the catalog dir (CoW overlay over the image)
    s.host
        .write_file(
            "/etc/pkg/catalog",
            b"alpha\tdeadbeef\t10\talpha.wasm\nbeta\tcafef00d\t20\tbeta.wasm\n",
        )
        .expect("write catalog");
    // pkgfsd is a daemon (it serves forever, never returns the prompt), so drive a fixed budget and
    // capture what the spawned `ls` consumer emits.
    let out = s.send_line_async("pkgfsd ls /pkg/bin", 50_000);
    assert!(
        out.contains("alpha") && out.contains("beta"),
        "pkgfsd should serve the catalog at /pkg/bin; got {out:?}"
    );
}

/// WHY: the demand-load READ path — a tool's BYTES are fetched only on open; a cache hit is
/// served from `/var/persist/pkg/<sha>` after a sha256 RE-verify (which defends a corrupted/
/// truncated cache). GUARANTEES: given a catalog row and a matching cached blob, `pkgfsd cat
/// /pkg/bin/<name>` serves the REAL bytes through the serve channel — the demand-load, sha-verified,
/// end to end. (This is the cache-hit branch; the cold-start fetch over /net is netfs's layer and
/// needs a registry, so it is exercised separately.)
#[test]
fn pkgfsd_serves_a_cached_package_on_read() {
    let payload = b"demo package payload\n";
    let sha = pkgcore::sha256_hex(payload); // the content-addressed digest, as the catalog records it
    let dir = PathBuf::from(std::env::var("TEST_TMPDIR").expect("TEST_TMPDIR set by bazel"))
        .join("pkgfsd-cache");
    let mut s = boot_posix_with_persist(dir);

    s.host.mkdir("/etc/pkg").ok();
    let catalog = format!("demo\t{sha}\t{}\tdemo.wasm\n", payload.len());
    s.host
        .write_file("/etc/pkg/catalog", catalog.as_bytes())
        .expect("write catalog");
    s.host.mkdir("/var/persist/pkg").ok();
    s.host
        .write_file(&format!("/var/persist/pkg/{sha}"), payload)
        .expect("seed the cache");

    // pkgfsd serves /pkg + spawns `cat /pkg/bin/demo`; cat reads the SERVED file — pkgfsd resolves
    // it to the cache hit, re-verifies the sha, and streams the bytes back.
    let out = s.send_line_async("pkgfsd cat /pkg/bin/demo", 50_000);
    assert!(
        out.contains("demo package payload"),
        "pkgfsd should serve the cached package; got {out:?}"
    );
}
