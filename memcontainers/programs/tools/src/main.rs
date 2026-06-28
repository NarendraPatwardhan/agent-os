//! `tools` — the tool-plane broker and CLI.
//!
//! In SERVICE mode this binary serves `/svc/tools`: it seeds from `/etc/tools/catalog.json`, owns the
//! warm live catalog, answers `search`/`describe`/`list`, and dispatches `call` through the existing
//! host-call transport (`name\0args`). Runtime catalog mutation is host-control only. As `/bin/tools` it
//! is a CLI client of that service. As a `/bin/<alias>` symlink it dispatches through the catalog by alias,
//! like mcbox-style applets.

#![no_std]
#![no_main]

extern crate alloc;

use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec;
use alloc::vec::Vec;

use json::Json;
use pkgcore::{hex, sha256, Sha256};
use sysroot as rt;
use toolcore::{err_json, ok_json, search_page_json, ArgsMode, Binding, Catalog, ToolRecord};

#[global_allocator]
static ALLOCATOR: talc::wasm::WasmDynamicTalc = talc::wasm::new_wasm_dynamic_allocator();

const SERVICE_NAME: &str = "tools";
const CATALOG_PATH: &str = "/etc/tools/catalog.json";
const RESULTS_DIR: &str = "/tmp/tools/results";
const INLINE_LIMIT: usize = 1024 * 1024;
const COPY_CHUNK: usize = 16 * 1024;
const CONTROL_CALLER: u32 = 0;
const CAP_NET: u32 = rt::CAP_NET as u32;

const HELP: &str = "\
tools — discover and call host-backed tools through /svc/tools

Usage:
  tools search <query> [--limit N] [--offset N]
  tools describe <address>
  tools list
  tools call <address> [--output PATH] [json-or-string]
  tools gc
  <alias> [json-or-string]

The live catalog is owned by /svc/tools after activation. Calls return a JSON envelope:
{\"ok\":true,\"data\":...} or {\"ok\":false,\"err\":{\"code\":...,\"message\":...}}.
Large or binary results are materialized as ToolFile records under /tmp/tools/results unless --output
writes them to a caller-selected guest path.
";

fn fail(msg: &str) -> ! {
    rt::eprint(msg);
    rt::exit(1);
}

fn basename(p: &[u8]) -> &[u8] {
    match p.iter().rposition(|&c| c == b'/') {
        Some(i) => &p[i + 1..],
        None => p,
    }
}

fn read_all_fd(fd: i32) -> Result<Vec<u8>, i32> {
    let mut out = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => break,
            Ok(n) => out.extend_from_slice(&buf[..n]),
            Err(e) => return Err(e),
        }
    }
    Ok(out)
}

fn read_file(path: &str) -> Option<Vec<u8>> {
    let fd = rt::open(path, rt::O_READ).ok()?;
    let out = read_all_fd(fd).ok();
    let _ = rt::close(fd);
    out
}

fn write_stdout(data: &[u8]) {
    if rt::write_all(1, data).is_err() {
        rt::exit(1);
    }
}

fn load_catalog() -> Catalog {
    let Some(bytes) = read_file(CATALOG_PATH) else {
        return Catalog::empty();
    };
    let Ok(text) = core::str::from_utf8(&bytes) else {
        return Catalog::empty();
    };
    Catalog::parse(text).unwrap_or_else(|_| Catalog::empty())
}

fn field_str<'a>(doc: &'a Json, name: &str) -> Option<&'a str> {
    doc.get(name).and_then(|v| v.as_str())
}

fn field_usize(doc: &Json, name: &str, default: usize, max: usize) -> usize {
    doc.get(name)
        .and_then(|v| v.as_u64())
        .map(|n| (n as usize).min(max))
        .unwrap_or(default)
}

fn field_u64(doc: &Json, name: &str) -> Option<u64> {
    doc.get(name).and_then(|v| v.as_u64())
}

