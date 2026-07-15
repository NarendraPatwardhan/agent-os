use std::env;
use std::fs;
use std::path::Path;

const BEGIN: &str = "<!-- BEGIN generated:image-size-badges -->";
const END: &str = "<!-- END generated:image-size-badges -->";

fn main() {
    if let Err(err) = run() {
        eprintln!("readme-badges: {err}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("fragment") => fragment(args.collect()),
        Some("update") => update(args.collect()),
        Some(other) => Err(format!("unknown command {other:?}")),
        None => Err("usage: readme-badges <fragment|update> ...".to_string()),
    }
}

fn fragment(args: Vec<String>) -> Result<(), String> {
    if args.is_empty() {
        return Err("fragment needs at least one NAME=PATH pair".to_string());
    }

    println!("    <br>");
    for arg in args {
        let (name, path) = arg
            .split_once('=')
            .ok_or_else(|| format!("expected NAME=PATH, got {arg:?}"))?;
        validate_name(name)?;
        let bytes = fs::metadata(path)
            .map_err(|err| format!("metadata({path:?}) failed: {err}"))?
            .len();
        let message = human_size(bytes);
        let color = badge_color(name)?;
        println!(
            "    <img alt=\"Image size: {name} {message}\" src=\"https://img.shields.io/static/v1?label={label}&amp;message={encoded_message}&amp;color={color}\">",
            label = url_component(name),
            encoded_message = url_component(&message),
        );
    }

    Ok(())
}

fn badge_color(name: &str) -> Result<&'static str, String> {
    match name {
        "minimal" | "posix" => Ok("2e7d32"),
        "loom" => Ok("d99a08"),
        "atlas" | "paper" => Ok("1565c0"),
        other => Err(format!("no badge color configured for {other:?}")),
    }
}

fn update(args: Vec<String>) -> Result<(), String> {
    let mut readme = None;
    let mut fragment = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--readme" => readme = iter.next(),
            "--fragment" => fragment = iter.next(),
            other => return Err(format!("unknown update arg {other:?}")),
        }
    }

    let readme = readme.ok_or_else(|| "update needs --readme PATH".to_string())?;
    let fragment = fragment.ok_or_else(|| "update needs --fragment PATH".to_string())?;
    let readme_text = read_to_string(readme)?;
    let fragment_text = read_to_string(fragment)?;
    print!("{}", replace_region(&readme_text, &fragment_text)?);
    Ok(())
}

fn read_to_string(path: &str) -> Result<String, String> {
    fs::read_to_string(Path::new(path)).map_err(|err| format!("read({path:?}) failed: {err}"))
}

fn replace_region(readme: &str, fragment: &str) -> Result<String, String> {
    let begin_start = readme
        .find(BEGIN)
        .ok_or_else(|| format!("README is missing {BEGIN}"))?;
    let begin_end = readme[begin_start..]
        .find('\n')
        .map(|offset| begin_start + offset + 1)
        .ok_or_else(|| format!("{BEGIN} must be followed by a newline"))?;
    let end_start = readme[begin_end..]
        .find(END)
        .map(|offset| begin_end + offset)
        .ok_or_else(|| format!("README is missing {END}"))?;

    let mut out = String::with_capacity(readme.len() + fragment.len());
    out.push_str(&readme[..begin_end]);
    out.push_str(fragment.trim_end());
    out.push('\n');
    out.push_str(&readme[end_start..]);
    Ok(out)
}

fn validate_name(name: &str) -> Result<(), String> {
    let ok = !name.is_empty()
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if ok {
        Ok(())
    } else {
        Err(format!("invalid badge name {name:?}"))
    }
}

fn human_size(bytes: u64) -> String {
    const KIB: u64 = 1024;
    const MIB: u64 = 1024 * KIB;
    if bytes >= MIB {
        one_decimal(bytes, MIB, "MiB")
    } else if bytes >= KIB {
        one_decimal(bytes, KIB, "KiB")
    } else {
        format!("{bytes} B")
    }
}

fn one_decimal(bytes: u64, unit: u64, suffix: &str) -> String {
    let tenths = (bytes.saturating_mul(10) + unit / 2) / unit;
    if tenths % 10 == 0 {
        format!("{} {suffix}", tenths / 10)
    } else {
        format!("{}.{} {suffix}", tenths / 10, tenths % 10)
    }
}

fn url_component(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'.' | b'_' | b'-' => out.push(byte as char),
            b' ' => out.push_str("%20"),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}
