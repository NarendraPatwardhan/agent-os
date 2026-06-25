//! `mc` — the agent-os runtime CLI. Loads a `kernel.wasm` (and an optional base image),
//! then drives it either interactively over a raw terminal or from a scripted input
//! transcript (the mode the e2e suite uses). All the real work lives in the `host`
//! library; this is the thin front door, named `mc` for the running system's identity
//! (§8.2), not `agent-os-*`.

use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::Parser;
use host::{DiskPersist, KernelHostBuilder, RealNet, StdioSink};

mod terminal;
use terminal::Terminal;

#[derive(Parser, Debug)]
#[command(name = "mc", about = "agent-os runtime — load and drive a kernel.wasm")]
struct Cli {
    /// Path to the kernel.wasm artifact.
    #[arg(long, value_name = "PATH")]
    kernel: PathBuf,

    /// Optional base image (tar) to feed via mc_load_base_image.
    #[arg(long, value_name = "PATH")]
    image: Option<PathBuf>,

    /// Replay scripted input bytes from PATH instead of opening a TTY. The host exits once
    /// output has been quiet at a settled prompt or `--timeout-ticks` is reached.
    #[arg(long, value_name = "PATH")]
    script: Option<PathBuf>,

    /// Maximum ticks to run in `--script` mode before bailing.
    #[arg(long, default_value_t = 5000)]
    timeout_ticks: usize,

    /// Grant the network capability (real HTTP/HTTPS/WebSocket egress). Without it the
    /// kernel's `fetch`/`wscat` report "network unavailable" (the default-deny gate, A9).
    #[arg(long)]
    allow_net: bool,

    /// Grant the persistence capability, backed by the directory at PATH (created if
    /// needed). The kernel surfaces it as `/var/persist`; data survives restarts. Without
    /// it, `/var/persist` is read/write-denied (the default-deny gate, A9).
    #[arg(long, value_name = "PATH")]
    persist_dir: Option<PathBuf>,
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    let wasm_bytes = std::fs::read(&cli.kernel)
        .with_context(|| format!("reading kernel from {}", cli.kernel.display()))?;
    let base_image = match &cli.image {
        Some(p) => Some(
            std::fs::read(p).with_context(|| format!("reading base image from {}", p.display()))?,
        ),
        None => None,
    };

    let mut builder = KernelHostBuilder::new(wasm_bytes)
        .with_base_image(base_image)
        .with_stdout(Box::new(StdioSink::stdout()))
        .with_stderr(Box::new(StdioSink::stderr()))
        .with_log(Box::new(StdioSink::stdout()));
    if cli.allow_net {
        builder = builder.with_net(Box::new(RealNet::new()));
    }
    if let Some(dir) = &cli.persist_dir {
        builder = builder.with_persist(Box::new(DiskPersist::new(dir)));
    }
    let mut host = builder.build().context("building KernelHost")?;

    if let Some(path) = &cli.script {
        let bytes = std::fs::read(path)
            .with_context(|| format!("reading script from {}", path.display()))?;
        host.send_input(&bytes).context("sending scripted input")?;
        host.run_script(cli.timeout_ticks)
            .context("running scripted session")?;
        return Ok(());
    }

    // Interactive: raw terminal mode. Install a panic hook so a wasmtime trap or any panic
    // restores cooked mode before the unwind prints.
    install_raw_mode_panic_hook();
    let terminal = Terminal::new()?;
    loop {
        if let Ok(Some(key)) = terminal.read_key() {
            use crossterm::event::{KeyCode, KeyModifiers};
            if let KeyCode::Char('c') = key.code {
                if key.modifiers.contains(KeyModifiers::CONTROL) {
                    break;
                }
            }
            let byte: u8 = match key.code {
                KeyCode::Char(c) => c as u8,
                KeyCode::Enter => b'\n',
                KeyCode::Backspace => 0x08,
                _ => 0,
            };
            if byte != 0 {
                host.send_input(&[byte])?;
            }
        }

        if !host.tick()? {
            break;
        }

        std::thread::sleep(std::time::Duration::from_millis(5));
    }

    Ok(())
}

fn install_raw_mode_panic_hook() {
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let _ = crossterm::terminal::disable_raw_mode();
        default(info);
    }));
}
