use sidecar_helper::{
    cleanup, launch, network_host_init, prepare, reconcile, renew, Config, CONFIG_PATH, VERSION,
};
use std::env;
use std::fs;
use std::path::Path;

extern "C" {
    fn getuid() -> u32;
    fn geteuid() -> u32;
    fn setgroups(size: usize, groups: *const u32) -> i32;
    fn seteuid(uid: u32) -> i32;
    fn umask(mask: u32) -> u32;
}

fn main() {
    if let Err(error) = run() {
        eprintln!("agentos-sidecar-helper: {error}");
        std::process::exit(125);
    }
}

fn run() -> Result<(), String> {
    let args = env::args().skip(1).collect::<Vec<_>>();
    if args.as_slice() == ["version"] {
        println!("agentos-sidecar-helper {VERSION}");
        return Ok(());
    }

    let real_uid = unsafe { getuid() };
    let effective_uid = unsafe { geteuid() };
    if effective_uid != 0 {
        return Err("must be installed root-owned setuid".into());
    }
    if unsafe { setgroups(0, std::ptr::null()) } != 0 {
        return Err("could not clear supplementary groups".into());
    }

    if real_uid != 0 && unsafe { seteuid(real_uid) } != 0 {
        return Err("could not drop privilege for validation".into());
    }
    let config = Config::load(Path::new(CONFIG_PATH))?;
    if real_uid != 0 && config.runner_uid != real_uid {
        return Err("caller is not the configured runner uid".into());
    }
    for (key, _) in env::vars_os().collect::<Vec<_>>() {
        env::remove_var(key);
    }
    if real_uid != 0 && unsafe { seteuid(0) } != 0 {
        return Err("could not reacquire privilege".into());
    }
    unsafe { umask(0o077) };
    env::set_current_dir("/").map_err(|error| format!("set safe working directory: {error}"))?;
    config.validate_installation()?;

    match args.as_slice() {
        [command] if command == "sys-test" => {
            fs::OpenOptions::new()
                .read(true)
                .write(true)
                .open("/dev/kvm")
                .map_err(|error| format!("open /dev/kvm: {error}"))?;
            if !Path::new("/sys/fs/cgroup/cgroup.controllers").is_file() {
                return Err("cgroup v2 is not mounted".into());
            }
            println!("agentos-sidecar-helper {VERSION}");
            Ok(())
        }
        [command] if command == "network-host-init" => network_host_init(&config),
        [command] if command == "reconcile" => reconcile(&config),
        [command, flag, id] if flag == "--id" && command == "layout" => {
            let layout = config.layout(id)?;
            println!("api={}", layout.api.display());
            println!("vsock={}", layout.vsock.display());
            println!("cgroup={}", layout.cgroup.display());
            println!("netns={}", layout.netns);
            println!("kernel=/kernel");
            println!("initramfs=/initramfs");
            Ok(())
        }
        [command, flag, id] if flag == "--id" && command == "prepare" => {
            prepare(&config, id, None, false).map(|_| ())
        }
        [command, profile_flag, profile, id_flag, id]
            if profile_flag == "--profile" && id_flag == "--id" && command == "prepare" =>
        {
            prepare(&config, id, Some(profile), false).map(|_| ())
        }
        [command, network_flag, id_flag, id]
            if network_flag == "--network" && id_flag == "--id" && command == "prepare" =>
        {
            prepare(&config, id, None, true).map(|_| ())
        }
        [command, profile_flag, profile, network_flag, id_flag, id]
            if profile_flag == "--profile"
                && network_flag == "--network"
                && id_flag == "--id"
                && command == "prepare" =>
        {
            prepare(&config, id, Some(profile), true).map(|_| ())
        }
        [command, flag, id] if flag == "--id" && command == "renew" => renew(&config, id),
        [command, flag, id] if flag == "--id" && command == "jailer" => {
            std::process::exit(launch(&config, id, None, false)?);
        }
        [command, profile_flag, profile, id_flag, id]
            if profile_flag == "--profile" && id_flag == "--id" && command == "jailer" =>
        {
            std::process::exit(launch(&config, id, Some(profile), false)?);
        }
        [command, network_flag, id_flag, id]
            if network_flag == "--network" && id_flag == "--id" && command == "jailer" =>
        {
            std::process::exit(launch(&config, id, None, true)?);
        }
        [command, profile_flag, profile, network_flag, id_flag, id]
            if profile_flag == "--profile"
                && network_flag == "--network"
                && id_flag == "--id"
                && command == "jailer" =>
        {
            std::process::exit(launch(&config, id, Some(profile), true)?);
        }
        [command, flag, id] if flag == "--id" && command == "cleanup" => cleanup(&config, id),
        _ => Err("usage: version | sys-test | network-host-init | reconcile | layout|prepare|renew|jailer|cleanup [--profile PROFILE] [--network] --id ID".into()),
    }
}
