//! `tools` — the tool-plane broker and CLI.
//!
//! In SERVICE mode this binary serves `/svc/tools`: it seeds from `/etc/tools/catalog/index.json`,
//! keeps a warm digest-keyed index, answers `search`/`list` from that index, and hydrates one sharded
//! record for `describe`/`call`. Runtime catalog mutation is host-control only. As `/bin/tools` it is a
//! CLI client of that service. As a `/bin/<alias>` symlink it dispatches through the catalog by alias,
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
use toolcore::{
    err_json, ok_json, search_page_json, ArgsMode, Binding, CatalogIndex, IndexEntry, ToolRecord,
};

#[global_allocator]
static ALLOCATOR: talc::wasm::WasmDynamicTalc = talc::wasm::new_wasm_dynamic_allocator();

const SERVICE_NAME: &str = "tools";
const CATALOG_ROOT: &str = "/etc/tools/catalog";
const CATALOG_INDEX_PATH: &str = "/etc/tools/catalog/index.json";
const CATALOG_DIGEST_PATH: &str = "/etc/tools/catalog/index.sha256";
const CATALOG_RECORDS_DIR: &str = "/etc/tools/catalog/records";
const RESULTS_DIR: &str = "/tmp/tools/results";
const INLINE_LIMIT: usize = 1024 * 1024;
const COPY_CHUNK: usize = 16 * 1024;
const SHARD_CACHE_LIMIT: usize = 32;
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

fn digest_hex(bytes: &[u8]) -> String {
    hex(&sha256(bytes))
}

fn ensure_catalog_dirs() {
    let _ = rt::mkdir("/etc");
    let _ = rt::mkdir("/etc/tools");
    let _ = rt::mkdir(CATALOG_ROOT);
    let _ = rt::mkdir(CATALOG_RECORDS_DIR);
}

fn load_index() -> (CatalogIndex, String) {
    let Some(bytes) = read_file(CATALOG_INDEX_PATH) else {
        return (CatalogIndex::empty(), String::new());
    };
    // The index bytes are the source of truth; the digest is computed from them (never from the
    // sidecar, which is only a `/tools` accelerator and could be stale after an interrupted write).
    let digest = digest_hex(&bytes);
    let Ok(text) = core::str::from_utf8(&bytes) else {
        return (CatalogIndex::empty(), digest);
    };
    (
        CatalogIndex::parse(text).unwrap_or_else(|_| CatalogIndex::empty()),
        digest,
    )
}

