use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use wasmtime::{Engine, Instance, Linker, Memory, Module, Store, TypedFunc};

use crate::sha256_hex;
use crate::KernelHost;

#[derive(Debug, Clone)]
pub struct CatalogConnection {
    pub reference: String,
    pub spec: Option<CatalogSpecSource>,
    pub tools: Vec<String>,
}

#[derive(Debug, Clone)]
pub enum CatalogSpecSource {
    Bytes {
        bytes: Vec<u8>,
        format: Option<String>,
        source_format: Option<String>,
        base_url: Option<String>,
        endpoint: Option<String>,
    },
    Path {
        path: PathBuf,
        format: Option<String>,
        source_format: Option<String>,
        base_url: Option<String>,
        endpoint: Option<String>,
    },
    Url {
        url: String,
        format: Option<String>,
        source_format: Option<String>,
        base_url: Option<String>,
        endpoint: Option<String>,
    },
}

/// A host-call tool definition injected directly into the catalog (the Rust mirror of the JS SDK's
/// `toolCatalogBundle`): it does not need the compiler, since there is no spec to normalize — its shard
/// is a `host_call` binding the BEAM/host owner answers.
#[derive(Debug, Clone)]
pub struct HostToolDef {
    pub address: String,
    pub description: String,
    pub binding_name: String,
    pub args_mode: String,
    /// Raw JSON (`None` when absent); parsed here, in the crate that already links serde_json, so
    /// the NIF boundary stays JSON-free.
    pub input_schema: Option<String>,
    pub output_schema: Option<String>,
    pub annotations: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CatalogInjectOptions {
    pub compiler_wasm: Vec<u8>,
    pub connections: Vec<CatalogConnection>,
    pub tools: Vec<String>,
    pub host_tools: Vec<HostToolDef>,
    pub generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogApplyStatus {
    pub generation: u64,
    pub digest: String,
    pub tools: usize,
}

#[derive(Debug, Clone)]
struct SourceBytes {
    bytes: Vec<u8>,
    sha: String,
    format: String,
    base_url: Option<String>,
    endpoint: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct RegistryEntry {
    id: String,
    kind: String,
    url: Option<String>,
    endpoint: Option<String>,
    #[serde(rename = "defaultGroups")]
    default_groups: Option<Vec<String>>,
    groups: Option<BTreeMap<String, RegistryGroup>>,
}

#[derive(Debug, Clone, Deserialize)]
struct RegistryGroup {
    filter: Option<CompileFilter>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
struct CompileFilter {
    exact_paths: Vec<String>,
    path_prefixes: Vec<String>,
    tag_prefixes: Vec<String>,
}

#[derive(Debug, Clone)]
struct RefParts {
    integration: String,
    owner: String,
    connection: String,
}

#[derive(Debug, Clone)]
struct CompilerEntries {
    entries: BTreeMap<String, Vec<u8>>,
}

#[derive(Debug, Clone)]
struct ToolCatalogBundle {
    index: CatalogIndexOut,
    index_bytes: Vec<u8>,
    index_digest: String,
    records: Vec<CatalogRecordOut>,
}

#[derive(Debug, Clone, Serialize)]
struct CatalogIndexOut {
    generation: u64,
    tools: Vec<CatalogIndexToolOut>,
}

#[derive(Debug, Clone, Serialize)]
struct CatalogIndexToolOut {
    address: String,
    integration: String,
    description: String,
    sha: String,
}

#[derive(Debug, Clone)]
struct CatalogRecordOut {
    sha: String,
    bytes: Vec<u8>,
}

#[derive(Default)]
struct CatalogCache {
    source_by_sha: HashMap<String, Vec<u8>>,
    source_sha_by_url: HashMap<String, String>,
    bundle_by_key: HashMap<String, BTreeMap<String, Vec<u8>>>,
}

static CATALOG_CACHE: OnceLock<Mutex<CatalogCache>> = OnceLock::new();

struct CatalogCompiler {
    store: Store<()>,
    memory: Memory,
    alloc: TypedFunc<u32, u32>,
    free: TypedFunc<(u32, u32), ()>,
    registry_resolve: TypedFunc<(u32, u32), i64>,
    compile: TypedFunc<(u32, u32, u32, u32), i64>,
    bundle_schema_version: TypedFunc<(), u32>,
    artifact_digest: String,
}

impl CatalogCompiler {
    fn instantiate(wasm: &[u8]) -> Result<Self> {
        let artifact_digest = sha256_hex(wasm);
        let engine = Engine::default();
        let module = Module::new(&engine, wasm)?;
        let imports = module.imports().collect::<Vec<_>>();
        if !imports.is_empty() {
            return Err(anyhow!(
                "catalog compiler must be pure wasm; imports={imports:?}"
            ));
        }
        let mut store = Store::new(&engine, ());
        let linker = Linker::new(&engine);
        let instance = linker.instantiate(&mut store, &module)?;
        let memory = instance
            .get_memory(&mut store, "memory")
            .ok_or_else(|| anyhow!("catalog compiler is missing memory"))?;
        Ok(Self {
            alloc: typed(&instance, &mut store, "cc_alloc")?,
            free: typed(&instance, &mut store, "cc_free")?,
            registry_resolve: typed(&instance, &mut store, "cc_registry_resolve")?,
            compile: typed(&instance, &mut store, "cc_compile")?,
            bundle_schema_version: typed(&instance, &mut store, "cc_bundle_schema_version")?,
            store,
            memory,
            artifact_digest,
        })
    }

    fn registry_resolve(&mut self, id: &str) -> Result<RegistryEntry> {
        let raw = self.call_with_input(id.as_bytes(), |compiler, ptr, len| {
            compiler
                .registry_resolve
                .call(&mut compiler.store, (ptr, len))
                .map_err(anyhow::Error::from)
        })?;
        let parsed: Value = serde_json::from_slice(&raw)?;
        if let Some(message) = parsed
            .get("error")
            .and_then(|e| e.get("message"))
            .and_then(Value::as_str)
        {
            return Err(anyhow!(message.to_string()));
        }
        Ok(serde_json::from_value(parsed)?)
    }

    fn compile(&mut self, source: &[u8], opts_json: &[u8]) -> Result<CompilerEntries> {
        let src_ptr = self.write(source)?;
        let opts_ptr = self.write(opts_json)?;
        let pair = self
            .compile
            .call(
                &mut self.store,
                (
                    src_ptr,
                    source.len() as u32,
                    opts_ptr,
                    opts_json.len() as u32,
                ),
            )
            .map_err(anyhow::Error::from);
        self.free
            .call(&mut self.store, (src_ptr, source.len() as u32))?;
        self.free
            .call(&mut self.store, (opts_ptr, opts_json.len() as u32))?;
        let raw = self.read_return(pair?)?;
        let entries = decode_framed_bundle(&raw)?;
        if let Some(error) = entries.get("error.json") {
            let parsed: Value = serde_json::from_slice(error)?;
            let message = parsed
                .get("error")
                .and_then(|e| e.get("message"))
                .and_then(Value::as_str)
                .unwrap_or("catalog compiler failed");
            return Err(anyhow!(message.to_string()));
        }
        Ok(CompilerEntries { entries })
    }

    fn schema_version(&mut self) -> Result<u32> {
        Ok(self.bundle_schema_version.call(&mut self.store, ())?)
    }

    fn call_with_input(
        &mut self,
        input: &[u8],
        f: impl FnOnce(&mut Self, u32, u32) -> Result<i64>,
    ) -> Result<Vec<u8>> {
        let ptr = self.write(input)?;
        let pair = f(self, ptr, input.len() as u32);
        self.free.call(&mut self.store, (ptr, input.len() as u32))?;
        self.read_return(pair?)
    }

    fn write(&mut self, bytes: &[u8]) -> Result<u32> {
        let ptr = self.alloc.call(&mut self.store, bytes.len() as u32)?;
        self.memory.write(&mut self.store, ptr as usize, bytes)?;
        Ok(ptr)
    }

    fn read_return(&mut self, pair: i64) -> Result<Vec<u8>> {
        let (ptr, len) = unpack_return(pair);
        let mut out = vec![0u8; len as usize];
        self.memory.read(&self.store, ptr as usize, &mut out)?;
        self.free.call(&mut self.store, (ptr, len))?;
        Ok(out)
    }
}

fn typed<T, U>(instance: &Instance, store: &mut Store<()>, name: &str) -> Result<TypedFunc<T, U>>
where
    T: wasmtime::WasmParams,
    U: wasmtime::WasmResults,
{
    instance
        .get_typed_func(store, name)
        .map_err(|e| anyhow!("catalog compiler is missing {name}: {e}"))
}

impl KernelHost {
    pub fn inject_catalog(
        &mut self,
        opts: CatalogInjectOptions,
    ) -> Result<Option<CatalogApplyStatus>> {
        if opts.connections.is_empty() && opts.host_tools.is_empty() {
            return Ok(None);
        }
        let mut bundles = Vec::new();
        if !opts.host_tools.is_empty() {
            bundles.push(host_tool_catalog_bundle(&opts.host_tools, opts.generation)?);
        }
        if !opts.connections.is_empty() {
            // Only connection/spec tools need the compiler; host-call tools are sharded directly.
            let mut compiler = CatalogCompiler::instantiate(&opts.compiler_wasm)?;
            bundles.push(connection_tool_catalog_bundle(&mut compiler, &opts)?);
        }
        let bundle = merge_tool_catalog_bundles(bundles, opts.generation)?;
        self.ensure_catalog_dirs()?;
        for record in &bundle.records {
            self.write_file(
                &format!("/etc/tools/catalog/records/{}", record.sha),
                &record.bytes,
            )?;
        }
        let index_text = std::str::from_utf8(&bundle.index_bytes)?;
        let request = format!(
            r#"{{"op":"catalog.apply","generation":{},"index":{},"digest":"{}"}}"#,
            opts.generation, index_text, bundle.index_digest
        )
        .into_bytes();
        let response = self.service_call("tools", &request)?;
        if response.status != 0 {
            return Err(anyhow!(
                "catalog.apply service call failed with status {}",
                response.status
            ));
        }
        let parsed: Value = serde_json::from_slice(&response.body)?;
        if parsed.get("ok").and_then(Value::as_bool) != Some(true) {
            return Err(anyhow!("catalog.apply rejected update: {}", parsed));
        }
        Ok(Some(CatalogApplyStatus {
            generation: opts.generation,
            digest: bundle.index_digest,
            tools: bundle.index.tools.len(),
        }))
    }

    fn ensure_catalog_dirs(&mut self) -> Result<()> {
        for path in [
            "/etc",
            "/etc/tools",
            "/etc/tools/catalog",
            "/etc/tools/catalog/records",
        ] {
            match self.stat(path) {
                Ok(stat) if stat.is_dir => {}
                _ => {
                    let _ = self.mkdir(path);
                }
            }
        }
        Ok(())
    }
}

pub fn read_default_catalog_compiler_wasm() -> Result<Vec<u8>> {
    let rel = std::env::var("MC_CATALOG_COMPILER_WASM").map_err(|_| {
        anyhow!("catalog-compiler.wasm not available: set MC_CATALOG_COMPILER_WASM")
    })?;
    let path = if rel.starts_with('/') {
        PathBuf::from(rel)
    } else if let Ok(runfiles) = std::env::var("RUNFILES_DIR") {
        PathBuf::from(runfiles).join(rel)
    } else {
        PathBuf::from(rel)
    };
    std::fs::read(&path).map_err(|e| anyhow!("reading {}: {e}", path.display()))
}

/// Shard host-call tool definitions into a bundle (mirror of the JS `toolCatalogBundle`): each shard is
/// the connection-agnostic payload `{input_schema?, output_schema?, annotations, binding}`, content-
/// addressed by its own bytes; the full address lives only in the index. No compiler is involved.
fn host_tool_catalog_bundle(defs: &[HostToolDef], generation: u64) -> Result<ToolCatalogBundle> {
    let mut tools = Vec::new();
    let mut records = BTreeMap::<String, Vec<u8>>::new();
    let mut seen = std::collections::BTreeSet::new();
    for def in defs {
        if !seen.insert(def.address.clone()) {
            return Err(anyhow!("duplicate tool catalog address '{}'", def.address));
        }
        if !valid_tool_address(&def.address) {
            return Err(anyhow!("invalid host tool address '{}'", def.address));
        }
        if !valid_binding_name(&def.binding_name) {
            return Err(anyhow!("invalid host tool binding name '{}'", def.binding_name));
        }
        if def.args_mode != "json" && def.args_mode != "raw" {
            return Err(anyhow!(
                "host tool args mode must be `json` or `raw`, got '{}'",
                def.args_mode
            ));
        }
        let mut shard = serde_json::Map::new();
        if let Some(json) = &def.input_schema {
            shard.insert("input_schema".to_string(), parse_host_tool_json(json, "input_schema")?);
        }
        if let Some(json) = &def.output_schema {
            shard.insert("output_schema".to_string(), parse_host_tool_json(json, "output_schema")?);
        }
        shard.insert(
            "annotations".to_string(),
            match &def.annotations {
                Some(json) => parse_host_tool_json(json, "annotations")?,
                None => Value::Object(serde_json::Map::new()),
            },
        );
        shard.insert(
            "binding".to_string(),
            serde_json::json!({"type": "host_call", "name": def.binding_name, "args": def.args_mode}),
        );
        let bytes = serde_json::to_vec(&Value::Object(shard))?;
        let sha = sha256_hex(&bytes);
        records.entry(sha.clone()).or_insert(bytes);
        tools.push(CatalogIndexToolOut {
            address: def.address.clone(),
            integration: def.address.split('.').next().unwrap_or("host").to_string(),
            description: def.description.clone(),
            sha,
        });
    }
    tools.sort_by(|a, b| a.address.cmp(&b.address));
    let index = CatalogIndexOut { generation, tools };
    let index_bytes = serde_json::to_vec(&index)?;
    Ok(ToolCatalogBundle {
        index,
        index_bytes: index_bytes.clone(),
        index_digest: sha256_hex(&index_bytes),
        records: records
            .into_iter()
            .map(|(sha, bytes)| CatalogRecordOut { sha, bytes })
            .collect(),
    })
}

/// Mirror of `toolcore::valid_binding_name`: a plain UTF-8 host-call name, not a raw `/...` mount key,
/// trimmed, no control/framing bytes.
fn valid_binding_name(name: &str) -> bool {
    !name.is_empty()
        && !name.starts_with('/')
        && name.trim() == name
        && !name.bytes().any(|b| b.is_ascii_control())
}

fn parse_host_tool_json(json: &str, field: &str) -> Result<Value> {
    serde_json::from_str(json).map_err(|e| anyhow!("host tool {field} must be valid JSON: {e}"))
}

/// Mirror of `toolcore::parse_address`'s shape check: `integration.{org|user}.connection.tool…`.
fn valid_tool_address(address: &str) -> bool {
    let parts: Vec<&str> = address.split('.').collect();
    parts.len() >= 4
        && (parts[1] == "org" || parts[1] == "user")
        && parts.iter().all(|p| {
            !p.is_empty()
                && p.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        })
}

fn connection_tool_catalog_bundle(
    compiler: &mut CatalogCompiler,
    opts: &CatalogInjectOptions,
) -> Result<ToolCatalogBundle> {
    let mut bundles = Vec::new();
    for connection in &opts.connections {
        let ref_parts = parse_ref(&connection.reference)?;
        let registry = resolve_registry(compiler, &ref_parts.integration, connection)?;
        let groups = selected_groups(
            &ref_parts.integration,
            &registry,
            &opts.tools,
            &connection.tools,
        );
        for group in groups {
            let source = acquire_source(connection, &registry)?;
            let compile_opts =
                resolved_compile_opts(&ref_parts.integration, &registry, &source, group.as_deref());
            let entries = compile_cached(compiler, &source, &compile_opts)?;
            bundles.push(bundle_from_compiler_entries(
                entries,
                &ref_parts,
                opts.generation,
            )?);
        }
    }
    merge_tool_catalog_bundles(bundles, opts.generation)
}

fn resolve_registry(
    compiler: &mut CatalogCompiler,
    integration: &str,
    connection: &CatalogConnection,
) -> Result<RegistryEntry> {
    for id in [
        integration.to_string(),
        format!("{integration}-rest"),
        format!("{integration}-openapi"),
    ] {
        if let Ok(entry) = compiler.registry_resolve(&id) {
            return Ok(entry);
        }
    }
    if let Some(spec) = &connection.spec {
        if let Some(format) = spec_format(spec) {
            return Ok(RegistryEntry {
                id: integration.to_string(),
                kind: format,
                url: spec_url(spec),
                endpoint: spec_endpoint(spec),
                default_groups: None,
                groups: None,
            });
        }
    }
    Err(anyhow!(
        "connection '{}' does not resolve to a catalog registry entry",
        connection.reference
    ))
}

fn selected_groups(
    integration: &str,
    registry: &RegistryEntry,
    root_selectors: &[String],
    connection_selectors: &[String],
) -> Vec<Option<String>> {
    let mut explicit = selectors_for_connection(integration, &registry.id, root_selectors);
    explicit.extend(selectors_for_connection(
        integration,
        &registry.id,
        connection_selectors,
    ));
    if !explicit.is_empty() {
        return dedupe_options(explicit);
    }
    match &registry.default_groups {
        Some(defaults) if !defaults.is_empty() => defaults.iter().cloned().map(Some).collect(),
        _ => vec![None],
    }
}

fn selectors_for_connection(
    integration: &str,
    registry_id: &str,
    selectors: &[String],
) -> Vec<Option<String>> {
    let mut out = Vec::new();
    for raw in selectors {
        let selector = raw.trim();
        if selector.is_empty() {
            continue;
        }
        let Some((lhs, rhs)) = selector.split_once('/') else {
            if selector == integration || selector == registry_id {
                out.push(None);
            }
            continue;
        };
        if (lhs == integration || lhs == registry_id) && !rhs.is_empty() {
            out.push(Some(rhs.to_string()));
        }
    }
    out
}

fn acquire_source(connection: &CatalogConnection, registry: &RegistryEntry) -> Result<SourceBytes> {
    match &connection.spec {
        Some(CatalogSpecSource::Bytes {
            bytes,
            source_format,
            format: _,
            base_url,
            endpoint,
        }) => cached_source(
            bytes.clone(),
            source_format.clone().unwrap_or_else(|| "json".to_string()),
            base_url.clone(),
            endpoint.clone(),
        ),
        Some(CatalogSpecSource::Path {
            path,
            source_format,
            format: _,
            base_url,
            endpoint,
        }) => cached_source(
            std::fs::read(path)?,
            source_format
                .clone()
                .unwrap_or_else(|| source_format_for_path(&path.to_string_lossy())),
            base_url.clone(),
            endpoint.clone(),
        ),
        Some(CatalogSpecSource::Url {
            url,
            source_format,
            format: _,
            base_url,
            endpoint,
        }) => fetch_source(
            url,
            source_format
                .clone()
                .unwrap_or_else(|| source_format_for_path(url)),
            base_url.clone(),
            endpoint.clone(),
        ),
        None => {
            let url = registry.url.as_ref().ok_or_else(|| {
                anyhow!(
                    "connection '{}' requires a provided spec",
                    connection.reference
                )
            })?;
            fetch_source(
                url,
                source_format_for_path(url),
                None,
                registry.endpoint.clone(),
            )
        }
    }
}

fn cached_source(
    bytes: Vec<u8>,
    format: String,
    base_url: Option<String>,
    endpoint: Option<String>,
) -> Result<SourceBytes> {
    let sha = sha256_hex(&bytes);
    let mut cache = CATALOG_CACHE
        .get_or_init(|| Mutex::new(CatalogCache::default()))
        .lock()
        .map_err(|_| anyhow!("catalog cache lock poisoned"))?;
    cache.source_by_sha.insert(sha.clone(), bytes.clone());
    Ok(SourceBytes {
        bytes,
        sha,
        format,
        base_url,
        endpoint,
    })
}

fn fetch_source(
    url: &str,
    format: String,
    base_url: Option<String>,
    endpoint: Option<String>,
) -> Result<SourceBytes> {
    if let Some(loaded) = {
        let cache = CATALOG_CACHE
            .get_or_init(|| Mutex::new(CatalogCache::default()))
            .lock()
            .map_err(|_| anyhow!("catalog cache lock poisoned"))?;
        cache.source_sha_by_url.get(url).and_then(|sha| {
            cache
                .source_by_sha
                .get(sha)
                .map(|bytes| (sha.clone(), bytes.clone()))
        })
    } {
        return Ok(SourceBytes {
            bytes: loaded.1,
            sha: loaded.0,
            format,
            base_url,
            endpoint,
        });
    }
    let response = ureq::get(url).call()?;
    let mut reader = response.into_reader();
    let mut bytes = Vec::new();
    use std::io::Read as _;
    reader.read_to_end(&mut bytes)?;
    let loaded = cached_source(bytes, format, base_url, endpoint)?;
    let mut cache = CATALOG_CACHE
        .get_or_init(|| Mutex::new(CatalogCache::default()))
        .lock()
        .map_err(|_| anyhow!("catalog cache lock poisoned"))?;
    cache
        .source_sha_by_url
        .insert(url.to_string(), loaded.sha.clone());
    Ok(loaded)
}

fn resolved_compile_opts(
    integration: &str,
    registry: &RegistryEntry,
    source: &SourceBytes,
    group: Option<&str>,
) -> Value {
    let filter = filter_for_group(
        group,
        registry
            .groups
            .as_ref()
            .and_then(|g| group.and_then(|id| g.get(id))),
    );
    let mut out = serde_json::Map::new();
    out.insert("format".to_string(), Value::String(registry.kind.clone()));
    out.insert(
        "source_format".to_string(),
        Value::String(source.format.clone()),
    );
    out.insert(
        "integration".to_string(),
        Value::String(integration.to_string()),
    );
    if let Some(group) = group {
        out.insert("group".to_string(), Value::String(group.to_string()));
    }
    out.insert(
        "filter".to_string(),
        serde_json::to_value(filter).expect("filter serializes"),
    );
    out.insert(
        "base_url".to_string(),
        source
            .base_url
            .clone()
            .or_else(|| registry.endpoint.clone())
            .map(Value::String)
            .unwrap_or(Value::Null),
    );
    out.insert(
        "endpoint".to_string(),
        source
            .endpoint
            .clone()
            .or_else(|| registry.endpoint.clone())
            .map(Value::String)
            .unwrap_or(Value::Null),
    );
    Value::Object(out)
}

fn filter_for_group(group: Option<&str>, registry_group: Option<&RegistryGroup>) -> CompileFilter {
    if let Some(filter) = registry_group.and_then(|g| g.filter.clone()) {
        return filter;
    }
    CompileFilter {
        exact_paths: Vec::new(),
        path_prefixes: Vec::new(),
        tag_prefixes: group.map(|g| vec![g.to_string()]).unwrap_or_default(),
    }
}

fn compile_cached(
    compiler: &mut CatalogCompiler,
    source: &SourceBytes,
    opts: &Value,
) -> Result<BTreeMap<String, Vec<u8>>> {
    let canonical_opts = canonical_json(opts)?;
    let schema_version = compiler.schema_version()?;
    // The artifact digest (sha256 of the compiler wasm) is the compiler's identity — it changes
    // whenever the binary does, fully subsuming any in-wasm version string.
    let key = sha256_hex(
        format!(
            "{}\0{}\0{}\0{}",
            compiler.artifact_digest, schema_version, source.sha, canonical_opts
        )
        .as_bytes(),
    );
    if let Some(cached) = CATALOG_CACHE
        .get_or_init(|| Mutex::new(CatalogCache::default()))
        .lock()
        .map_err(|_| anyhow!("catalog cache lock poisoned"))?
        .bundle_by_key
        .get(&key)
        .cloned()
    {
        return Ok(cached);
    }
    let bundle = compiler.compile(&source.bytes, canonical_opts.as_bytes())?;
    let mut cache = CATALOG_CACHE
        .get_or_init(|| Mutex::new(CatalogCache::default()))
        .lock()
        .map_err(|_| anyhow!("catalog cache lock poisoned"))?;
    cache.bundle_by_key.insert(key, bundle.entries.clone());
    Ok(bundle.entries)
}

fn bundle_from_compiler_entries(
    entries: BTreeMap<String, Vec<u8>>,
    ref_parts: &RefParts,
    generation: u64,
) -> Result<ToolCatalogBundle> {
    let index_bytes = entries
        .get("index.json")
        .ok_or_else(|| anyhow!("catalog compiler bundle missing index.json"))?;
    let parsed: Value = serde_json::from_slice(index_bytes)?;
    let tools_value = parsed
        .get("tools")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("catalog compiler bundle index has invalid shape"))?;
    let mut tools = Vec::new();
    for value in tools_value {
        let address = value
            .get("address")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("catalog compiler bundle index entry has invalid address"))?;
        let sha = value
            .get("sha")
            .and_then(Value::as_str)
            .ok_or_else(|| anyhow!("catalog compiler bundle index entry has invalid sha"))?;
        tools.push(CatalogIndexToolOut {
            address: re_prefix_address(address, ref_parts)?,
            integration: ref_parts.integration.clone(),
            description: value
                .get("description")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string(),
            sha: sha.to_string(),
        });
    }
    tools.sort_by(|a, b| a.address.cmp(&b.address));
    let index = CatalogIndexOut { generation, tools };
    let index_bytes = serde_json::to_vec(&index)?;
    let mut records = Vec::new();
    for (path, bytes) in entries {
        if let Some(sha) = path.strip_prefix("records/") {
            records.push(CatalogRecordOut {
                sha: sha.to_string(),
                bytes,
            });
        }
    }
    Ok(ToolCatalogBundle {
        index,
        index_bytes: index_bytes.clone(),
        index_digest: sha256_hex(&index_bytes),
        records,
    })
}

fn merge_tool_catalog_bundles(
    bundles: Vec<ToolCatalogBundle>,
    generation: u64,
) -> Result<ToolCatalogBundle> {
    let mut by_address = BTreeMap::<String, CatalogIndexToolOut>::new();
    let mut records = BTreeMap::<String, Vec<u8>>::new();
    for bundle in bundles {
        for record in bundle.records {
            if let Some(existing) = records.get(&record.sha) {
                if existing != &record.bytes {
                    return Err(anyhow!("catalog record sha collision '{}'", record.sha));
                }
            }
            records.insert(record.sha, record.bytes);
        }
        for tool in bundle.index.tools {
            if by_address.insert(tool.address.clone(), tool).is_some() {
                return Err(anyhow!("duplicate tool catalog address"));
            }
        }
    }
    let index = CatalogIndexOut {
        generation,
        tools: by_address.into_values().collect(),
    };
    let index_bytes = serde_json::to_vec(&index)?;
    Ok(ToolCatalogBundle {
        index,
        index_bytes: index_bytes.clone(),
        index_digest: sha256_hex(&index_bytes),
        records: records
            .into_iter()
            .map(|(sha, bytes)| CatalogRecordOut { sha, bytes })
            .collect(),
    })
}

fn re_prefix_address(address: &str, ref_parts: &RefParts) -> Result<String> {
    let parts = address.split('.').collect::<Vec<_>>();
    if parts.len() < 4 {
        return Err(anyhow!(
            "catalog compiler emitted invalid tool address '{}'",
            address
        ));
    }
    Ok(format!(
        "{}.{}.{}.{}",
        ref_parts.integration,
        ref_parts.owner,
        ref_parts.connection,
        parts[3..].join(".")
    ))
}

fn parse_ref(reference: &str) -> Result<RefParts> {
    let parts = reference.split('.').collect::<Vec<_>>();
    if parts.len() != 3
        || !safe_segment(parts[0])
        || !matches!(parts[1], "org" | "user")
        || !safe_segment(parts[2])
    {
        return Err(anyhow!("invalid connection reference '{}'", reference));
    }
    Ok(RefParts {
        integration: parts[0].to_string(),
        owner: parts[1].to_string(),
        connection: parts[2].to_string(),
    })
}

fn safe_segment(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|b| matches!(b, b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'_' | b'-'))
}

fn dedupe_options(values: Vec<Option<String>>) -> Vec<Option<String>> {
    let mut out = Vec::new();
    for value in values {
        if !out.contains(&value) {
            out.push(value);
        }
    }
    out
}

fn spec_format(spec: &CatalogSpecSource) -> Option<String> {
    match spec {
        CatalogSpecSource::Bytes { format, .. }
        | CatalogSpecSource::Path { format, .. }
        | CatalogSpecSource::Url { format, .. } => format.clone(),
    }
}

fn spec_url(spec: &CatalogSpecSource) -> Option<String> {
    match spec {
        CatalogSpecSource::Url { url, .. } => Some(url.clone()),
        _ => None,
    }
}

fn spec_endpoint(spec: &CatalogSpecSource) -> Option<String> {
    match spec {
        CatalogSpecSource::Bytes { endpoint, .. }
        | CatalogSpecSource::Path { endpoint, .. }
        | CatalogSpecSource::Url { endpoint, .. } => endpoint.clone(),
    }
}

fn source_format_for_path(path: &str) -> String {
    if path.to_ascii_lowercase().contains(".yaml") || path.to_ascii_lowercase().contains(".yml") {
        "yaml".to_string()
    } else {
        "json".to_string()
    }
}

fn canonical_json(value: &Value) -> Result<String> {
    Ok(serde_json::to_string(&canonical(value))?)
}

fn canonical(value: &Value) -> Value {
    match value {
        Value::Array(items) => Value::Array(items.iter().map(canonical).collect()),
        Value::Object(map) => {
            let mut out = serde_json::Map::new();
            let mut keys = map.keys().collect::<Vec<_>>();
            keys.sort();
            for key in keys {
                out.insert(key.clone(), canonical(&map[key]));
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

fn decode_framed_bundle(bytes: &[u8]) -> Result<BTreeMap<String, Vec<u8>>> {
    let mut pos = 0usize;
    let count = read_u32(bytes, &mut pos)? as usize;
    let mut out = BTreeMap::new();
    for _ in 0..count {
        let path_len = read_u32(bytes, &mut pos)? as usize;
        let byte_len = read_u32(bytes, &mut pos)? as usize;
        let end = pos
            .checked_add(path_len)
            .and_then(|n| n.checked_add(byte_len))
            .ok_or_else(|| anyhow!("catalog compiler returned a malformed bundle frame"))?;
        if end > bytes.len() {
            return Err(anyhow!(
                "catalog compiler returned a truncated bundle frame"
            ));
        }
        let path = std::str::from_utf8(&bytes[pos..pos + path_len])?.to_string();
        pos += path_len;
        out.insert(path, bytes[pos..pos + byte_len].to_vec());
        pos += byte_len;
    }
    if pos != bytes.len() {
        return Err(anyhow!(
            "catalog compiler returned a bundle frame with trailing bytes"
        ));
    }
    Ok(out)
}

fn read_u32(bytes: &[u8], pos: &mut usize) -> Result<u32> {
    if *pos + 4 > bytes.len() {
        return Err(anyhow!(
            "catalog compiler returned a truncated bundle frame"
        ));
    }
    let value = u32::from_le_bytes(bytes[*pos..*pos + 4].try_into().unwrap());
    *pos += 4;
    Ok(value)
}

fn unpack_return(pair: i64) -> (u32, u32) {
    let raw = pair as u64;
    ((raw & 0xffff_ffff) as u32, (raw >> 32) as u32)
}
