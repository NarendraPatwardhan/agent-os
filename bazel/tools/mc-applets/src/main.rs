use std::process::ExitCode;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Set {
    Full,
    Min,
}

fn extract_quoted(line: &str, key: &str) -> Option<String> {
    let start = line.find(key)? + key.len();
    let rest = &line[start..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

fn extract_tier(line: &str) -> Option<String> {
    let start = line.find(".tier = .")? + ".tier = .".len();
    let rest = &line[start..];
    let end = rest
        .find(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .unwrap_or(rest.len());
    Some(rest[..end].to_string())
}

fn applets_payload(registry: &str, want_tier: &str, want_set: Set) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    for line in registry.lines() {
        if !line.contains(".name = ") || !line.contains(".tier = .") {
            continue;
        }
        let name = extract_quoted(line, ".name = \"")
            .ok_or_else(|| format!("malformed applet name in line: {line}"))?;
        let tier = extract_tier(line).ok_or_else(|| format!("malformed tier in line: {line}"))?;
        if tier != want_tier {
            continue;
        }
        if want_set == Set::Min && !line.contains(".min_set = true") {
            continue;
        }
        out.extend_from_slice(name.as_bytes());
        out.push(b'\n');
    }
    Ok(out)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 5 {
        eprintln!("usage: mc-applets <registry_data.zig> <tier> <full|min> <out>");
        return ExitCode::from(2);
    }

    let set = match args[3].as_str() {
        "full" => Set::Full,
        "min" => Set::Min,
        other => {
            eprintln!("mc-applets: invalid set `{other}` (expected full|min)");
            return ExitCode::from(2);
        }
    };

    let registry = match std::fs::read_to_string(&args[1]) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("mc-applets: reading {}: {e}", args[1]);
            return ExitCode::from(1);
        }
    };

    let payload = match applets_payload(&registry, &args[2], set) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("mc-applets: {e}");
            return ExitCode::from(2);
        }
    };

    if let Err(e) = std::fs::write(&args[4], payload) {
        eprintln!("mc-applets: writing {}: {e}", args[4]);
        return ExitCode::from(1);
    }
    ExitCode::SUCCESS
}