fn list_json(catalog: &Catalog) -> Json {
    let mut integrations: Vec<String> = Vec::new();
    let mut tools = Vec::new();
    for rec in catalog.records() {
        if !integrations.iter().any(|i| i == &rec.integration) {
            integrations.push(rec.integration.clone());
        }
        tools.push(Json::Str(rec.address.clone()));
    }
    integrations.sort();
    Json::Obj(vec![
        (
            "integrations".to_string(),
            Json::Arr(integrations.into_iter().map(Json::Str).collect()),
        ),
        ("tools".to_string(), Json::Arr(tools)),
    ])
}

fn catalog_json(catalog: &Catalog) -> Json {
    Json::Obj(vec![(
        "tools".to_string(),
        Json::Arr(catalog.records().iter().map(ToolRecord::to_json).collect()),
    )])
}

fn catalog_text(catalog: &Catalog) -> String {
    json::to_string(&catalog_json(catalog))
}

fn catalog_digest(catalog: &Catalog) -> String {
    hex(&sha256(catalog_text(catalog).as_bytes()))
}

fn checkpoint_catalog(text: &str) -> Result<(), i32> {
    let _ = rt::mkdir("/etc");
    let _ = rt::mkdir("/etc/tools");
    let tmp = "/etc/tools/catalog.json.tmp";
    let fd = rt::open(tmp, rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC)?;
    let write = rt::write_all(fd, text.as_bytes());
    rt::close(fd);
    write?;
    rt::rename(tmp, CATALOG_PATH)
}

fn catalog_status(state: &ToolState, count: usize) -> Json {
    Json::Obj(vec![
        (
            "catalogGeneration".to_string(),
            Json::Num(state.catalog_generation as f64),
        ),
        (
            "catalogDigest".to_string(),
            Json::Str(state.catalog_digest.clone()),
        ),
        ("tools".to_string(), Json::Num(count as f64)),
    ])
}

struct ToolState {
    catalog: Catalog,
    catalog_generation: u64,
    catalog_digest: String,
    next_result_id: u64,
}

impl ToolState {
    fn new() -> Self {
        ensure_result_dirs();
        let catalog = load_catalog();
        let catalog_digest = catalog_digest(&catalog);
        Self {
            catalog,
            catalog_generation: 0,
            catalog_digest,
            next_result_id: scan_next_result_id(),
        }
    }

    fn next_paths(&mut self) -> (String, String) {
        loop {
            let id = self.next_result_id;
            self.next_result_id = self.next_result_id.wrapping_add(1);
            let final_path = format!("{RESULTS_DIR}/{id}");
            if rt::stat(&final_path).is_ok() {
                continue;
            }
            return (format!("{RESULTS_DIR}/.{id}.tmp"), final_path);
        }
    }
}

struct FileSink {
    fd: i32,
    tmp_path: String,
    final_path: String,
    bytes: u64,
    sha: Sha256,
}

impl FileSink {
    fn create(tmp_path: String, final_path: String) -> Result<Self, i32> {
        let fd = rt::open(&tmp_path, rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC)?;
        Ok(Self {
            fd,
            tmp_path,
            final_path,
            bytes: 0,
            sha: Sha256::new(),
        })
    }

    fn write(&mut self, chunk: &[u8]) -> Result<(), i32> {
        rt::write_all(self.fd, chunk)?;
        self.sha.update(chunk);
        self.bytes = self.bytes.saturating_add(chunk.len() as u64);
        Ok(())
    }

    fn finish(self) -> Result<Json, i32> {
        let FileSink {
            fd,
            tmp_path,
            final_path,
            bytes,
            sha,
        } = self;
        rt::close(fd);
        rt::rename(&tmp_path, &final_path)?;
        Ok(tool_file_json(&final_path, bytes, &hex(&sha.finalize())))
    }

    fn abort(self) {
        rt::close(self.fd);
        let _ = rt::unlink(&self.tmp_path);
    }
}

fn ensure_result_dirs() {
    let _ = rt::mkdir("/tmp");
    let _ = rt::mkdir("/tmp/tools");
    let _ = rt::mkdir(RESULTS_DIR);
}

