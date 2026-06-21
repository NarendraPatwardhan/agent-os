// programs/sh/src/main.rs — /bin/sh, the guest shell (NOT part of the mcbox multicall, §16.3).
//
// A wasm32-freestanding guest that runs the OS-agnostic `shcore` engine over
// `sysroot` syscalls (so it imports only `mc` — no WASI). The same binary serves three
// modes — interactive REPL, `sh -c '…'`, and `sh script [args…]` — and is the
// single shell used for both the interactive prompt (booted as pid 1) and
// scripts. There is no `fork`: subshells/`$()` are handled in-process by
// `shcore`; blocking syscalls are made cooperative by the kernel.

#![no_std]
#![no_main]

extern crate alloc;

use alloc::format;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;

use shcore::os::{Fd, FileStat, OsError, OsResult, Pid, SigDisp, Signal};
use shcore::{Flow, Interp, ShellOs};
use sysroot as rt;

// shcore uses `alloc`; provide the same wasm allocator the kernel uses.
#[global_allocator]
static ALLOC: talc::wasm::WasmDynamicTalc = talc::wasm::new_wasm_dynamic_allocator();

// `sh` runs at whatever privilege it was launched with.
rt::declare_tier!("full");

const HELP: &str = "\
sh — the memcontainers shell

Usage: sh                     start an interactive shell (REPL)
       sh -c COMMAND [ARG]...  run COMMAND, then exit
       sh FILE [ARG]...        run the script in FILE with positional args

Runs the shcore engine: pipelines (`|`), redirections (`> >> < 2>`),
`$(command)` and `${var}` substitution, `&&` / `||` / `;`, `if`/`for`/`while`/
`case`, functions, and built-ins. There is no fork — subshells and command
substitution run in-process; blocking syscalls are made cooperative by the
kernel.

Notes (deviations from POSIX sh):
  - `--help`/`-h` are recognized only as the first argument.
  - The `set` option flags (-e/-u/-x/-o) are not accepted as CLI arguments;
    `$0` and the positional parameters are set from FILE and ARG... in script
    mode.

Exit status:
  the status of the last command run (or of COMMAND / the script).
";

/// `ShellOs` backed by the real kernel syscalls (via `sysroot`).
struct SysrootOs {
    interactive: bool,
}

