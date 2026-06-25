//! `exec` builtins — the in-process commands (`cd`/`export`/`echo`/`printf`/`test`/…).
//!
//! These are methods on `Interp`, split out of `exec/mod.rs` for navigability (Rust
//! lets one type's impl span several files). The carry-both core set delegates to the
//! shared `crate::{echo, printf, testexpr}` modules rather than carrying its own copy.

use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

use constants_rust as abi;

use crate::expand::ExpandCtx;
use crate::os::*;

use super::{errno_str, Flow, Interp, Triple, VarVal};

impl<'o, O: ShellOs> Interp<'o, O> {
    // ================= builtins =================

    pub(crate) fn run_builtin_with_redirs(
        &mut self,
        name: &str,
        argv: &[String],
        triple: Triple,
    ) -> (i32, Option<Flow>) {
        // Run the builtin with the redirected fd triple in effect.
        let mut control: Option<Flow> = None;
        let mut status = 0;
        let argv = argv.to_vec();
        let name = name.to_string();
        self.run_with_fds(triple, |me| {
            let (s, c) = me.dispatch_builtin(&name, &argv);
            status = s;
            control = c;
            Flow::Normal
        });
        (status, control)
    }

    fn dispatch_builtin(&mut self, name: &str, argv: &[String]) -> (i32, Option<Flow>) {
        let args = &argv[1..];
        // `--help`/`-h` as the FIRST argument prints the builtin's help to stdout
        // and succeeds, before any side effect — so the shell surface is as
        // self-describing as the `/bin` tools (an agent typing `echo --help` at
        // the prompt hits this builtin, not `/bin/echo`). First-arg only, so a
        // wrapped command's own flags pass through (`command ls --help`).
        if matches!(args.first().map(String::as_str), Some("--help") | Some("-h")) {
            if let Some(help) = builtin_help(name) {
                let o = self.cur_out();
                self.write_fd(o, help);
                return (0, None);
            }
        }
        match name {
            // `:` is a shell special builtin (no `/bin` twin). The rest of this
            // group — true/false/echo/pwd/printf/test/[/kill — are the POSIX
            // "carry-both" core set: each ALSO ships as a `/bin` twin under
            // programs/, and must behave identically. echo/printf/test achieve that
            // by sharing crate::{echo,printf,testexpr}; the others are small enough
            // to mirror directly.
            ":" | "true" => (0, None),
            "false" => (1, None),
            "echo" => (self.bi_echo(args), None),
            "pwd" => (self.bi_pwd(), None),
            "printf" => (self.bi_printf(args), None),
            "cd" => (self.bi_cd(args), None),
            "export" => (self.bi_export(args), None),
            "unset" => (self.bi_unset(args), None),
            "shift" => (self.bi_shift(args), None),
            "set" => (self.bi_set(args), None),
            "read" => (self.bi_read(args), None),
            "test" | "[" => (self.bi_test(name, args), None),
            "umount" => (self.bi_umount(args), None),
            "bind" => (self.bi_bind(args), None),
            "exit" => {
                let code = args
                    .first()
                    .and_then(|s| s.parse::<i32>().ok())
                    .unwrap_or(self.last_status);
                (code, Some(Flow::Exit(code)))
            }
            "return" => {
                let code = args
                    .first()
                    .and_then(|s| s.parse::<i32>().ok())
                    .unwrap_or(self.last_status);
                (code, Some(Flow::Return(code)))
            }
            "break" => {
                let n = args
                    .first()
                    .and_then(|s| s.parse::<u32>().ok())
                    .unwrap_or(1)
                    .max(1);
                (0, Some(Flow::Break(n)))
            }
            "continue" => {
                let n = args
                    .first()
                    .and_then(|s| s.parse::<u32>().ok())
                    .unwrap_or(1)
                    .max(1);
                (0, Some(Flow::Continue(n)))
            }
            "." | "source" => (self.bi_source(args), None),
            "eval" => {
                let joined = args.join(" ");
                let f = self.run(&joined);
                (
                    self.last_status,
                    if f == Flow::Normal { None } else { Some(f) },
                )
            }
            "local" => (self.bi_local(args), None),
            "command" => {
                // `command cmd args` — bypass functions; v1: just run as a fresh
                // simple command via eval of the remaining args.
                if args.is_empty() {
                    (0, None)
                } else {
                    let joined = args.join(" ");
                    let f = self.run(&joined);
                    (
                        self.last_status,
                        if f == Flow::Normal { None } else { Some(f) },
                    )
                }
            }
            "jobs" => (self.bi_jobs(), None),
            "fg" => (self.bi_fg(args), None),
            "bg" => (self.bi_bg(args), None),
            "wait" => (self.bi_wait(args), None),
            "kill" => (self.bi_kill(args), None),
            _ => {
                self.eprintln(&format!("sh: {name}: not a builtin"));
                (1, None)
            }
        }
    }