fn scan_next_result_id() -> u64 {
    let mut next = 0u64;
    let mut buf = [0u8; 65536];
    let Ok(n) = rt::readdir(RESULTS_DIR, &mut buf) else {
        return next;
    };
    for name in buf[..n].split(|&b| b == 0).filter(|p| !p.is_empty()) {
        if let Some(id) = parse_u64_bytes(name) {
            next = next.max(id.saturating_add(1));
        }
    }
    next
}

fn parse_u64_bytes(bytes: &[u8]) -> Option<u64> {
    if bytes.is_empty() || bytes.iter().any(|b| !b.is_ascii_digit()) {
        return None;
    }
    let mut n = 0u64;
    for &b in bytes {
        n = n.checked_mul(10)?.checked_add((b - b'0') as u64)?;
    }
    Some(n)
}

fn result_owned_name(name: &[u8]) -> bool {
    parse_u64_bytes(name).is_some()
        || (name.len() > 5
            && name.starts_with(b".")
            && name.ends_with(b".tmp")
            && parse_u64_bytes(&name[1..name.len().saturating_sub(4)]).is_some())
}

fn gc_results() -> Json {
    ensure_result_dirs();
    let mut buf = [0u8; 65536];
    let Ok(n) = rt::readdir(RESULTS_DIR, &mut buf) else {
        return err_json("gc_failed", "could not list result directory");
    };
    let mut removed = 0usize;
    for name in buf[..n].split(|&b| b == 0).filter(|p| !p.is_empty()) {
        if !result_owned_name(name) {
            continue;
        }
        let path = format!("{RESULTS_DIR}/{}", String::from_utf8_lossy(name));
        if rt::unlink(&path).is_ok() {
            removed += 1;
        }
    }
    ok_json(Json::Obj(vec![(
        "removed".to_string(),
        Json::Num(removed as f64),
    )]))
}

fn tool_file_json(path: &str, bytes: u64, sha_hex: &str) -> Json {
    Json::Obj(vec![
        ("_tag".to_string(), Json::Str("ToolFile".to_string())),
        ("path".to_string(), Json::Str(path.to_string())),
        ("byteLength".to_string(), Json::Num(bytes as f64)),
        ("sha256".to_string(), Json::Str(sha_hex.to_string())),
    ])
}

fn result_path(state: &mut ToolState, output: Option<&str>) -> Result<(String, String), ()> {
    ensure_result_dirs();
    match output {
        Some(path) if !path.is_empty() && !path.ends_with('/') => {
            Ok((format!("{path}.tmp"), path.to_string()))
        }
        Some(_) => Err(()),
        None => Ok(state.next_paths()),
    }
}

fn materialize_buffer(state: &mut ToolState, bytes: &[u8]) -> Result<Json, ()> {
    let (tmp, final_path) = result_path(state, None)?;
    let mut sink = FileSink::create(tmp, final_path).map_err(|_| ())?;
    if let Err(_e) = sink.write(bytes) {
        sink.abort();
        return Err(());
    }
    sink.finish().map_err(|_| ())
}

fn copy_host_to_file(fd: i32, state: &mut ToolState, output: Option<&str>) -> Result<Json, ()> {
    let (tmp, final_path) = result_path(state, output)?;
    let mut sink = FileSink::create(tmp, final_path).map_err(|_| ())?;
    let mut buf = [0u8; COPY_CHUNK];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if sink.write(&buf[..n]).is_err() {
                    sink.abort();
                    return Err(());
                }
            }
            Err(_) => {
                sink.abort();
                return Err(());
            }
        }
    }
    sink.finish().map_err(|_| ())
}

