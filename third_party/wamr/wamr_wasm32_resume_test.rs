use wasmtime::{Engine, Instance, Module, Store, TypedFunc};

fn probe_wasm() -> Vec<u8> {
    let runfiles = runfiles::Runfiles::create().expect("runfiles unavailable");
    let path = runfiles
        .rlocation("_main/third_party/wamr/wamr_wasm32_probe")
        .expect("wamr_wasm32_probe not found in runfiles");
    std::fs::read(&path).unwrap_or_else(|err| panic!("reading {}: {err}", path.display()))
}

#[test]
fn wamr_wasm32_yields_and_resumes_metered_loop() {
    let engine = Engine::default();
    let module = Module::new(&engine, probe_wasm()).expect("compile WAMR wasm32 probe");
    let mut store = Store::new(&engine, ());
    let instance = Instance::new(&mut store, &module, &[]).expect("instantiate WAMR wasm32 probe");
    let resume_probe: TypedFunc<(), i32> = instance
        .get_typed_func(&mut store, "wamr_wasm32_resume_probe")
        .expect("lookup wamr_wasm32_resume_probe export");

    let yield_count = resume_probe
        .call(&mut store, ())
        .expect("run WAMR wasm32 resume probe");

    println!("observed yield count: {yield_count}");
    assert!(
        yield_count > 1,
        "WAMR did not yield multiple times; probe returned {yield_count}"
    );
}

#[test]
fn wamr_wasm32_trap_is_not_reported_as_yield() {
    let engine = Engine::default();
    let module = Module::new(&engine, probe_wasm()).expect("compile WAMR wasm32 probe");
    let mut store = Store::new(&engine, ());
    let instance = Instance::new(&mut store, &module, &[]).expect("instantiate WAMR wasm32 probe");
    let trap_probe: TypedFunc<(), i32> = instance
        .get_typed_func(&mut store, "wamr_wasm32_trap_probe")
        .expect("lookup wamr_wasm32_trap_probe export");

    let result = trap_probe
        .call(&mut store, ())
        .expect("run WAMR wasm32 trap probe");

    assert_eq!(result, 0, "trap probe failed with code {result}");
}