    // Carry-both core set: the `echo` builtin and `/bin/echo` share their rendering
    // via `crate::echo`, so there is no hand-synced second copy. The builtin only
    // writes the produced bytes to its current stdout.
    fn bi_echo(&mut self, args: &[String]) -> i32 {
        let bytes = crate::echo::render(args);
        let o = self.cur_out();
        self.emit(o, &bytes);
        0
    }

    // Carry-both core set: the twin of `/bin/pwd` (programs/). Keep the output
    // (path + LF) identical between the two.
    fn bi_pwd(&mut self) -> i32 {
        let cwd = self.os.getcwd().unwrap_or_else(|_| "/".to_string());
        let o = self.cur_out();
        self.write_fd(o, &cwd);
        self.write_fd(o, "\n");
        0
    }

    // Carry-both core set: the `printf` builtin and `/bin/printf` share one formatting
    // engine via `crate::printf`, so there is no byte-for-byte second copy to keep in
    // sync. `args` is argv[1..], so args[0] is FORMAT — required, like `/bin/printf`.
    fn bi_printf(&mut self, args: &[String]) -> i32 {
        if args.is_empty() {
            self.eprintln("printf: usage: printf FORMAT [ARG...]");
            return 1;
        }
        let fmt = args[0].as_bytes();
        let rest: Vec<&[u8]> = args[1..].iter().map(|s| s.as_bytes()).collect();
        let (out, err) = crate::printf::render(fmt, &rest);
        let o = self.cur_out();
        self.emit(o, &out);
        if err {
            1
        } else {
            0
        }
    }

    fn bi_cd(&mut self, args: &[String]) -> i32 {
        let prev = self.os.getcwd().unwrap_or_default();
        let mut print_dir = false;
        let target = match args.first().map(|s| s.as_str()) {
            Some("-") => {
                // `cd -`: return to OLDPWD and echo the directory (POSIX).
                print_dir = true;
                match self.get("OLDPWD") {
                    Some(p) if !p.is_empty() => p,
                    _ => {
                        self.eprintln("cd: OLDPWD not set");
                        return 1;
                    }
                }
            }
            Some(a) => a.to_string(),
            None => self.get("HOME").unwrap_or_else(|| "/".to_string()),
        };
        match self.os.chdir(&target) {
            Ok(()) => {
                // OLDPWD ← where we were; PWD ← where we are now.
                self.set_var_raw("OLDPWD", &prev);
                if let Ok(cwd) = self.os.getcwd() {
                    self.set_var_raw("PWD", &cwd);
                    if print_dir {
                        let o = self.cur_out();
                        self.write_fd(o, &cwd);
                        self.write_fd(o, "\n");
                    }
                }
                0
            }
            Err(e) => {
                self.eprintln(&format!("cd: {target}: {}", errno_str(e.0)));
                1
            }
        }
    }

    fn bi_export(&mut self, args: &[String]) -> i32 {
        if args.is_empty() {
            // list exported vars
            let names: Vec<String> = self
                .vars
                .iter()
                .filter(|(_, v)| v.exported)
                .map(|(k, v)| format!("export {k}={}", v.value))
                .collect();
            let o = self.cur_out();
            for n in names {
                self.write_fd(o, &n);
                self.write_fd(o, "\n");
            }
            return 0;
        }
        for a in args {
            if let Some((name, val)) = a.split_once('=') {
                self.export_var(name, Some(val));
            } else {
                self.export_var(a, None);
            }
        }
        0
    }

