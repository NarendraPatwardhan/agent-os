use mc_parser_generate::{Options, Outputs, run};
use std::path::PathBuf;

fn usage() -> ! {
    eprintln!(
        "usage: mc-grammar-gen --root FILE [--module ID=FILE] --vocabulary syntax.kdl --ir OUT --grammar-json OUT --parser-c OUT --node-types OUT --semantics OUT --semantics-c OUT --diagnostics OUT --manifest OUT"
    );
    std::process::exit(2)
}
fn main() {
    let mut args = std::env::args().skip(1);
    let mut root = None;
    let mut vocabulary = None;
    let mut modules = Vec::new();
    let mut values = std::collections::BTreeMap::new();
    while let Some(flag) = args.next() {
        let value = args.next().unwrap_or_else(|| usage());
        match flag.as_str() {
            "--root" => root = Some(PathBuf::from(value)),
            "--vocabulary" => vocabulary = Some(PathBuf::from(value)),
            "--module" => {
                let Some((id, path)) = value.split_once('=') else {
                    usage()
                };
                modules.push((id.into(), PathBuf::from(path)));
            }
            "--ir" | "--grammar-json" | "--parser-c" | "--node-types" | "--semantics"
            | "--semantics-c" | "--diagnostics" | "--manifest" => {
                values.insert(flag, PathBuf::from(value));
            }
            _ => usage(),
        }
    }
    let mut take = |name: &str| values.remove(name).unwrap_or_else(|| usage());
    let options = Options {
        root: root.unwrap_or_else(|| usage()),
        modules,
        vocabulary: vocabulary.unwrap_or_else(|| usage()),
        outputs: Outputs {
            ir: take("--ir"),
            grammar_json: take("--grammar-json"),
            parser_c: take("--parser-c"),
            node_types: take("--node-types"),
            semantics: take("--semantics"),
            semantics_c: take("--semantics-c"),
            diagnostics: take("--diagnostics"),
            manifest: take("--manifest"),
        },
    };
    if let Err(error) = run(options) {
        eprintln!("mc-grammar-gen: {error}");
        std::process::exit(1)
    }
}
