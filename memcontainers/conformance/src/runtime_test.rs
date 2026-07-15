use std::collections::BTreeMap;

use host::{CaptureSink, ExecOptions, KernelHost, KernelHostBuilder};

fn runfile(path: &str) -> Vec<u8> {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    let p = r
        .rlocation(path)
        .unwrap_or_else(|| panic!("{path} not found in runfiles"));
    std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display()))
}

fn boot(image: &str) -> KernelHost {
    boot_with_contract(image, 0, 0, 0)
}

fn boot_with_contract(image: &str, tier: i32, budget_mib: i32, fuel: i64) -> KernelHost {
    let (stdout, _stdout_buf) = CaptureSink::new();
    let (stderr, _stderr_buf) = CaptureSink::new();
    KernelHostBuilder::new(runfile("_main/memcontainers/kernel/rust/kernel.wasm"))
        .with_base_image(Some(runfile(image)))
        .with_contract(tier, budget_mib, fuel)
        .with_stdout(Box::new(stdout))
        .with_stderr(Box::new(stderr))
        .deterministic()
        .build()
        .expect("boot kernel")
}

#[test]
fn typed_control_exec_stat_readdir_and_service_roundtrip() {
    let mut host = boot("_main/memcontainers/images/svc_test.tar");

    host.mkdir("/tmp/conformance").expect("mkdir");
    host.write_file("/tmp/conformance/input", b"file-bytes")
        .expect("write input");
    host.symlink("/tmp/conformance/input", "/tmp/conformance/link")
        .expect("symlink");

    let stat = host.stat("/tmp/conformance/link").expect("stat link");
    assert!(
        stat.is_symlink && !stat.is_dir && stat.nlink == 1,
        "symlink stat came back malformed: {stat:?}"
    );
    let listing = host.readdir("/tmp/conformance").expect("readdir");
    assert!(
        listing
            .iter()
            .any(|entry| entry.name == "input" && !entry.is_dir && !entry.is_symlink),
        "readdir missing regular file entry: {listing:?}"
    );
    assert!(
        listing
            .iter()
            .any(|entry| entry.name == "link" && !entry.is_dir && entry.is_symlink),
        "readdir missing symlink entry: {listing:?}"
    );

    let mut env = BTreeMap::new();
    env.insert("CONF_FLAG".to_string(), "from-env".to_string());
    let exec = host
        .exec(
            "pwd; printf \"$CONF_FLAG\\n\"; read line; printf \"$line\"",
            500_000,
            ExecOptions {
                cwd: Some("/tmp/conformance".to_string()),
                env,
                stdin: Some(b"from-stdin\n".to_vec()),
            },
        )
        .expect("typed exec");
    assert_eq!(
        exec.exit_code,
        0,
        "stderr={}",
        String::from_utf8_lossy(&exec.stderr)
    );
    assert_eq!(
        String::from_utf8(exec.stdout).expect("exec stdout utf8"),
        "/tmp/conformance\nfrom-env\nfrom-stdin"
    );

    let put = host
        .service_call("kv", b"put\0answer\0forty-two")
        .expect("kv put via host control");
    assert_eq!(put.status, 0);
    assert!(
        put.body.is_empty(),
        "put body should be empty: {:?}",
        put.body
    );
    let get = host
        .service_call("kv", b"get\0answer")
        .expect("kv get via host control");
    assert_eq!(get.status, 0);
    assert_eq!(get.body, b"forty-two");
}

#[test]
fn fuel_exhaustion_reparks_and_resumes_a_long_guest() {
    let mut host = boot("_main/memcontainers/images/loom.tar");
    let result = host
        .exec(
            "luau -e 'local x=0; for i=1,1000000 do x=x+i end; print(x)'",
            1_000_000,
            ExecOptions::default(),
        )
        .expect("long luau exec");
    assert_eq!(
        result.exit_code,
        0,
        "stderr={}",
        String::from_utf8_lossy(&result.stderr)
    );
    let out = String::from_utf8(result.stdout).expect("luau stdout utf8");
    assert!(
        out.contains("500000500000"),
        "long guest did not finish after fuel re-parking: {out:?}"
    );
}

#[test]
fn host_trap_unwinds_pcall_and_the_vm_remains_live() {
    let mut host = boot("_main/memcontainers/images/loom.tar");
    host.write_file(
        "/tmp/pcall.luau",
        concat!(
            "local ok = pcall(function() error('boom') end)\n",
            "print('caught=' .. tostring(ok == false))\n",
            "local n = 0\n",
            "for i = 1, 20 do if not pcall(function() error(i) end) then n = n + 1 end end\n",
            "print('stress=' .. tostring(n == 20))\n",
            "print(2 + 2)\n",
        )
        .as_bytes(),
    )
    .expect("write pcall script");
    let result = host
        .exec("luau /tmp/pcall.luau", 500_000, ExecOptions::default())
        .expect("pcall luau exec");
    assert_eq!(
        result.exit_code,
        0,
        "stderr={}",
        String::from_utf8_lossy(&result.stderr)
    );
    let out = String::from_utf8(result.stdout).expect("pcall stdout utf8");
    assert!(out.contains("caught=true"), "pcall did not resume: {out}");
    assert!(out.contains("stress=true"), "pcall stress failed: {out}");
    assert!(
        out.contains("4"),
        "VM did not stay live after trap unwind: {out}"
    );
}

#[test]
fn runtime_fuel_ceiling_kills_a_runaway_guest() {
    let mut host = boot_with_contract("_main/memcontainers/images/posix.tar", 0, 0, 10_000_000);
    let result = host
        .exec("while true; do :; done", 500_000, ExecOptions::default())
        .expect("runaway exec should finish by budget kill");
    assert_eq!(result.exit_code, 137, "runaway exit status");
    let stderr = String::from_utf8_lossy(&result.stderr);
    assert!(
        stderr.contains("cpu budget exceeded"),
        "budget kill did not surface expected stderr: {stderr:?}"
    );
}