    fn bi_unset(&mut self, args: &[String]) -> i32 {
        for a in args {
            if a == "-f" || a == "-v" {
                continue;
            }
            self.unset_var(a);
        }
        0
    }

    fn bi_shift(&mut self, args: &[String]) -> i32 {
        let n = args
            .first()
            .and_then(|s| s.parse::<usize>().ok())
            .unwrap_or(1);
        if n > self.positional.len() {
            return 1;
        }
        self.positional.drain(0..n);
        0
    }

    fn bi_set(&mut self, args: &[String]) -> i32 {
        let mut i = 0;
        let mut saw_dashdash = false;
        while i < args.len() {
            let a = &args[i];
            if a == "--" {
                saw_dashdash = true;
                i += 1;
                break;
            }
            if let Some(flags) = a.strip_prefix('-') {
                if a == "-" {
                    break;
                }
                if flags == "o" {
                    if let Some(opt) = args.get(i + 1) {
                        self.set_named_option(opt, true);
                        i += 2;
                        continue;
                    }
                }
                for f in flags.chars() {
                    self.set_short_option(f, true);
                }
                i += 1;
                continue;
            }
            if let Some(flags) = a.strip_prefix('+') {
                if flags == "o" {
                    if let Some(opt) = args.get(i + 1) {
                        self.set_named_option(opt, false);
                        i += 2;
                        continue;
                    }
                }
                for f in flags.chars() {
                    self.set_short_option(f, false);
                }
                i += 1;
                continue;
            }
            break;
        }
        if saw_dashdash || i < args.len() {
            self.positional = args[i..].to_vec();
        }
        0
    }

    fn set_short_option(&mut self, f: char, on: bool) {
        match f {
            'e' => self.opts.errexit = on,
            'u' => self.opts.nounset = on,
            'x' => self.opts.xtrace = on,
            _ => {}
        }
    }
    fn set_named_option(&mut self, name: &str, on: bool) {
        match name {
            "errexit" => self.opts.errexit = on,
            "nounset" => self.opts.nounset = on,
            "xtrace" => self.opts.xtrace = on,
            "pipefail" => self.opts.pipefail = on,
            _ => {}
        }
    }

    fn bi_read(&mut self, args: &[String]) -> i32 {
        // read [var...] — read a line from stdin, split on IFS into vars.
        let mut line = Vec::new();
        let mut byte = [0u8; 1];
        let infd = self.cur_in();
        loop {
            match self.os.read(infd, &mut byte) {
                Ok(0) => {
                    if line.is_empty() {
                        return 1; // EOF
                    }
                    break;
                }
                Ok(_) => {
                    if byte[0] == b'\n' {
                        break;
                    }
                    if byte[0] != b'\r' {
                        line.push(byte[0]);
                    }
                }
                Err(_) => return 1,
            }
        }
        let text = String::from_utf8_lossy(&line).into_owned();
        let names: Vec<&String> = args.iter().filter(|a| !a.starts_with('-')).collect();
        if names.is_empty() {
            self.set_var_raw("REPLY", &text);
            return 0;
        }
        let ifs = self.ifs();
        let ifs_chars: Vec<char> = ifs.chars().collect();
        let fields: Vec<&str> = text
            .split(|c: char| ifs_chars.contains(&c))
            .filter(|s| !s.is_empty())
            .collect();
        for (idx, name) in names.iter().enumerate() {
            if idx + 1 == names.len() {
                // last var gets the remainder
                let rest = fields[idx..].join(" ");
                self.set_var_raw(name, &rest);
            } else {
                self.set_var_raw(name, fields.get(idx).copied().unwrap_or(""));
            }
        }
        0
    }

    fn bi_source(&mut self, args: &[String]) -> i32 {
        let path = match args.first() {
            Some(p) => p.clone(),
            None => {
                self.eprintln("source: filename argument required");
                return 1;
            }
        };
        let full = self.resolve_path(&path).unwrap_or(path.clone());
        let fd = match self.os.open(&full, O_READ) {
            Ok(f) => f,
            Err(_) => {
                self.eprintln(&format!("source: {path}: cannot open"));
                return 1;
            }
        };
        let mut content = Vec::new();
        let mut buf = [0u8; 4096];
        while let Ok(n) = self.os.read(fd, &mut buf) {
            if n == 0 {
                break;
            }
            content.extend_from_slice(&buf[..n]);
        }
        self.os.close(fd);
        let src = String::from_utf8_lossy(&content).into_owned();
        let f = self.run(&src);
        let _ = f;
        self.last_status
    }