impl ShellOs for SysrootOs {
    fn spawn(
        &mut self,
        argv: &[String],
        in_fd: Fd,
        out_fd: Fd,
        err_fd: Fd,
        tier: i32,
    ) -> OsResult<Pid> {
        let mut blob = Vec::new();
        for a in argv {
            blob.extend_from_slice(a.as_bytes());
            blob.push(0);
        }
        rt::spawn_tiered(&blob, in_fd, out_fd, err_fd, tier).map_err(OsError)
    }
    fn waitpid(&mut self, pid: Pid) -> OsResult<i32> {
        rt::waitpid(pid as i32).map_err(OsError)
    }
    fn try_wait_any(&mut self) -> OsResult<Option<(Pid, i32)>> {
        match rt::waitpid_nohang(-1) {
            Ok(Some((status, pid))) => Ok(Some((pid, status))),
            Ok(None) => Ok(None),
            Err(e) => Err(OsError(e)),
        }
    }
    fn getpid(&self) -> Pid {
        rt::getpid()
    }
    fn pipe(&mut self) -> OsResult<(Fd, Fd)> {
        rt::pipe().map_err(OsError)
    }
    fn dup(&mut self, fd: Fd) -> OsResult<Fd> {
        rt::dup(fd).map_err(OsError)
    }
    fn dup2(&mut self, old: Fd, new: Fd) -> OsResult<()> {
        rt::dup2(old, new).map_err(OsError)
    }
    fn close(&mut self, fd: Fd) {
        rt::close(fd);
    }
    fn open(&mut self, path: &str, flags: i32) -> OsResult<Fd> {
        rt::open(path, flags).map_err(OsError)
    }
    fn read(&mut self, fd: Fd, buf: &mut [u8]) -> OsResult<usize> {
        rt::read(fd, buf).map_err(OsError)
    }
    fn write_all(&mut self, fd: Fd, buf: &[u8]) -> OsResult<()> {
        rt::write_all(fd, buf).map_err(OsError)
    }
    fn readdir(&mut self, path: &str) -> OsResult<Vec<String>> {
        let mut cap = 1024usize;
        loop {
            let mut buf = vec![0u8; cap];
            match rt::readdir(path, &mut buf) {
                Ok(n) => {
                    if n == cap {
                        cap *= 2; // possibly truncated — grow and retry
                        continue;
                    }
                    let names = buf[..n]
                        .split(|&b| b == 0)
                        .filter(|s| !s.is_empty())
                        .map(|s| String::from_utf8_lossy(s).into_owned())
                        .collect();
                    return Ok(names);
                }
                Err(e) => return Err(OsError(e)),
            }
        }
    }
    fn stat(&mut self, path: &str) -> OsResult<FileStat> {
        match rt::stat(path) {
            Ok(s) => Ok(FileStat {
                is_dir: s.is_dir,
                size: s.size,
                mode: s.mode,
                mtime: s.mtime,
            }),
            Err(e) => Err(OsError(e)),
        }
    }
    fn mkdir(&mut self, path: &str) -> OsResult<()> {
        rt::mkdir(path).map_err(OsError)
    }
    fn unlink(&mut self, path: &str) -> OsResult<()> {
        rt::unlink(path).map_err(OsError)
    }
    fn getcwd(&mut self) -> OsResult<String> {
        let mut buf = [0u8; 4096];
        match rt::getcwd(&mut buf) {
            Ok(n) => Ok(String::from_utf8_lossy(&buf[..n]).into_owned()),
            Err(e) => Err(OsError(e)),
        }
    }
    fn chdir(&mut self, path: &str) -> OsResult<()> {
        rt::chdir(path).map_err(OsError)
    }
    fn bind(&mut self, old: &str, new: &str) -> OsResult<()> {
        rt::bind(old, new).map_err(OsError)
    }
    fn unmount(&mut self, path: &str) -> OsResult<()> {
        rt::unmount(path).map_err(OsError)
    }
    fn getenv(&mut self, name: &str) -> Option<String> {
        let p = format!("/env/{name}");
        let fd = rt::open(&p, rt::O_READ).ok()?;
        let mut v = Vec::new();
        let mut b = [0u8; 256];
        loop {
            match rt::read(fd, &mut b) {
                Ok(0) => break,
                Ok(n) => v.extend_from_slice(&b[..n]),
                Err(_) => break,
            }
        }
        rt::close(fd);
        Some(String::from_utf8_lossy(&v).into_owned())
    }
    fn setenv(&mut self, name: &str, val: &str) {
        let p = format!("/env/{name}");
        if let Ok(fd) = rt::open(&p, rt::O_WRITE | rt::O_CREATE | rt::O_TRUNC) {
            let _ = rt::write_all(fd, val.as_bytes());
            rt::close(fd);
        }
    }
    fn unsetenv(&mut self, name: &str) {
        let _ = rt::unlink(&format!("/env/{name}"));
    }
    fn environ(&mut self) -> Vec<String> {
        self.readdir("/env").unwrap_or_default()
    }
    // Signals / job control (§13): backed by the kernel's `mc_sys_*` signal
    // syscalls. `Signal` is `#[repr(i32)]` with the kernel's numbers, so the
    // cast is the wire value.
    fn kill(&mut self, pid: i32, sig: Signal) -> OsResult<()> {
        rt::kill(pid, sig as i32).map_err(OsError)
    }
    fn set_sigdisp(&mut self, sig: Signal, disp: SigDisp) {
        let d = match disp {
            SigDisp::Ignore => rt::SIG_IGN,
            SigDisp::Default => rt::SIG_DFL,
        };
        let _ = rt::sigdisp(sig as i32, d);
    }
    fn setpgid(&mut self, pid: Pid, pgid: Pid) -> OsResult<()> {
        rt::setpgid(pid as i32, pgid as i32).map_err(OsError)
    }
    fn set_foreground_pgid(&mut self, pgid: Pid) -> OsResult<()> {
        rt::tcsetpgrp(pgid as i32).map_err(OsError)
    }
    fn isatty(&self, fd: Fd) -> bool {
        self.interactive && fd == 0
    }
}

fn read_argv() -> Vec<String> {
    let mut buf = [0u8; 4096];
    let n = rt::args_into(&mut buf);
    buf[..n]
        .split(|&b| b == 0)
        .filter(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .collect()
}

fn read_file(path: &str) -> Option<String> {
    let fd = rt::open(path, rt::O_READ).ok()?;
    let mut content = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match rt::read(fd, &mut buf) {
            Ok(0) => break,
            Ok(n) => content.extend_from_slice(&buf[..n]),
            Err(_) => break,
        }
    }
    rt::close(fd);
    Some(String::from_utf8_lossy(&content).into_owned())
}

/// Outcome of reading one interactive line.
enum LineRead {
    Line(String),
    Eof,
    /// A signal (Ctrl-C) interrupted the read — abort the current line.
    Interrupted,
}