fn collect_or_materialize(fd: i32, state: &mut ToolState) -> Result<Json, ()> {
    let mut inline = Vec::new();
    let mut sink: Option<FileSink> = None;
    let mut buf = [0u8; COPY_CHUNK];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if let Some(file) = sink.as_mut() {
                    if file.write(&buf[..n]).is_err() {
                        let file = sink.take().unwrap();
                        file.abort();
                        return Err(());
                    }
                } else if inline.len().saturating_add(n) <= INLINE_LIMIT {
                    inline.extend_from_slice(&buf[..n]);
                } else {
                    let (tmp, final_path) = result_path(state, None)?;
                    let mut file = FileSink::create(tmp, final_path).map_err(|_| ())?;
                    if file.write(&inline).is_err() || file.write(&buf[..n]).is_err() {
                        file.abort();
                        return Err(());
                    }
                    inline.clear();
                    sink = Some(file);
                }
            }
            Err(_) => {
                if let Some(sink) = sink {
                    sink.abort();
                }
                return Err(());
            }
        }
    }

    if let Some(sink) = sink {
        return sink.finish().map_err(|_| ());
    }
    match core::str::from_utf8(&inline) {
        Ok(text) => Ok(json::parse(text).unwrap_or_else(|_| Json::Str(text.to_string()))),
        Err(_) => materialize_buffer(state, &inline),
    }
}

fn args_for_binding(rec: &ToolRecord, args: Option<&Json>) -> Vec<u8> {
    match rec.binding.args_mode() {
        ArgsMode::Raw => match args {
            Some(Json::Str(s)) => s.as_bytes().to_vec(),
            Some(Json::Null) | None => Vec::new(),
            Some(v) => json::to_string(v).into_bytes(),
        },
        ArgsMode::Json => match args {
            Some(v) => json::to_string(v).into_bytes(),
            None => b"{}".to_vec(),
        },
    }
}

fn call_host(
    state: &mut ToolState,
    rec: &ToolRecord,
    args: Option<&Json>,
    output: Option<&str>,
) -> Json {
    let empty_args = Json::Obj(Vec::new());
    let actual_args = args.unwrap_or(&empty_args);
    if toolcore::validate_args(rec.input_schema.as_ref(), actual_args).is_err() {
        return err_json("validation_error", "arguments do not match input_schema");
    }

    let payload = args_for_binding(rec, args);
    let Binding::HostCall { name, .. } = &rec.binding else {
        return err_json("bad_binding", "tool is not a host-call binding");
    };
    let mut req = Vec::with_capacity(name.len() + 1 + payload.len());
    req.extend_from_slice(name.as_bytes());
    req.push(0);
    req.extend_from_slice(&payload);
    let fd = match rt::host_call(&req) {
        Ok(fd) => fd,
        Err(_) => return err_json("host_call_unavailable", "host tools are unavailable"),
    };
    let data = match output {
        Some(_) => copy_host_to_file(fd, state, output),
        None => collect_or_materialize(fd, state),
    };
    let data = match data {
        Ok(data) => data,
        Err(_) => {
            let _ = rt::close(fd);
            return err_json("host_call_failed", "host tool call failed");
        }
    };
    let _ = rt::close(fd);
    ok_json(data)
}

fn service_call_request(rec: &ToolRecord, args: Option<&Json>) -> Result<(String, Vec<u8>), ()> {
    let Binding::Service {
        service,
        op,
        adapter,
        request,
        ..
    } = &rec.binding
    else {
        return Err(());
    };
    let empty_args = Json::Obj(Vec::new());
    let actual_args = args.unwrap_or(&empty_args);
    let doc = Json::Obj(vec![
        ("op".to_string(), Json::Str(op.clone())),
        ("adapter".to_string(), Json::Str(adapter.clone())),
        ("tool".to_string(), Json::Str(rec.address.clone())),
        ("binding".to_string(), request.clone()),
        ("args".to_string(), actual_args.clone()),
    ]);
    Ok((service.clone(), json::to_string(&doc).into_bytes()))
}

fn tool_envelope(v: &Json) -> bool {
    v.get("ok").and_then(|ok| ok.as_bool()).is_some()
}

fn wrap_service_data(data: Json) -> Json {
    if tool_envelope(&data) {
        data
    } else {
        ok_json(data)
    }
}