    fn bi_local(&mut self, args: &[String]) -> i32 {
        if self.frames.is_empty() {
            self.eprintln("local: can only be used in a function");
            return 1;
        }
        for a in args {
            let (name, val) = match a.split_once('=') {
                Some((n, v)) => (n.to_string(), Some(v.to_string())),
                None => (a.clone(), None),
            };
            let prev = self.vars.get(&name).cloned();
            if let Some(frame) = self.frames.last_mut() {
                frame.locals.push((name.clone(), prev));
            }
            match val {
                Some(v) => self.set_var_raw(&name, &v),
                None => {
                    self.vars.insert(
                        name,
                        VarVal {
                            value: String::new(),
                            exported: false,
                        },
                    );
                }
            }
        }
        0
    }

    fn bi_umount(&mut self, args: &[String]) -> i32 {
        let path = match args.first() {
            Some(p) => p.clone(),
            None => {
                self.eprintln("umount: missing operand");
                return 1;
            }
        };
        match self.os.unmount(&path) {
            Ok(()) => 0,
            Err(e) => {
                // ENOTEMPTY means a child mount still exists → "busy".
                let reason = if e.0 == abi::ENOTEMPTY {
                    "target is busy".to_string()
                } else {
                    errno_str(e.0)
                };
                self.eprintln(&format!("umount: {path}: {reason}"));
                1
            }
        }
    }

    fn bi_bind(&mut self, args: &[String]) -> i32 {
        if args.len() < 2 {
            self.eprintln("bind: usage: bind OLD NEW");
            return 1;
        }
        match self.os.bind(&args[0], &args[1]) {
            Ok(()) => 0,
            Err(e) => {
                self.eprintln(&format!("bind: {}: {}", args[1], errno_str(e.0)));
                1
            }
        }
    }

    // Carry-both core set: the `test`/`[` builtin and `/bin/test` share their grammar
    // via `crate::testexpr`, which takes a `stat` closure so the pure logic stays
    // OS-free. The builtin supplies a closure over `ShellOs::stat`; `testexpr::eval`
    // already returns the correctly-prefixed error message (`test:` / `[:`).
    fn bi_test(&mut self, name: &str, args: &[String]) -> i32 {
        let result = {
            let mut stat = |p: &str| self.os.stat(p).ok();
            crate::testexpr::eval(name, args, &mut stat)
        };
        match result {
            Ok(true) => 0,
            Ok(false) => 1,
            Err(m) => {
                self.eprintln(&m);
                2
            }
        }
    }
}

