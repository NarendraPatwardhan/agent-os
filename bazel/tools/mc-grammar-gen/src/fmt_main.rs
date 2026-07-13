use mc_parser_dsl::parse;
use mc_parser_format::format;
use std::fs;
use std::path::PathBuf;

fn usage() -> ! {
    eprintln!("usage: mc-grammar-fmt [--check] FILE...");
    std::process::exit(2)
}

fn main() {
    let mut check = false;
    let mut paths = Vec::new();
    let workspace = std::env::var_os("BUILD_WORKSPACE_DIRECTORY").map(PathBuf::from);
    for argument in std::env::args().skip(1) {
        if argument == "--check" {
            check = true;
        } else if argument.starts_with('-') {
            usage();
        } else {
            let path = PathBuf::from(argument);
            paths.push(if path.is_relative() {
                workspace
                    .as_ref()
                    .map_or(path.clone(), |root| root.join(path))
            } else {
                path
            });
        }
    }
    if paths.is_empty() {
        usage();
    }

    let mut failed = false;
    for path in paths {
        let result = (|| -> Result<(), String> {
            let source = fs::read_to_string(&path)
                .map_err(|error| format!("{}: {error}", path.display()))?;
            let module =
                parse(&source, &path.to_string_lossy()).map_err(|error| error.to_string())?;
            let formatted = format(&module);
            if check {
                if source != formatted {
                    return Err(format!("{} is not canonically formatted", path.display()));
                }
            } else if source != formatted {
                fs::write(&path, formatted)
                    .map_err(|error| format!("{}: {error}", path.display()))?;
            }
            Ok(())
        })();
        if let Err(error) = result {
            eprintln!("mc-grammar-fmt: {error}");
            failed = true;
        }
    }
    if failed {
        std::process::exit(1);
    }
}
