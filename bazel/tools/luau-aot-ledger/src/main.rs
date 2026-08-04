use luau_aot_ledger::{canonical_json, extract, validate_policy};
use std::process::ExitCode;

fn run(args: &[String]) -> Result<(), String> {
    match args {
        [command, input, output] if command == "extract" => {
            let source = std::fs::read_to_string(input).map_err(|e| format!("reading {input}: {e}"))?;
            let result = extract(&source)?;
            std::fs::write(output, canonical_json(&result)?).map_err(|e| format!("writing {output}: {e}"))
        }
        [command, input, policy] if command == "validate" => {
            let source = std::fs::read_to_string(input).map_err(|e| format!("reading {input}: {e}"))?;
            let policy_json = std::fs::read_to_string(policy).map_err(|e| format!("reading {policy}: {e}"))?;
            validate_policy(&extract(&source)?, &policy_json)
        }
        _ => Err("usage: luau-aot-ledger extract <IrData.h> <output.json>\n       luau-aot-ledger validate <IrData.h> <policy.json>".to_owned()),
    }
}

fn main() -> ExitCode {
    let args: Vec<_> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("luau-aot-ledger: {error}");
            ExitCode::from(2)
        }
    }
}