fn builtin_help(name: &str) -> Option<&'static str> {
    let h = match name {
        ":" => "\
: — the null command; expand arguments and return success (exit 0).\n\
\n\
Usage: : [ARG]...\n",
        "true" => "true — do nothing, successfully (exit 0).\n\nUsage: true\n",
        "false" => "false — do nothing, unsuccessfully (exit 1).\n\nUsage: false\n",
        "echo" => "\
echo — print arguments separated by spaces, then a newline.\n\
\n\
Usage: echo [-neE] [ARG]...\n\
\n\
Options:\n\
  -n  do not output the trailing newline\n\
  -e  interpret backslash escapes (\\n \\t \\r \\\\ \\0 \\a \\b \\f \\v \\c)\n\
  -E  do not interpret backslash escapes (default)\n\
\n\
Only leading -neE tokens are options (POSIX/XSI echo). Same as /bin/echo.\n",
        "pwd" => "pwd — print the current working directory.\n\nUsage: pwd\n",
        "printf" => "\
printf — format and print arguments under FORMAT.\n\
\n\
Usage: printf FORMAT [ARG]...\n\
\n\
Supports %s %b %c %d %i %u %o %x %X %% with flags (- + space 0 #), width, and\n\
.precision (each may be * from an argument), plus backslash escapes. FORMAT is\n\
reused while arguments remain. Float conversions (%f/%e/%g) pass through. Same\n\
as /bin/printf.\n",
        "test" | "[" => "\
test — evaluate a conditional expression; exit 0 (true) or 1 (false).\n\
\n\
Usage: test EXPR\n\
       [ EXPR ]\n\
\n\
Primaries: file tests -e -f -d -r -w -x -s; string -z -n = !=; integer -eq -ne\n\
-lt -le -gt -ge; with ! negation, -a/-o connectives, and ( ) grouping. Same as\n\
/bin/test. `[` requires a closing `]`.\n",
        "kill" => "\
kill — send a signal (default TERM) to jobs or process ids.\n\
\n\
Usage: kill [-s SIGNAL | -SIGNAL] {JOB | PID}...\n\
       kill -l [SPEC]\n\
\n\
JOB is a %jobspec from the shell's job table; a PID (negative = process group)\n\
also works. SIGNAL is a name (TERM, KILL, INT, ... with or without SIG) or a\n\
number. -l lists signal names or converts a SPEC.\n",
        "cd" => "\
cd — change the current working directory.\n\
\n\
Usage: cd [DIR]\n\
\n\
With no DIR, change to $HOME. `cd -` returns to the previous directory ($OLDPWD).\n",
        "export" => "\
export — mark variables for export to child processes.\n\
\n\
Usage: export NAME[=VALUE]...\n\
\n\
Sets NAME (optionally to VALUE) in the environment inherited by spawned commands.\n",
        "unset" => "\
unset — remove shell variables.\n\
\n\
Usage: unset NAME...\n",
        "set" => "\
set — set shell options and the positional parameters.\n\
\n\
Usage: set [-eux] [-o OPTION] [--] [ARG]...\n\
       set +eux\n\
\n\
Options: -e errexit, -u nounset, -x xtrace (use + to disable). With ARG...,\n\
replace the positional parameters $1, $2, ... With no arguments, list variables.\n",
        "shift" => "\
shift — shift the positional parameters left.\n\
\n\
Usage: shift [N]\n\
\n\
Renames $(N+1)... to $1...; N defaults to 1.\n",
        "read" => "\
read — read one line from standard input into variables.\n\
\n\
Usage: read [-r] NAME...\n\
\n\
Splits the line on $IFS across NAME...; the last NAME gets the remainder. -r\n\
disables backslash escaping. Returns nonzero at end of input.\n",
        "." | "source" => "\
source — run a script in the current shell (no new process).\n\
\n\
Usage: . FILE [ARG]...\n\
       source FILE [ARG]...\n\
\n\
Variables and functions it defines persist. ARG... become its positional\n\
parameters.\n",
        "eval" => "\
eval — concatenate arguments and run the result as a command.\n\
\n\
Usage: eval [ARG]...\n",
        "local" => "\
local — declare variables local to the current function.\n\
\n\
Usage: local NAME[=VALUE]...\n",
        "command" => "\
command — run a command, bypassing shell functions.\n\
\n\
Usage: command COMMAND [ARG]...\n",
        "exit" => "exit — exit the shell with a status.\n\nUsage: exit [N]\n",
        "return" => "\
return — return from a function or sourced script with a status.\n\
\n\
Usage: return [N]\n",
        "break" => "break — exit a for/while loop.\n\nUsage: break [N]\n",
        "continue" => "\
continue — resume the next iteration of a for/while loop.\n\
\n\
Usage: continue [N]\n",
        "jobs" => "jobs — list active jobs.\n\nUsage: jobs\n",
        "fg" => "fg — resume a job in the foreground.\n\nUsage: fg [%JOB]\n",
        "bg" => "bg — resume a job in the background.\n\nUsage: bg [%JOB]\n",
        "wait" => "\
wait — wait for background jobs to finish.\n\
\n\
Usage: wait [%JOB | PID]...\n",
        "umount" => "\
umount — unmount a filesystem mounted at a path.\n\
\n\
Usage: umount MOUNTPOINT\n",
        "bind" => "\
bind — bind-mount one path onto another.\n\
\n\
Usage: bind OLD NEW\n\
\n\
Makes NEW resolve to the same filesystem location as OLD.\n",
        _ => return None,
    };
    Some(h)
}
