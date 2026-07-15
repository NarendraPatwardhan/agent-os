use std::path::PathBuf;

use wasmtime::{Engine, Linker, Module, Store};

fn runfile(path: &str) -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r
        .rlocation(path)
        .unwrap_or_else(|| panic!("{path} not found in runfiles"));
    std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

fn runfile_path(path: &str) -> PathBuf {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    r.rlocation(path)
        .unwrap_or_else(|| panic!("{path} not found in runfiles"))
}

fn unpack(pair: i64) -> (u32, u32) {
    let raw = pair as u64;
    ((raw & 0xffff_ffff) as u32, (raw >> 32) as u32)
}

fn read_return(
    store: &mut Store<()>,
    memory: &wasmtime::Memory,
    free: &wasmtime::TypedFunc<(u32, u32), ()>,
    pair: i64,
) -> Vec<u8> {
    let (ptr, len) = unpack(pair);
    let mut out = vec![0u8; len as usize];
    memory
        .read(&*store, ptr as usize, &mut out)
        .expect("read returned bytes");
    free.call(store, (ptr, len)).expect("free returned bytes");
    out
}

#[test]
fn wasmtime_instantiates_plain_wasm_and_compiles_fixture() {
    let wasm_path = runfile_path("_main/memcontainers/lib/catalog-compiler/catalog-compiler.wasm");
    let wasm = std::fs::read(&wasm_path).expect("read compiler wasm");
    let engine = Engine::default();
    let module = Module::new(&engine, &wasm).expect("compile catalog compiler");
    let imports: Vec<_> = module.imports().collect();
    assert!(
        imports.is_empty(),
        "compiler wasm must not import host/WASI symbols: {imports:?}"
    );

    let mut store = Store::new(&engine, ());
    let linker = Linker::new(&engine);
    let instance = linker
        .instantiate(&mut store, &module)
        .expect("instantiate catalog compiler");
    let memory = instance
        .get_memory(&mut store, "memory")
        .expect("compiler exports memory");
    let alloc = instance
        .get_typed_func::<u32, u32>(&mut store, "cc_alloc")
        .expect("cc_alloc");
    let free = instance
        .get_typed_func::<(u32, u32), ()>(&mut store, "cc_free")
        .expect("cc_free");
    let compile = instance
        .get_typed_func::<(u32, u32, u32, u32), i64>(&mut store, "cc_compile")
        .expect("cc_compile");
    let registry_list = instance
        .get_typed_func::<(), i64>(&mut store, "cc_registry_list")
        .expect("cc_registry_list");
    let registry_resolve = instance
        .get_typed_func::<(u32, u32), i64>(&mut store, "cc_registry_resolve")
        .expect("cc_registry_resolve");
    let schema = instance
        .get_typed_func::<(), u32>(&mut store, "cc_bundle_schema_version")
        .expect("cc_bundle_schema_version");
    assert_eq!(schema.call(&mut store, ()).unwrap(), 1);

    let registry_pair = registry_list.call(&mut store, ()).unwrap();
    let registry = read_return(&mut store, &memory, &free, registry_pair);
    let registry_text = String::from_utf8(registry).unwrap();
    assert!(registry_text.contains("\"id\":\"petstore\""));

    let petstore = b"petstore";
    let petstore_ptr = alloc.call(&mut store, petstore.len() as u32).unwrap();
    memory
        .write(&mut store, petstore_ptr as usize, petstore)
        .expect("write registry id");
    let resolved_pair = registry_resolve
        .call(&mut store, (petstore_ptr, petstore.len() as u32))
        .unwrap();
    let resolved = read_return(&mut store, &memory, &free, resolved_pair);
    free.call(&mut store, (petstore_ptr, petstore.len() as u32))
        .unwrap();
    assert!(String::from_utf8(resolved)
        .unwrap()
        .contains("\"kind\":\"openapi\""));

    let source =
        runfile("_main/memcontainers/lib/catalog-compiler/data/github_issues.openapi.json");
    let opts = runfile("_main/memcontainers/lib/catalog-compiler/data/github_issues.opts.json");
    let src_ptr = alloc.call(&mut store, source.len() as u32).unwrap();
    memory
        .write(&mut store, src_ptr as usize, &source)
        .expect("write source");
    let opts_ptr = alloc.call(&mut store, opts.len() as u32).unwrap();
    memory
        .write(&mut store, opts_ptr as usize, &opts)
        .expect("write opts");
    let pair = compile
        .call(
            &mut store,
            (src_ptr, source.len() as u32, opts_ptr, opts.len() as u32),
        )
        .unwrap();
    free.call(&mut store, (src_ptr, source.len() as u32))
        .unwrap();
    free.call(&mut store, (opts_ptr, opts.len() as u32))
        .unwrap();
    let out = read_return(&mut store, &memory, &free, pair);
    assert!(out.windows("index.json".len()).any(|w| w == b"index.json"));
    assert!(out.windows("records/".len()).any(|w| w == b"records/"));
    assert!(!out
        .windows("connection_ref".len())
        .any(|w| w == b"connection_ref"));
}
