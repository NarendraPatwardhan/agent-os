use wasmtime::{Engine, Instance, Module, Store, TypedFunc};

fn probe_wasm() -> Vec<u8> {
    let runfiles = runfiles::Runfiles::create().expect("runfiles unavailable");
    let path = runfiles
        .rlocation("_main/third_party/wamr/wamr_wasm32_probe")
        .expect("wamr_wasm32_probe not found in runfiles");
    std::fs::read(&path).unwrap_or_else(|err| panic!("reading {}: {err}", path.display()))
}

#[test]
fn wamr_wasm32_runs_embedded_guest_add_to_completion() {
    let engine = Engine::default();
    let module = Module::new(&engine, probe_wasm()).expect("compile WAMR wasm32 probe");
    let mut store = Store::new(&engine, ());
    let instance = Instance::new(&mut store, &module, &[]).expect("instantiate WAMR wasm32 probe");
    let probe: TypedFunc<(), i32> = instance
        .get_typed_func(&mut store, "wamr_wasm32_probe")
        .expect("lookup wamr_wasm32_probe export");

    let result = probe.call(&mut store, ()).expect("run WAMR wasm32 probe");

    assert_eq!(result, 5, "WAMR did not return add(2, 3)");
}