/// Read one line from stdin (cooked TTY delivers whole lines). `Eof` at end of
/// input; `Interrupted` when a signal (Ctrl-C → `EINTR`) breaks the read.
fn read_line() -> LineRead {
    let mut v: Vec<u8> = Vec::new();
    let mut b = [0u8; 1];
    loop {
        match rt::read(rt::STDIN, &mut b) {
            Ok(0) => {
                if v.is_empty() {
                    return LineRead::Eof;
                }
                return LineRead::Line(String::from_utf8_lossy(&v).into_owned());
            }
            Ok(_) => {
                if b[0] == b'\n' {
                    return LineRead::Line(String::from_utf8_lossy(&v).into_owned());
                }
                if b[0] != b'\r' {
                    v.push(b[0]);
                }
            }
            Err(rt::EINTR) => return LineRead::Interrupted,
            Err(_) => return LineRead::Eof,
        }
    }
}

fn exit_code(flow: Flow, status: i32) -> i32 {
    match flow {
        Flow::Exit(c) => c,
        _ => status,
    }
}

fn repl<O: ShellOs>(sh: &mut Interp<O>) {
    let mut buf = String::new();
    rt::print("$ ");
    loop {
        match read_line() {
            LineRead::Eof => {
                if buf.trim().is_empty() {
                    rt::print("\n");
                    break;
                }
                // EOF mid-command: run what we have, then exit.
                let f = sh.run(&buf);
                let _ = exit_code(f, sh.last_status());
                break;
            }
            LineRead::Interrupted => {
                // Ctrl-C: abandon the current (possibly multi-line) input and
                // start fresh. The kernel already echoed `^C\n`.
                buf.clear();
                rt::print("$ ");
                continue;
            }
            LineRead::Line(line) => {
                buf.push_str(&line);
                buf.push('\n');
            }
        }
        // Wait for a complete command before executing (multi-line constructs).
        if let Err(shcore::parser::ParseError::Incomplete(_)) = shcore::parser::parse(&buf)
        {
            rt::print("> ");
            continue;
        }
        let flow = sh.run(&buf);
        buf.clear();
        if let Flow::Exit(_) = flow {
            break;
        }
        rt::print("$ ");
    }
}

fn main() {
    let argv = read_argv();
    // Help, only as the first argument so `-c '… --help …'` and a script named
    // oddly are never shadowed.
    if matches!(argv.get(1).map(String::as_str), Some("--help") | Some("-h")) {
        rt::emit_help(HELP);
    }
    // Mode selection.
    enum Mode {
        Command(String, Vec<String>),
        Script(String, Vec<String>),
        Interactive,
    }
    let mode = if argv.len() >= 2 && argv[1] == "-c" {
        let cmd = argv.get(2).cloned().unwrap_or_default();
        let rest = if argv.len() > 3 {
            argv[3..].to_vec()
        } else {
            Vec::new()
        };
        Mode::Command(cmd, rest)
    } else if argv.len() >= 2 {
        Mode::Script(argv[1].clone(), argv[2..].to_vec())
    } else {
        Mode::Interactive
    };

    let interactive = matches!(mode, Mode::Interactive);
    let mut os = SysrootOs { interactive };
    if interactive {
        // An interactive shell ignores the terminal stop/interrupt signals for
        // itself so Ctrl-C / Ctrl-Z act on the foreground job, not the shell.
        // Its blocked console read then takes EINTR and redraws the prompt.
        os.set_sigdisp(Signal::Int, SigDisp::Ignore);
        os.set_sigdisp(Signal::Tstp, SigDisp::Ignore);
    }
    let mut sh = Interp::new(&mut os);

    let code = match mode {
        Mode::Command(cmd, mut rest) => {
            // POSIX `sh -c cmd [name [args…]]`: first operand is $0, rest are $1…
            if !rest.is_empty() {
                sh.set_arg0(&rest.remove(0));
                sh.set_positional(rest);
            }
            let f = sh.run(&cmd);
            exit_code(f, sh.last_status())
        }
        Mode::Script(path, args) => {
            sh.set_arg0(&path);
            sh.set_positional(args);
            match read_file(&path) {
                Some(src) => {
                    let f = sh.run(&src);
                    exit_code(f, sh.last_status())
                }
                None => {
                    rt::eprint(&format!("sh: cannot open {path}\n"));
                    127
                }
            }
        }
        Mode::Interactive => {
            repl(&mut sh);
            sh.last_status()
        }
    };
    rt::exit(code);
}

rt::entry!(main);