fn call_service(
    state: &mut ToolState,
    rec: &ToolRecord,
    args: Option<&Json>,
    output: Option<&str>,
) -> Json {
    let empty_args = Json::Obj(Vec::new());
    let actual_args = args.unwrap_or(&empty_args);
    if toolcore::validate_args(rec.input_schema.as_ref(), actual_args).is_err() {
        return err_json("validation_error", "arguments do not match input_schema");
    }

    let (service, body) = match service_call_request(rec, args) {
        Ok(req) => req,
        Err(_) => return err_json("bad_binding", "tool is not a service binding"),
    };
    let conn = match rt::svc_connect(&service) {
        Ok(fd) => fd,
        Err(_) => return err_json("service_unavailable", "tool adapter service is unavailable"),
    };
    let fd = match rt::svc_call(conn, &body, &[]) {
        Ok(fd) => fd,
        Err(_) => {
            let _ = rt::close(conn);
            return err_json("service_call_failed", "tool adapter service call failed");
        }
    };
    let data = match output {
        Some(_) => copy_host_to_file(fd, state, output).map(wrap_service_data),
        None => collect_or_materialize(fd, state).map(wrap_service_data),
    };
    let _ = rt::close(fd);
    let _ = rt::close(conn);
    match data {
        Ok(data) => data,
        Err(_) => err_json(
            "service_call_failed",
            "tool adapter service response failed",
        ),
    }
}

fn call_tool(
    state: &mut ToolState,
    rec: &ToolRecord,
    args: Option<&Json>,
    output: Option<&str>,
) -> Json {
    match rec.binding {
        Binding::HostCall { .. } => call_host(state, rec, args, output),
        Binding::Service { .. } => call_service(state, rec, args, output),
    }
}

fn apply_catalog(state: &mut ToolState, req: &Json, caller: u32) -> Json {
    if caller != CONTROL_CALLER {
        return err_json(
            "permission_denied",
            "catalog mutation requires host control",
        );
    }
    if let Some(base) = field_u64(req, "baseGeneration") {
        if base != state.catalog_generation {
            return err_json("generation_mismatch", "catalog generation changed");
        }
    }
    let Some(tools) = req.get("tools").cloned() else {
        return err_json("bad_request", "catalog.apply requires tools");
    };
    let proposed = Json::Obj(vec![("tools".to_string(), tools)]);
    let proposed_text = json::to_string(&proposed);
    let next = match Catalog::parse(&proposed_text) {
        Ok(catalog) => catalog,
        Err(_) => return err_json("invalid_catalog", "catalog did not validate"),
    };
    let text = catalog_text(&next);
    if checkpoint_catalog(&text).is_err() {
        return err_json("checkpoint_failed", "could not persist tool catalog");
    }
    let count = next.records().len();
    state.catalog = next;
    state.catalog_generation = state.catalog_generation.wrapping_add(1);
    state.catalog_digest = hex(&sha256(text.as_bytes()));
    ok_json(catalog_status(state, count))
}

fn can_call_host_tools(caller: u32, caller_caps: u32) -> bool {
    caller == CONTROL_CALLER || caller_caps & CAP_NET != 0
}

fn require_host_tool_authority(caller: u32, caller_caps: u32) -> Option<Json> {
    if can_call_host_tools(caller, caller_caps) {
        None
    } else {
        Some(err_json("permission_denied", "tool calls require CAP_NET"))
    }
}

