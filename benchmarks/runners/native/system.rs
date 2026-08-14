use std::fs;
use std::process::Command;

pub(crate) fn proc_bytes(key: &str) -> Option<u64> {
    let status = fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|line| line.starts_with(key))?;
    let kib = line.split_whitespace().nth(1)?.parse::<u64>().ok()?;
    Some(kib * 1024)
}

pub(crate) fn pss_bytes() -> Option<u64> {
    let rollup = fs::read_to_string("/proc/self/smaps_rollup").ok()?;
    let line = rollup.lines().find(|line| line.starts_with("Pss:"))?;
    Some(line.split_whitespace().nth(1)?.parse::<u64>().ok()? * 1024)
}

pub(crate) fn command_output(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

pub(crate) fn host_perf_metadata() -> serde_json::Value {
    let governor = fs::read_to_string("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
        .ok()
        .map(|s| s.trim().to_owned());
    let freq = fs::read_to_string("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok());
    let max_freq = fs::read_to_string("/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok());
    let vmstat = fs::read_to_string("/proc/vmstat").unwrap_or_default();
    let pick = |key: &str| {
        vmstat.lines().find_map(|line| {
            let mut parts = line.split_whitespace();
            (parts.next() == Some(key))
                .then(|| parts.next()?.parse::<u64>().ok())
                .flatten()
        })
    };
    serde_json::json!({
        "cpuGovernor": governor,
        "cpuFreqKhz": freq,
        "cpuMaxFreqKhz": max_freq,
        "majorFaults": pick("pgmajfault"),
        "swapIn": pick("pswpin"),
        "swapOut": pick("pswpout"),
        "perfTracing": perf_enabled(),
    })
}

pub(crate) fn system_metadata() -> serde_json::Value {
    let cpuinfo = fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let cpu_model = cpuinfo
        .lines()
        .find_map(|line| line.strip_prefix("model name\t: "))
        .unwrap_or("unknown");
    let mem_total = fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|text| {
            text.lines()
                .find(|line| line.starts_with("MemTotal:"))
                .and_then(|line| line.split_whitespace().nth(1))
                .and_then(|value| value.parse::<u64>().ok())
        })
        .map(|kib| kib * 1024);
    serde_json::json!({
        "hostname": command_output("hostname", &[]).unwrap_or_else(|| "unknown".to_owned()),
        "os": std::env::consts::OS,
        "architecture": std::env::consts::ARCH,
        "logicalCpus": std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1),
        "cpuModel": cpu_model,
        "totalMemoryBytes": mem_total,
        "runtime": "wasmtime via memcontainers/hosts/wasmtime",
        "process": {
            "rssBytes": proc_bytes("VmRSS:"),
            "peakRssBytes": proc_bytes("VmHWM:"),
            "pssBytes": pss_bytes()
        },
        "perf": host_perf_metadata(),
    })
}

/// Opt-in PERF-013 tracing. Accepts `1` / `true` / `yes` (case-insensitive). Unset or other values = off.
pub(crate) fn perf_enabled() -> bool {
    match std::env::var("MC_PERF") {
        Ok(v) => {
            let v = v.trim();
            v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("yes")
        }
        Err(_) => false,
    }
}