fn list_json(index: &CatalogIndex) -> Json {
    let mut integrations: Vec<String> = Vec::new();
    let mut tools = Vec::new();
    for entry in index.entries() {
        if !integrations.iter().any(|i| i == &entry.integration) {
            integrations.push(entry.integration.clone());
        }
        tools.push(Json::Str(entry.address.clone()));
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

fn write_atomic(path: &str, tmp: &str, bytes: &[u8]) -> Result<(), i32> {
    let fd = rt::open(tmp, rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC)?;
    let write = rt::write_all(fd, bytes);
    rt::close(fd);
    write?;
    rt::rename(tmp, path)
}

fn checkpoint_index(index_text: &str, digest: &str) -> Result<(), i32> {
    ensure_catalog_dirs();
    // Write the digest sidecar first, then commit the index with the atomic rename — so the index.json
    // rename is the single commit point and the live index never carries an OLDER sidecar. (The broker
    // trusts the index bytes regardless; this keeps the `/tools` accelerator consistent.)
    let mut digest_body = digest.as_bytes().to_vec();
    digest_body.push(b'\n');
    write_atomic(
        CATALOG_DIGEST_PATH,
        "/etc/tools/catalog/index.sha256.tmp",
        &digest_body,
    )?;
    write_atomic(
        CATALOG_INDEX_PATH,
        "/etc/tools/catalog/index.json.tmp",
        index_text.as_bytes(),
    )
}

fn catalog_status(state: &ToolState) -> Json {
    Json::Obj(vec![
        (
            "catalogGeneration".to_string(),
            Json::Num(state.catalog_generation as f64),
        ),
        (
            "catalogDigest".to_string(),
            Json::Str(state.catalog_digest.clone()),
        ),
        (
            "tools".to_string(),
            Json::Num(state.index.entries().len() as f64),
        ),
    ])
}

struct ToolState {
    index: CatalogIndex,
    shard_cache: Vec<(String, ToolRecord)>,
    catalog_generation: u64,
    catalog_digest: String,
    next_result_id: u64,
}

impl ToolState {
    fn new() -> Self {
        ensure_result_dirs();
        ensure_catalog_dirs();
        let (index, catalog_digest) = load_index();
        let catalog_generation = index.generation();
        Self {
            index,
            shard_cache: Vec::new(),
            catalog_generation,
            catalog_digest,
            next_result_id: scan_next_result_id(),
        }
    }

    fn reload_if_changed(&mut self) {
        // Detect change by hashing the current index bytes (the source of truth) — not the digest
        // sidecar, which could be stale after an interrupted write and would then mask a real change.
        // The index is the small discovery list (not the shards), so this is cheap relative to the
        // per-shard hydration it gates, and it costs nothing to load when unchanged.
        let observed = match read_file(CATALOG_INDEX_PATH) {
            Some(bytes) => digest_hex(&bytes),
            None => String::new(),
        };
        if observed == self.catalog_digest {
            return;
        }
        let (index, digest) = load_index();
        self.catalog_generation = index.generation();
        self.index = index;
        self.shard_cache.clear();
        self.catalog_digest = digest;
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

    fn cached_record(&mut self, entry: &IndexEntry) -> Option<ToolRecord> {
        let pos = self
            .shard_cache
            .iter()
            .position(|(sha, _)| sha == &entry.sha)?;
        let (_, record) = self.shard_cache.remove(pos);
        self.shard_cache
            .insert(0, (entry.sha.clone(), record.clone()));
        Some(record)
    }

    fn insert_record_cache(&mut self, entry: &IndexEntry, record: ToolRecord) {
        if let Some(pos) = self
            .shard_cache
            .iter()
            .position(|(sha, _)| sha == &entry.sha)
        {
            self.shard_cache.remove(pos);
        }
        self.shard_cache.insert(0, (entry.sha.clone(), record));
        if self.shard_cache.len() > SHARD_CACHE_LIMIT {
            self.shard_cache.pop();
        }
    }

    fn hydrate_entry(&mut self, entry: &IndexEntry) -> Result<ToolRecord, Json> {
        if let Some(record) = self.cached_record(entry) {
            return Ok(record);
        }
        let path = format!("{CATALOG_RECORDS_DIR}/{}", entry.sha);
        let Some(bytes) = read_file(&path) else {
            return Err(err_json("catalog_shard_missing", "tool shard is missing"));
        };
        if digest_hex(&bytes) != entry.sha {
            return Err(err_json(
                "catalog_shard_corrupt",
                "tool shard digest mismatch",
            ));
        }
        let Ok(text) = core::str::from_utf8(&bytes) else {
            return Err(err_json(
                "catalog_shard_invalid",
                "tool shard was not UTF-8",
            ));
        };
        let record = toolcore::hydrate_record(entry, text)
            .map_err(|_| err_json("catalog_shard_invalid", "tool shard did not validate"))?;
        self.insert_record_cache(entry, record.clone());
        Ok(record)
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
    let (integration, owner, connection, _) =
        toolcore::parse_address(&rec.address).map_err(|_| ())?;
    let connection_ref = format!("{integration}.{owner}.{connection}");
    let doc = Json::Obj(vec![
        ("op".to_string(), Json::Str(op.clone())),
        ("adapter".to_string(), Json::Str(adapter.clone())),
        ("tool".to_string(), Json::Str(rec.address.clone())),
        ("connection_ref".to_string(), Json::Str(connection_ref)),
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
    let Some(generation) = field_u64(req, "generation") else {
        return err_json("bad_request", "catalog.apply requires generation");
    };
    let Some(index_json) = req.get("index").cloned() else {
        return err_json("bad_request", "catalog.apply requires index");
    };
    let Some(digest) = field_str(req, "digest") else {
        return err_json("bad_request", "catalog.apply requires digest");
    };
    if digest.len() != 64 || !digest.bytes().all(|b| b.is_ascii_hexdigit()) {
        return err_json("bad_request", "catalog.apply digest must be sha256 hex");
    }
    let index_text = json::to_string(&index_json);
    let computed = digest_hex(index_text.as_bytes());
    if computed != digest.to_ascii_lowercase() {
        return err_json(
            "digest_mismatch",
            "catalog.apply digest does not match index",
        );
    }
    let next = match CatalogIndex::parse(&index_text) {
        Ok(index) => index,
        Err(_) => return err_json("invalid_catalog", "catalog index did not validate"),
    };
    if next.generation() != generation {
        return err_json(
            "generation_mismatch",
            "index generation did not match request",
        );
    }
    // Optimistic-concurrency guard: a single host controls the catalog, so a request whose generation
    // is older than the live one is a stale or replayed apply — reject it rather than roll the catalog
    // backwards. (Re-applying the current generation is idempotent and allowed.)
    if generation < state.catalog_generation {
        return err_json(
            "generation_conflict",
            "catalog.apply generation is older than the live catalog",
        );
    }
    // Verify every referenced shard is present AND content-addressed correctly before committing, so a
    // torn shard write can never go live (the broker also re-verifies lazily on hydration).
    for entry in next.entries() {
        match read_file(&format!("{CATALOG_RECORDS_DIR}/{}", entry.sha)) {
            Some(bytes) if digest_hex(&bytes) == entry.sha => {}
            Some(_) => {
                return err_json(
                    "catalog_shard_corrupt",
                    "catalog.apply shard does not match its content address",
                )
            }
            None => {
                return err_json(
                    "catalog_shard_missing",
                    "catalog.apply references a missing shard",
                )
            }
        }
    }
    if checkpoint_index(&index_text, &computed).is_err() {
        return err_json("checkpoint_failed", "could not persist tool catalog index");
    }
    state.index = next;
    state.catalog_generation = generation;
    state.catalog_digest = computed;
    state.shard_cache.clear();
    ok_json(catalog_status(state))
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
    state.reload_if_changed();
    let op = field_str(req, "op").unwrap_or("");
    match op {
        "catalog.apply" => apply_catalog(state, req, caller),
        "search" => {
            let query = field_str(req, "query").unwrap_or("");
            let limit = field_usize(req, "limit", 12, 100);
            let offset = field_usize(req, "offset", 0, usize::MAX);
            let (items, total) = state.index.search(query, offset, limit);
            search_page_json(&items, total, offset, limit)
        }
        "describe" => {
            let Some(address) = field_str(req, "address") else {
                return err_json("bad_request", "describe requires address");
            };
            let Some(entry) = state.index.find(address).cloned() else {
                return err_json("tool_not_found", "no tool with that address");
            };
            match state.hydrate_entry(&entry) {
                Ok(rec) => rec.to_json(),
                Err(err) => err,
            }
        }
        "list" => list_json(&state.index),
        "gc" => gc_results(),
        "call" => {
            if let Some(err) = require_host_tool_authority(caller, caller_caps) {
                return err;
            }
            let Some(address) = field_str(req, "address") else {
                return err_json("bad_request", "call requires address");
            };
            let Some(entry) = state.index.find(address).cloned() else {
                return err_json("tool_not_found", "no tool with that address");
            };
            let rec = match state.hydrate_entry(&entry) {
                Ok(rec) => rec,
                Err(err) => return err,
            };
            call_tool(state, &rec, req.get("args"), field_str(req, "output"))
        }
        "call_alias" => {
            if let Some(err) = require_host_tool_authority(caller, caller_caps) {
                return err;
            }
            let Some(alias) = field_str(req, "alias") else {
                return err_json("bad_request", "call_alias requires alias");
            };
            let Some(entry) = state.index.find_alias(alias).cloned() else {
                return err_json("tool_not_found", "no unique tool for that alias");
            };
            let rec = match state.hydrate_entry(&entry) {
                Ok(rec) => rec,
                Err(err) => return err,
            };
            call_tool(state, &rec, req.get("args"), field_str(req, "output"))
        }
        _ => err_json("bad_request", "unknown tools operation"),
    }
}

fn serve_loop() -> ! {
    let server = match rt::svc_serve(SERVICE_NAME) {
        Ok(fd) => fd,
        Err(_) => rt::exit(1),
    };
    // Activation should prove that the endpoint exists, not that every warm
    // index has already been rebuilt. Large real-world catalogs are still
    // loaded before the first request is handled, but after `svc_serve` the
    // kernel's activation watchdog is no longer the startup bottleneck.
    let mut state = ToolState::new();
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