fn handle(state: &mut ToolState, req: &Json, caller: u32, caller_caps: u32) -> Json {
    let op = field_str(req, "op").unwrap_or("");
    match op {
        "catalog.apply" => apply_catalog(state, req, caller),
        "search" => {
            let query = field_str(req, "query").unwrap_or("");
            let limit = field_usize(req, "limit", 12, 100);
            let offset = field_usize(req, "offset", 0, usize::MAX);
            let (items, total) = state.catalog.search(query, offset, limit);
            search_page_json(&items, total, offset, limit)
        }
        "describe" => {
            let Some(address) = field_str(req, "address") else {
                return err_json("bad_request", "describe requires address");
            };
            state
                .catalog
                .find(address)
                .map(|rec| rec.to_json())
                .unwrap_or_else(|| err_json("tool_not_found", "no tool with that address"))
        }
        "list" => list_json(&state.catalog),
        "gc" => gc_results(),
        "call" => {
            if let Some(err) = require_host_tool_authority(caller, caller_caps) {
                return err;
            }
            let Some(address) = field_str(req, "address") else {
                return err_json("bad_request", "call requires address");
            };
            let rec = state.catalog.find(address).cloned();
            match rec.as_ref() {
                Some(rec) => call_tool(state, rec, req.get("args"), field_str(req, "output")),
                None => err_json("tool_not_found", "no tool with that address"),
            }
        }
        "call_alias" => {
            if let Some(err) = require_host_tool_authority(caller, caller_caps) {
                return err;
            }
            let Some(alias) = field_str(req, "alias") else {
                return err_json("bad_request", "call_alias requires alias");
            };
            let rec = state.catalog.find_alias(alias).cloned();
            match rec.as_ref() {
                Some(rec) => call_tool(state, rec, req.get("args"), field_str(req, "output")),
                None => err_json("tool_not_found", "no unique tool for that alias"),
            }
        }
        _ => err_json("bad_request", "unknown tools operation"),
    }
}

fn serve_loop() -> ! {
    let mut state = ToolState::new();
    let server = match rt::svc_serve(SERVICE_NAME) {
        Ok(fd) => fd,
        Err(_) => rt::exit(1),
    };
    let mut buf = [0u8; 65536];
    let mut hbuf = [0i32; 0];
    loop {
        let n = match rt::svc_recv(server, &mut buf, &mut hbuf) {
            Ok(n) => n,
            Err(_) => rt::exit(0),
        };
        let Some(req) = rt::parse_svc_request(&buf[..n], &hbuf) else {
            continue;
        };
        if req.kind != rt::SvcKind::Call {
            continue;
        }
        let response = match core::str::from_utf8(req.blob)
            .ok()
            .and_then(|s| json::parse(s).ok())
        {
            Some(doc) => json::to_string(&handle(&mut state, &doc, req.caller, req.caller_caps)),
            None => json::to_string(&err_json("bad_json", "request must be a JSON object")),
        };
        let _ = rt::svc_respond(
            server,
            req.session,
            req.req_id,
            0,
            response.as_bytes(),
            true,
        );
    }
}

fn service_request(req: Json) -> Result<Vec<u8>, ()> {
    let conn = rt::svc_connect(SERVICE_NAME).map_err(|_| ())?;
    let body = json::to_string(&req);
    let fd = rt::svc_call(conn, body.as_bytes(), &[]).map_err(|_| ())?;
    let out = read_all_fd(fd).map_err(|_| ())?;
    let _ = rt::close(fd);
    let _ = rt::close(conn);
    Ok(out)
}

fn json_arg(raw: &[u8]) -> Json {
    let text = String::from_utf8_lossy(raw).into_owned();
    toolcore::parse_json_or_string(&text)
}

fn join_tokens(tokens: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    for (i, tok) in tokens.iter().enumerate() {
        if i > 0 {
            out.push(b' ');
        }
        out.extend_from_slice(tok);
    }
    out
}

fn request_and_print(req: Json) -> ! {
    match service_request(req) {
        Ok(out) => {
            write_stdout(&out);
            write_stdout(b"\n");
            rt::exit(0);
        }
        Err(_) => fail("tools: service unavailable\n"),
    }
}

fn parse_num_arg(tokens: &[&[u8]], flag: &[u8], default: usize) -> usize {
    tokens
        .windows(2)
        .find(|w| w[0] == flag)
        .and_then(|w| core::str::from_utf8(w[1]).ok())
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(default)
}

fn cli(alias: &[u8], aliased: bool, toks: &[&[u8]]) -> ! {
    if aliased {
        let args = if toks.is_empty() {
            Json::Null
        } else {
            json_arg(&join_tokens(toks))
        };
        request_and_print(Json::Obj(vec![
            ("op".to_string(), Json::Str("call_alias".to_string())),
            (
                "alias".to_string(),
                Json::Str(String::from_utf8_lossy(alias).into_owned()),
            ),
            ("args".to_string(), args),
        ]));
    }

    if toks.is_empty() || toks[0] == b"--help" || toks[0] == b"-h" {
        rt::emit_help(HELP);
    }

    match toks[0] {
        b"search" => {
            let mut query_parts = Vec::new();
            let mut i = 1;
            while i < toks.len() {
                if (toks[i] == b"--limit" || toks[i] == b"--offset") && i + 1 < toks.len() {
                    i += 2;
                } else {
                    query_parts.push(toks[i]);
                    i += 1;
                }
            }
            request_and_print(Json::Obj(vec![
                ("op".to_string(), Json::Str("search".to_string())),
                (
                    "query".to_string(),
                    Json::Str(String::from_utf8_lossy(&join_tokens(&query_parts)).into_owned()),
                ),
                (
                    "limit".to_string(),
                    Json::Num(parse_num_arg(toks, b"--limit", 12) as f64),
                ),
                (
                    "offset".to_string(),
                    Json::Num(parse_num_arg(toks, b"--offset", 0) as f64),
                ),
            ]));
        }
        b"describe" => {
            if toks.len() < 2 {
                fail("tools: usage: tools describe <address>\n");
            }
            request_and_print(Json::Obj(vec![
                ("op".to_string(), Json::Str("describe".to_string())),
                (
                    "address".to_string(),
                    Json::Str(String::from_utf8_lossy(toks[1]).into_owned()),
                ),
            ]));
        }
        b"list" => request_and_print(Json::Obj(vec![(
            "op".to_string(),
            Json::Str("list".to_string()),
        )])),
        b"gc" => request_and_print(Json::Obj(vec![(
            "op".to_string(),
            Json::Str("gc".to_string()),
        )])),
        b"call" => {
            if toks.len() < 2 {
                fail("tools: usage: tools call <address> [--output PATH] [json-or-string]\n");
            }
            let mut output: Option<String> = None;
            let mut arg_parts = Vec::new();
            let mut i = 2;
            while i < toks.len() {
                if (toks[i] == b"--output" || toks[i] == b"-o") && i + 1 < toks.len() {
                    output = Some(String::from_utf8_lossy(toks[i + 1]).into_owned());
                    i += 2;
                } else {
                    arg_parts.push(toks[i]);
                    i += 1;
                }
            }
            let args = if !arg_parts.is_empty() {
                json_arg(&join_tokens(&arg_parts))
            } else {
                Json::Obj(Vec::new())
            };
            let mut req = vec![
                ("op".to_string(), Json::Str("call".to_string())),
                (
                    "address".to_string(),
                    Json::Str(String::from_utf8_lossy(toks[1]).into_owned()),
                ),
                ("args".to_string(), args),
            ];
            if let Some(path) = output {
                req.push(("output".to_string(), Json::Str(path)));
            }
            request_and_print(Json::Obj(req));
        }
        _ => fail("tools: usage: tools search|describe|list|call|gc\n"),
    }
}

fn main() {
    let mut argbuf = [0u8; 16384];
    let n = rt::args_into(&mut argbuf);
    let nul0 = argbuf[..n].iter().position(|&b| b == 0);
    let arg0 = nul0.map(|i| &argbuf[..i]).unwrap_or(&argbuf[..n]);
    let start = nul0.map(|i| i + 1).unwrap_or(n);
    let rest = &argbuf[start..n];
    let toks: Vec<&[u8]> = rest.split(|&b| b == 0).filter(|p| !p.is_empty()).collect();
    let arg1 = toks.first().copied().unwrap_or(b"");
    if arg1 == rt::SERVICE_MARKER.as_bytes() {
        serve_loop();
    }
    let alias = basename(arg0);
    cli(alias, alias != b"tools", &toks);
}

rt::entry!(main);
