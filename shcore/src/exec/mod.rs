//! The blocking, tree-walking executor.
//!
//! `Interp` owns shell state (variables, functions, positional params, options, the
//! job table) and runs the AST over a [`ShellOs`]. It is written in straight-line
//! BLOCKING style: the kernel turns a blocking syscall (`waitpid`/`read`) into
//! cooperative suspension (§4.4), so the executor needs no async or hand-rolled state
//! machine. There is no `fork`, so subshells and command substitution run in-process
//! with snapshot/restore rather than a second address space.
//!
//! The open-flag and errno constants come from the generated contract
//! (`//contracts:constants_rust`, via `os::*` and `abi::*`) — the single source of
//! truth (B2); nothing here re-declares an ABI value.

use alloc::collections::BTreeMap;
use alloc::format;
use alloc::rc::Rc;
use alloc::string::{String, ToString};
use alloc::vec;
use alloc::vec::Vec;

use constants_rust as abi;

use crate::ast::*;
use crate::expand::{expand_redirect_target, expand_to_fields, expand_to_string, ExpandCtx};
// Brings in the ShellOs trait, the Fd/Pid types, STDIN/OUT/ERR, TIER_INHERIT,
// STOPPED_STATUS, and the O_* open flags — all rooted in the contract (os.rs).
use crate::os::*;
use crate::parser::{parse, ParseError};
use crate::word::Word;

/// Virtual stdout fd for an in-flight command substitution: `fd = CAPTURE_FD_BASE -
/// index`. Real kernel fds are >= 0, so these can never collide with one.
const CAPTURE_FD_BASE: Fd = -1000;

mod builtins;
mod job;

#[derive(Clone)]
struct VarVal {
    value: String,
    exported: bool,
}

#[derive(Clone, Default)]
pub struct Options {
    pub errexit: bool,  // set -e
    pub nounset: bool,  // set -u
    pub xtrace: bool,   // set -x
    pub pipefail: bool, // set -o pipefail
}

struct Frame {
    saved_positional: Vec<String>,
    saved_arg0: String,
    /// (name, previous VarVal or None) to restore on function return.
    locals: Vec<(String, Option<VarVal>)>,
}

/// Non-local control flow bubbling up through the tree walk.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flow {
    Normal,
    Break(u32),
    Continue(u32),
    Return(i32),
    Exit(i32),
}

struct Job {
    id: u32,
    pids: Vec<Pid>,
    cmd: String,
    /// Live (not yet reaped). A stopped job is still `running == true`.
    running: bool,
    /// Suspended by SIGTSTP (Ctrl-Z or `kill -STOP`); resumed by `fg`/`bg`.
    stopped: bool,
}

/// Outcome of waiting on a foreground child: it exited (with a status) or it
/// stopped (SIGTSTP / Ctrl-Z), which hands control back to the shell.
pub(crate) enum FgWait {
    Exited(i32),
    Stopped,
}

pub struct Interp<'o, O: ShellOs> {
    os: &'o mut O,
    vars: BTreeMap<String, VarVal>,
    funcs: BTreeMap<String, Rc<Command>>,
    positional: Vec<String>,
    arg0: String,
    frames: Vec<Frame>,
    pub opts: Options,
    last_status: i32,
    last_bg: Option<Pid>,
    shell_pid: Pid,
    /// The current [stdin, stdout, stderr] fd numbers for the running context.
    /// The executor routes I/O through these instead of `dup2`-ing onto fds
    /// 0/1/2 — this kernel fixes a guest's std streams at spawn time, so an
    /// in-process builtin/compound writes to `cur_fds[1]` directly while an
    /// external command receives the triple via `spawn`.
    cur_fds: [Fd; 3],
    jobs: Vec<Job>,
    next_job: u32,
    tmp_seq: u32,
    /// In-flight command-substitution sinks. `$(...)` pushes an in-memory buffer and
    /// points its stdout at a virtual capture fd, so builtin output is collected with
    /// no filesystem round-trip; an external child (which can't take a virtual fd) is
    /// spliced in via a temp file (see `dispatch_simple`). A stack, so nested
    /// substitutions nest correctly.
    captures: Vec<Vec<u8>>,
    subshell_depth: u32,
    /// Whether the last and-or list's failure should trigger `set -e`.
    errexit_eligible: bool,
}

impl<'o, O: ShellOs> Interp<'o, O> {
    pub fn new(os: &'o mut O) -> Self {
        let shell_pid = os.getpid();
        let mut vars = BTreeMap::new();
        // Seed from the environment (/env): everything there is exported.
        for name in os.environ() {
            if let Some(value) = os.getenv(&name) {
                vars.insert(
                    name,
                    VarVal {
                        value,
                        exported: true,
                    },
                );
            }
        }
        // Sensible defaults if the environment didn't provide them.
        if !vars.contains_key("IFS") {
            vars.insert(
                "IFS".to_string(),
                VarVal {
                    value: " \t\n".to_string(),
                    exported: false,
                },
            );
        }
        let _ = os.mkdir("/tmp"); // for command-substitution / heredoc temp files
        Interp {
            os,
            vars,
            funcs: BTreeMap::new(),
            positional: Vec::new(),
            arg0: "sh".to_string(),
            frames: Vec::new(),
            opts: Options::default(),
            last_status: 0,
            last_bg: None,
            shell_pid,
            cur_fds: [STDIN, STDOUT, STDERR],
            jobs: Vec::new(),
            next_job: 1,
            tmp_seq: 0,
            captures: Vec::new(),
            subshell_depth: 0,
            errexit_eligible: false,
        }
    }

    pub fn set_positional(&mut self, args: Vec<String>) {
        self.positional = args;
    }
    pub fn set_arg0(&mut self, name: &str) {
        self.arg0 = name.to_string();
    }
    pub fn last_status(&self) -> i32 {
        self.last_status
    }

    /// Parse and execute a complete source string. Returns the resulting flow
    /// (so the REPL can act on `exit`). `Incomplete` is reported as a syntax
    /// error here; interactive callers should pre-check completeness.
    pub fn run(&mut self, src: &str) -> Flow {
        match parse(src) {
            Ok(script) => self.exec_list(&script.list),
            Err(ParseError::Incomplete(m)) | Err(ParseError::Syntax(m)) => {
                self.eprintln(&format!("sh: syntax error: {m}"));
                self.last_status = 2;
                Flow::Normal
            }
        }
    }

    // ================= variables / environment =================

    fn get_var(&self, name: &str) -> Option<String> {
        self.vars.get(name).map(|v| v.value.clone())
    }
    fn set_var_raw(&mut self, name: &str, val: &str) {
        let exported = self.vars.get(name).map(|v| v.exported).unwrap_or(false);
        self.vars.insert(
            name.to_string(),
            VarVal {
                value: val.to_string(),
                exported,
            },
        );
        if exported {
            self.os.setenv(name, val);
        }
    }
    fn export_var(&mut self, name: &str, val: Option<&str>) {
        let value = match val {
            Some(v) => v.to_string(),
            None => self
                .vars
                .get(name)
                .map(|v| v.value.clone())
                .unwrap_or_default(),
        };
        self.vars.insert(
            name.to_string(),
            VarVal {
                value: value.clone(),
                exported: true,
            },
        );
        self.os.setenv(name, &value);
    }
    fn unset_var(&mut self, name: &str) {
        if let Some(v) = self.vars.remove(name) {
            if v.exported {
                self.os.unsetenv(name);
            }
        }
        self.funcs.remove(name);
    }

    // ================= output helpers =================

    /// Write bytes to `fd`, which may be a virtual capture fd (`$(...)` collects into
    /// an in-memory buffer) or a real kernel fd. ALL in-process output flows through
    /// here, so command substitution captures it without a filesystem round-trip.
    fn emit(&mut self, fd: Fd, bytes: &[u8]) {
        match self.capture_index(fd) {
            Some(idx) => {
                if let Some(buf) = self.captures.get_mut(idx) {
                    buf.extend_from_slice(bytes);
                }
            }
            None => {
                let _ = self.os.write_all(fd, bytes);
            }
        }
    }
    fn write_fd(&mut self, fd: Fd, s: &str) {
        self.emit(fd, s.as_bytes());
    }
    /// Builtin stdout / stderr for the current context.
    fn cur_out(&self) -> Fd {
        self.cur_fds[1]
    }
    fn cur_in(&self) -> Fd {
        self.cur_fds[0]
    }
    fn eprintln(&mut self, s: &str) {
        let efd = self.cur_fds[2];
        self.emit(efd, s.as_bytes());
        self.emit(efd, b"\n");
    }

    // ================= command-substitution capture =================

    /// If `fd` is a virtual capture fd, the index of its buffer in `self.captures`.
    fn capture_index(&self, fd: Fd) -> Option<usize> {
        if fd <= CAPTURE_FD_BASE {
            Some((CAPTURE_FD_BASE - fd) as usize)
        } else {
            None
        }
    }
    fn capture_fd(idx: usize) -> Fd {
        CAPTURE_FD_BASE - idx as Fd
    }
    /// Splice a temp file's contents into capture buffer `idx`, then remove it — folds
    /// an external child's output (which had to go to a real fd) into the in-memory
    /// sink, in order.
    fn drain_capture_file(&mut self, path: &str, idx: usize) {
        if let Ok(rfd) = self.os.open(path, O_READ) {
            let mut buf = [0u8; 4096];
            while let Ok(n) = self.os.read(rfd, &mut buf) {
                if n == 0 {
                    break;
                }
                if let Some(b) = self.captures.get_mut(idx) {
                    b.extend_from_slice(&buf[..n]);
                }
            }
            self.os.close(rfd);
        }
        let _ = self.remove_tmp(path);
    }

    // ================= list / and-or / pipeline =================

    pub fn exec_list(&mut self, list: &List) -> Flow {
        let mut flow = Flow::Normal;
        for item in &list.items {
            match item.sep {
                ListSep::Async => {
                    self.exec_and_or_async(&item.and_or);
                }
                ListSep::Seq => {
                    flow = self.exec_and_or(&item.and_or);
                    if flow != Flow::Normal {
                        return flow;
                    }
                    if self.opts.errexit && self.errexit_eligible {
                        return Flow::Exit(self.last_status);
                    }
                }
            }
        }
        flow
    }

    fn exec_and_or(&mut self, ao: &AndOr) -> Flow {
        // `set -e` triggers only if the *rightmost* pipeline that executed
        // failed (a failing left operand of `&&`/`||` is exempt — POSIX).
        let mut executed_last = ao.rest.is_empty();
        let f = self.exec_pipeline(&ao.first);
        if f != Flow::Normal {
            return f;
        }
        for (idx, (op, pl)) in ao.rest.iter().enumerate() {
            let run = match op {
                AndOrOp::And => self.last_status == 0,
                AndOrOp::Or => self.last_status != 0,
            };
            if run {
                let f = self.exec_pipeline(pl);
                if f != Flow::Normal {
                    return f;
                }
                executed_last = idx == ao.rest.len() - 1;
            } else {
                executed_last = false;
            }
        }
        self.errexit_eligible = executed_last && self.last_status != 0;
        Flow::Normal
    }

    fn exec_and_or_async(&mut self, ao: &AndOr) {
        // Background: only meaningful for an external pipeline. We start its
        // commands without waiting and record a job. In-process/compound async
        // degrades to synchronous (no fork to background an in-process body).
        let pids = self.start_pipeline_background(&ao.first);
        if !pids.is_empty() {
            // Put the background job in its own process group so a later Ctrl-C
            // (which targets the *foreground* group) never reaches it.
            if self.job_control() {
                let grp = pids[0];
                for &p in &pids {
                    let _ = self.os.setpgid(p, grp);
                }
            }
            let id = self.next_job;
            self.next_job += 1;
            self.last_bg = pids.last().copied();
            let cmd = "background".to_string();
            self.jobs.push(Job {
                id,
                pids: pids.clone(),
                cmd,
                running: true,
                stopped: false,
            });
            // Job-control notice `[job] pid` — to stdout so the prompt and the
            // marker share a stream (the harness observes stdout).
            let o = self.cur_out();
            let marker = format!("[{}] {}\n", id, pids.last().copied().unwrap_or(0));
            self.write_fd(o, &marker);
            self.last_status = 0;
        } else {
            // ran synchronously (degraded)
        }
    }

    fn exec_pipeline(&mut self, pl: &Pipeline) -> Flow {
        let n = pl.cmds.len();
        let flow = if n == 1 {
            let base = self.cur_fds;
            self.exec_command(&pl.cmds[0], base)
        } else {
            self.exec_multi_pipeline(pl)
        };
        if pl.bang {
            self.last_status = if self.last_status == 0 { 1 } else { 0 };
        }
        flow
    }

    /// Run one in-process pipeline stage as a real subshell: snapshot shell
    /// state, run it with the given `[in, out, err]` fds, then restore — so a
    /// `cd`/assignment/`read` inside a pipeline cannot leak into the parent
    /// (POSIX subshell-per-stage). Returns the stage's exit status; `exit`/
    /// `return`/`break`/`continue` do not escape the stage.
    fn run_inline_stage(&mut self, cmd: &Command, fds: [Fd; 3]) -> i32 {
        let snap = self.snapshot();
        self.subshell_depth += 1;
        let status = match self.start_command(cmd, fds) {
            Started::Done(s) => s,
            Started::Control(flow) => match flow {
                Flow::Exit(c) | Flow::Return(c) => c,
                _ => self.last_status,
            },
            Started::Pid { pid, restore } => {
                // Defensive: a stage classified inline that nonetheless spawned.
                let st = self.os.waitpid(pid).unwrap_or(1);
                self.apply_env_restore(restore);
                st
            }
        };
        self.subshell_depth -= 1;
        self.restore(snap);
        status
    }

    fn exec_multi_pipeline(&mut self, pl: &Pipeline) -> Flow {
        let n = pl.cmds.len();
        let base = self.cur_fds;
        let mut statuses = vec![0i32; n];
        let mut pids: Vec<Option<Pid>> = vec![None; n];
        let mut temps: Vec<String> = Vec::new();

        // Thread the current stdin fd left-to-right. `cur_in_owned` marks an fd
        // the shell must close once the stage consumes it (a pipe read end or a
        // temp-file read end); the shell's own stdin (`base[0]`) is never closed.
        let mut cur_in = base[0];
        let mut cur_in_owned = false;

        // How a stage will run. Simple commands are EXPANDED here (once) so the
        // classification uses the *resolved* command name: a dynamically-named
        // command (`cmd=echo; $cmd … | cat`) that resolves to a builtin/function
        // takes the in-process temp-file path, while a real external still
        // streams concurrently through a pipe.
        enum Plan {
            InlineCmd,                                  // compound / function definition
            Simple(Vec<String>, Vec<(String, String)>), // expanded simple command
            Failed(i32),                                // expansion error (no output)
        }

        for i in 0..n {
            let is_last = i == n - 1;
            let cmd = &pl.cmds[i];

            let plan = match cmd {
                Command::Simple(sc) => match self.expand_simple(sc) {
                    Ok((argv, assigns)) => Plan::Simple(argv, assigns),
                    Err(status) => Plan::Failed(status),
                },
                _ => Plan::InlineCmd,
            };
            let inline = match &plan {
                Plan::InlineCmd | Plan::Failed(_) => true,
                Plan::Simple(argv, _) => self.expanded_runs_inline(argv),
            };

            if inline {
                // In-process stage: subshell + (non-last) output to a temp file
                // so it can never deadlock on a full pipe with no reader yet.
                let (out_fd, out_temp): (Fd, Option<String>) = if is_last {
                    (base[1], None)
                } else {
                    let path = self.tmp_path("pipe");
                    match self.os.open(&path, O_WRITE | O_CREATE | O_TRUNC) {
                        Ok(fd) => (fd, Some(path)),
                        Err(_) => (base[1], None),
                    }
                };
                statuses[i] = match plan {
                    Plan::InlineCmd => self.run_inline_stage(cmd, [cur_in, out_fd, base[2]]),
                    Plan::Simple(argv, assigns) => {
                        let redirs = match cmd {
                            Command::Simple(sc) => sc.redirs.clone(),
                            _ => Vec::new(),
                        };
                        self.run_inline_simple(&argv, &assigns, &redirs, [cur_in, out_fd, base[2]])
                    }
                    Plan::Failed(status) => status,
                };
                if cur_in_owned {
                    self.os.close(cur_in);
                }
                match out_temp {
                    Some(path) => {
                        self.os.close(out_fd);
                        match self.os.open(&path, O_READ) {
                            Ok(rfd) => {
                                cur_in = rfd;
                                cur_in_owned = true;
                            }
                            Err(_) => {
                                cur_in = base[0];
                                cur_in_owned = false;
                            }
                        }
                        temps.push(path);
                    }
                    None => {
                        cur_in = base[0];
                        cur_in_owned = false;
                    }
                }
            } else {
                // External stage: a real task, connected to its consumer by a
                // pipe (concurrent). The last stage writes straight to base[1].
                let (argv, assigns) = match plan {
                    Plan::Simple(argv, assigns) => (argv, assigns),
                    _ => unreachable!("only expanded simple commands classify as external"),
                };
                let redirs = match cmd {
                    Command::Simple(sc) => sc.redirs.clone(),
                    _ => Vec::new(),
                };
                let (out_fd, next_in): (Fd, Option<Fd>) = if is_last {
                    (base[1], None)
                } else {
                    match self.os.pipe() {
                        Ok((pr, pw)) => (pw, Some(pr)),
                        Err(_) => {
                            self.eprintln("sh: cannot create pipe");
                            if cur_in_owned {
                                self.os.close(cur_in);
                            }
                            for t in &temps {
                                let _ = self.remove_tmp(t);
                            }
                            self.last_status = 1;
                            return Flow::Normal;
                        }
                    }
                };
                // Pipeline stages run in subshells. Snapshot so temp assignments
                // and expansion-time shell mutations don't leak into later
                // stages; the spawned child already inherited its private env.
                let snap = self.snapshot();
                let started =
                    self.dispatch_simple(&argv, &assigns, &redirs, [cur_in, out_fd, base[2]]);
                let control_status = self.last_status;
                self.restore(snap);
                match started {
                    Started::Pid { pid, restore: _ } => {
                        pids[i] = Some(pid);
                    }
                    Started::Done(s) => statuses[i] = s,
                    Started::Control(_) => statuses[i] = control_status,
                }
                if cur_in_owned {
                    self.os.close(cur_in);
                }
                if !is_last {
                    self.os.close(out_fd); // shell drops its write-end copy
                }
                cur_in = next_in.unwrap_or(base[0]);
                cur_in_owned = next_in.is_some();
            }
        }
        if cur_in_owned {
            self.os.close(cur_in);
        }

        let live: Vec<Pid> = pids.iter().flatten().copied().collect();
        self.enter_foreground(&live);
        let mut stopped = false;
        for i in 0..n {
            if let Some(p) = pids[i] {
                match self.wait_one(p) {
                    FgWait::Exited(st) => statuses[i] = st,
                    FgWait::Stopped => {
                        stopped = true;
                        break;
                    }
                }
            }
        }
        self.leave_foreground();
        for t in &temps {
            let _ = self.remove_tmp(t);
        }
        if stopped {
            self.record_stopped(live, "pipeline".to_string());
            self.last_status = 128 + Signal::Tstp as i32;
            return Flow::Normal;
        }
        self.last_status = if self.opts.pipefail {
            statuses
                .iter()
                .rev()
                .copied()
                .find(|&s| s != 0)
                .unwrap_or(0)
        } else {
            statuses[n - 1]
        };
        Flow::Normal
    }

    /// Start a single pipeline's external commands in the background; returns
    /// their pids. Falls back to synchronous execution if any element is
    /// in-process (no fork to background it).
    fn start_pipeline_background(&mut self, pl: &Pipeline) -> Vec<Pid> {
        // For v1: only a single external command backgrounds cleanly.
        if pl.cmds.len() == 1 {
            if let Command::Simple(_) = &pl.cmds[0] {
                let base = self.cur_fds;
                match self.start_command(&pl.cmds[0], base) {
                    Started::Pid { pid, restore } => {
                        self.apply_env_restore(restore);
                        return vec![pid];
                    }
                    Started::Done(s) => {
                        self.last_status = s;
                        return vec![];
                    }
                    Started::Control(_) => return vec![],
                }
            }
        }
        // Degrade: run synchronously.
        self.exec_pipeline(pl);
        vec![]
    }

    // ================= command dispatch =================

    /// Execute one command to completion (used outside pipelines), returning flow.
    fn exec_command(&mut self, cmd: &Command, base: [Fd; 3]) -> Flow {
        match self.start_command(cmd, base) {
            Started::Done(s) => {
                self.last_status = s;
                Flow::Normal
            }
            Started::Control(f) => f,
            Started::Pid { pid, restore } => {
                self.enter_foreground(&[pid]);
                let outcome = self.wait_one(pid);
                self.leave_foreground();
                self.apply_env_restore(restore);
                match outcome {
                    FgWait::Exited(st) => self.last_status = st,
                    FgWait::Stopped => {
                        self.record_stopped(vec![pid], self.command_label(cmd));
                        self.last_status = 128 + Signal::Tstp as i32;
                    }
                }
                Flow::Normal
            }
        }
    }

    fn start_command(&mut self, cmd: &Command, base: [Fd; 3]) -> Started {
        match cmd {
            Command::Function { name, body } => {
                self.funcs.insert(name.clone(), Rc::new((**body).clone()));
                Started::Done(0)
            }
            Command::Compound { kind, redirs } => {
                let triple = match self.resolve_redirs(redirs, base) {
                    Ok(t) => t,
                    Err(e) => {
                        self.eprintln(&format!("sh: {e}"));
                        return Started::Done(1);
                    }
                };
                let flow = self.run_with_fds(triple, |me| me.exec_compound(kind));
                match flow {
                    Flow::Normal => Started::Done(self.last_status),
                    other => Started::Control(other),
                }
            }
            Command::Simple(sc) => self.start_simple(sc, base),
        }
    }

    fn start_simple(&mut self, sc: &SimpleCommand, base: [Fd; 3]) -> Started {
        match self.expand_simple(sc) {
            Ok((argv, assigns)) => self.dispatch_simple(&argv, &assigns, &sc.redirs, base),
            Err(status) => Started::Done(status),
        }
    }

    /// Expand a simple command's words → `argv` and its assignment values, ONCE.
    /// Split from dispatch so a pipeline can classify a stage by its *expanded*
    /// first word (a dynamic name like `$cmd` that resolves to a builtin must
    /// take the in-process path), without re-running expansions. `Err(status)`
    /// on an expansion error (e.g. `set -u`).
    fn expand_simple(
        &mut self,
        sc: &SimpleCommand,
    ) -> core::result::Result<(Vec<String>, Vec<(String, String)>), i32> {
        let mut argv: Vec<String> = Vec::new();
        for w in &sc.words {
            match expand_to_fields(w, self) {
                Ok(fields) => argv.extend(fields),
                Err(e) => {
                    self.eprintln(&format!("sh: {}", e.0));
                    return Err(1);
                }
            }
        }
        let mut assigns: Vec<(String, String)> = Vec::new();
        for a in &sc.assigns {
            match expand_to_string(&a.value, self) {
                Ok(v) => assigns.push((a.name.clone(), v)),
                Err(e) => {
                    self.eprintln(&format!("sh: {}", e.0));
                    return Err(1);
                }
            }
        }
        Ok((argv, assigns))
    }

    /// Whether an already-expanded simple command runs in-process (builtin,
    /// function, or a pure assignment) versus spawning an external program.
    fn expanded_runs_inline(&self, argv: &[String]) -> bool {
        match argv.first() {
            None => true, // pure assignment / redirect-only
            Some(name) => is_builtin(name) || self.funcs.contains_key(name),
        }
    }

    /// Run an already-expanded simple command against `base` fds. Handles pure
    /// assignments, functions, builtins, and external spawn (the latter returns
    /// `Started::Pid`).
    fn dispatch_simple(
        &mut self,
        argv: &[String],
        assigns: &[(String, String)],
        redirs: &[Redirect],
        base: [Fd; 3],
    ) -> Started {
        if argv.is_empty() {
            // Pure assignments (persist) + redirects (side effects only).
            for (n, v) in assigns {
                self.set_var_raw(n, v);
            }
            match self.resolve_redirs(redirs, base) {
                Ok(triple) => self.close_owned(&triple.owned),
                Err(e) => {
                    self.eprintln(&format!("sh: {e}"));
                    return Started::Done(1);
                }
            }
            return Started::Done(0);
        }

        let name = argv[0].clone();
        let triple = match self.resolve_redirs(redirs, base) {
            Ok(t) => t,
            Err(e) => {
                self.eprintln(&format!("sh: {e}"));
                return Started::Done(1);
            }
        };

        // Function?
        if let Some(body) = self.funcs.get(&name).cloned() {
            let restore = self.apply_temp_assigns(assigns);
            let argv2 = argv.to_vec();
            let flow = self.run_with_fds(triple, move |me| me.call_function(&body, &argv2));
            self.apply_env_restore(restore);
            return match flow {
                Flow::Return(c) => {
                    self.last_status = c;
                    Started::Done(c)
                }
                Flow::Normal => Started::Done(self.last_status),
                other => Started::Control(other),
            };
        }

        // Builtin?
        if is_builtin(&name) {
            let restore = self.apply_temp_assigns(assigns);
            let (status, flow) = self.run_builtin_with_redirs(&name, argv, triple);
            self.apply_env_restore(restore);
            return match flow {
                Some(f) => Started::Control(f),
                None => Started::Done(status),
            };
        }

        // External: temp assignments go to the environment for the child.
        let restore = self.apply_temp_assigns(assigns);
        let path = match self.resolve_path(&name) {
            Some(p) => p,
            None => {
                self.eprintln(&format!("sh: {name}: command not found"));
                self.close_owned(&triple.owned);
                self.apply_env_restore(restore);
                return Started::Done(127);
            }
        };
        let mut spawn_argv = argv.to_vec();
        spawn_argv[0] = path;

        // If stdout (or stderr via `2>&1`) is an in-memory capture sink, the child
        // can't receive a virtual fd. Spawn it to a temp file, wait, and splice the
        // temp into the capture buffer in order — no fork needed, and the per-child
        // temp keeps it deadlock-free. There is no interactive job control to give up
        // here (we are inside `$(...)`), so an inline wait is correct.
        let cap_idx = self
            .capture_index(triple.fds[1])
            .or_else(|| self.capture_index(triple.fds[2]));
        if let Some(idx) = cap_idx {
            let tmp = self.tmp_path("cap");
            let status = match self.os.open(&tmp, O_WRITE | O_CREATE | O_TRUNC) {
                Ok(wfd) => {
                    // Redirect whichever of stdout/stderr pointed at the capture sink.
                    let out_fd = if self.capture_index(triple.fds[1]).is_some() {
                        wfd
                    } else {
                        triple.fds[1]
                    };
                    let err_fd = if self.capture_index(triple.fds[2]).is_some() {
                        wfd
                    } else {
                        triple.fds[2]
                    };
                    let pid =
                        self.os
                            .spawn(&spawn_argv, triple.fds[0], out_fd, err_fd, TIER_INHERIT);
                    self.os.close(wfd);
                    self.close_owned(&triple.owned);
                    match pid {
                        Ok(p) => {
                            let st = self.os.waitpid(p).unwrap_or(1);
                            self.drain_capture_file(&tmp, idx);
                            st
                        }
                        Err(e) => {
                            self.eprintln(&format!("sh: {name}: {}", errno_str(e.0)));
                            let _ = self.remove_tmp(&tmp);
                            126
                        }
                    }
                }
                Err(_) => {
                    self.close_owned(&triple.owned);
                    self.eprintln(&format!("sh: {name}: cannot capture output"));
                    1
                }
            };
            self.apply_env_restore(restore);
            return Started::Done(status);
        }

        let pid = self.os.spawn(
            &spawn_argv,
            triple.fds[0],
            triple.fds[1],
            triple.fds[2],
            TIER_INHERIT,
        );
        self.close_owned(&triple.owned);
        match pid {
            Ok(p) => Started::Pid { pid: p, restore },
            Err(e) => {
                self.eprintln(&format!("sh: {name}: {}", errno_str(e.0)));
                self.apply_env_restore(restore);
                Started::Done(126)
            }
        }
    }

    /// Run an already-expanded simple command as an in-process pipeline stage:
    /// a real subshell (snapshot/restore), returning its exit status.
    fn run_inline_simple(
        &mut self,
        argv: &[String],
        assigns: &[(String, String)],
        redirs: &[Redirect],
        fds: [Fd; 3],
    ) -> i32 {
        let snap = self.snapshot();
        self.subshell_depth += 1;
        let status = match self.dispatch_simple(argv, assigns, redirs, fds) {
            Started::Done(s) => s,
            Started::Control(flow) => match flow {
                Flow::Exit(c) | Flow::Return(c) => c,
                _ => self.last_status,
            },
            Started::Pid { pid, restore } => {
                let st = self.os.waitpid(pid).unwrap_or(1);
                self.apply_env_restore(restore);
                st
            }
        };
        self.subshell_depth -= 1;
        self.restore(snap);
        status
    }

    // ================= compounds =================

    fn exec_compound(&mut self, c: &Compound) -> Flow {
        match c {
            Compound::BraceGroup(list) => self.exec_list(list),
            Compound::Subshell(list) => self.exec_subshell(list),
            Compound::If(i) => self.exec_if(i),
            Compound::For(f) => self.exec_for(f),
            Compound::While { cond, body } => self.exec_while(cond, body, false),
            Compound::Until { cond, body } => self.exec_while(cond, body, true),
            Compound::Case(c) => self.exec_case(c),
        }
    }

    fn exec_if(&mut self, i: &IfClause) -> Flow {
        for (cond, body) in &i.arms {
            let f = self.exec_list_cond(cond);
            if f != Flow::Normal {
                return f;
            }
            if self.last_status == 0 {
                return self.exec_list(body);
            }
        }
        if let Some(eb) = &i.else_body {
            return self.exec_list(eb);
        }
        self.last_status = 0;
        Flow::Normal
    }

    fn exec_for(&mut self, f: &ForClause) -> Flow {
        let items: Vec<String> = match &f.words {
            Some(ws) => {
                let mut v = Vec::new();
                for w in ws {
                    match expand_to_fields(w, self) {
                        Ok(fields) => v.extend(fields),
                        Err(e) => {
                            self.eprintln(&format!("sh: {}", e.0));
                            self.last_status = 1;
                            return Flow::Normal;
                        }
                    }
                }
                v
            }
            None => self.positional.clone(),
        };
        for item in items {
            self.set_var_raw(&f.var, &item);
            let flow = self.exec_list(&f.body);
            match flow {
                Flow::Break(1) => break,
                Flow::Break(n) => return Flow::Break(n - 1),
                Flow::Continue(1) => continue,
                Flow::Continue(n) => return Flow::Continue(n - 1),
                Flow::Normal => {}
                other => return other,
            }
        }
        Flow::Normal
    }

    fn exec_while(&mut self, cond: &List, body: &List, until: bool) -> Flow {
        loop {
            let f = self.exec_list_cond(cond);
            if f != Flow::Normal {
                return f;
            }
            let go = if until {
                self.last_status != 0
            } else {
                self.last_status == 0
            };
            if !go {
                break;
            }
            let flow = self.exec_list(body);
            match flow {
                Flow::Break(1) => break,
                Flow::Break(n) => return Flow::Break(n - 1),
                Flow::Continue(1) => continue,
                Flow::Continue(n) => return Flow::Continue(n - 1),
                Flow::Normal => {}
                other => return other,
            }
        }
        Flow::Normal
    }

    fn exec_case(&mut self, c: &CaseClause) -> Flow {
        let subject = match expand_to_string(&c.subject, self) {
            Ok(s) => s,
            Err(e) => {
                self.eprintln(&format!("sh: {}", e.0));
                self.last_status = 1;
                return Flow::Normal;
            }
        };
        let subj: Vec<char> = subject.chars().collect();
        for item in &c.items {
            for pat in &item.patterns {
                let p = match expand_to_string(pat, self) {
                    Ok(s) => s,
                    Err(e) => {
                        self.eprintln(&format!("sh: {}", e.0));
                        self.last_status = 1;
                        return Flow::Normal;
                    }
                };
                let pc: Vec<char> = p.chars().collect();
                if crate::glob::glob_full(&pc, &subj) {
                    return self.exec_list(&item.body);
                }
            }
        }
        self.last_status = 0;
        Flow::Normal
    }

    /// Run a condition list with `set -e` suppressed.
    fn exec_list_cond(&mut self, list: &List) -> Flow {
        let saved = self.opts.errexit;
        self.opts.errexit = false;
        let f = self.exec_list(list);
        self.opts.errexit = saved;
        f
    }

    // ================= subshell / command substitution =================

    fn snapshot(&mut self) -> Snapshot {
        Snapshot {
            vars: self.vars.clone(),
            positional: self.positional.clone(),
            arg0: self.arg0.clone(),
            opts: self.opts.clone(),
            last_status: self.last_status,
            cwd: self.os.getcwd().unwrap_or_default(),
            exported: self
                .vars
                .iter()
                .filter(|(_, v)| v.exported)
                .map(|(k, v)| (k.clone(), v.value.clone()))
                .collect(),
        }
    }
    fn restore(&mut self, snap: Snapshot) {
        // Reconcile /env: unset exported names not present before; reset others.
        let now_exported: BTreeMap<String, String> = self
            .vars
            .iter()
            .filter(|(_, v)| v.exported)
            .map(|(k, v)| (k.clone(), v.value.clone()))
            .collect();
        for name in now_exported.keys() {
            if !snap.exported.contains_key(name) {
                self.os.unsetenv(name);
            }
        }
        for (name, val) in &snap.exported {
            if now_exported.get(name) != Some(val) {
                self.os.setenv(name, val);
            }
        }
        self.vars = snap.vars;
        self.positional = snap.positional;
        self.arg0 = snap.arg0;
        self.opts = snap.opts;
        self.last_status = snap.last_status;
        let _ = self.os.chdir(&snap.cwd);
    }

    fn exec_subshell(&mut self, list: &List) -> Flow {
        let snap = self.snapshot();
        self.subshell_depth += 1;
        let flow = self.exec_list(list);
        self.subshell_depth -= 1;
        let status = self.last_status;
        self.restore(snap);
        self.last_status = status; // subshell exit status survives
        match flow {
            Flow::Exit(_) => Flow::Normal, // `exit` only ends the subshell
            other => other,
        }
    }

    fn command_subst_run(&mut self, raw: &str) -> String {
        let script = match parse(raw) {
            Ok(s) => s,
            Err(_) => return String::new(),
        };
        // Capture stdout into an in-memory buffer: push a sink and point stdout at its
        // virtual capture fd. Builtin output lands straight in the buffer; an external
        // child is spliced in (in order) via a temp file by `dispatch_simple`. No
        // filesystem round-trip in the common (all-builtin) case, and still
        // deadlock-free because each external child writes to its own temp.
        let idx = self.captures.len();
        self.captures.push(Vec::new());
        let cap = Self::capture_fd(idx);
        let snap = self.snapshot();
        let saved = self.cur_fds;
        self.cur_fds = [saved[0], cap, saved[2]];
        self.subshell_depth += 1;
        let _ = self.exec_list(&script.list);
        self.subshell_depth -= 1;
        self.cur_fds = saved;
        self.restore(snap);
        let mut out = self.captures.pop().unwrap_or_default();
        // Strip any `\r` (CRLF-input tolerance) from captured output so word splitting
        // and comparisons see clean `\n`, then strip trailing newlines.
        out.retain(|&b| b != b'\r');
        let mut s = String::from_utf8_lossy(&out).into_owned();
        while s.ends_with('\n') {
            s.pop();
        }
        s
    }

    fn tmp_path(&mut self, tag: &str) -> String {
        self.tmp_seq += 1;
        format!("/tmp/.mcsh-{}-{}-{}", self.shell_pid, tag, self.tmp_seq)
    }
    fn remove_tmp(&mut self, path: &str) -> OsResult<()> {
        self.os.unlink(path)
    }

    // ================= functions =================

    fn call_function(&mut self, body: &Command, argv: &[String]) -> Flow {
        if self.frames.len() > 128 {
            self.eprintln("sh: function recursion too deep");
            self.last_status = 1;
            return Flow::Normal;
        }
        self.frames.push(Frame {
            saved_positional: core::mem::take(&mut self.positional),
            saved_arg0: self.arg0.clone(),
            locals: Vec::new(),
        });
        self.positional = argv[1..].to_vec();
        let base = self.cur_fds;
        let flow = match self.start_command(body, base) {
            Started::Done(s) => {
                self.last_status = s;
                Flow::Normal
            }
            Started::Control(f) => f,
            Started::Pid { pid, restore } => {
                let st = self.os.waitpid(pid).unwrap_or(1);
                self.apply_env_restore(restore);
                self.last_status = st;
                Flow::Normal
            }
        };
        // pop frame, restoring locals + positional
        if let Some(frame) = self.frames.pop() {
            for (name, prev) in frame.locals.into_iter().rev() {
                match prev {
                    Some(v) => {
                        self.vars.insert(name, v);
                    }
                    None => {
                        self.vars.remove(&name);
                    }
                }
            }
            self.positional = frame.saved_positional;
            self.arg0 = frame.saved_arg0;
        }
        match flow {
            Flow::Return(c) => {
                self.last_status = c;
                Flow::Normal
            }
            other => other,
        }
    }

    // ================= redirections =================

    fn resolve_redirs(&mut self, redirs: &[Redirect], base: [Fd; 3]) -> Result<Triple, String> {
        let mut fds = base;
        let mut owned: Vec<Fd> = Vec::new();
        for r in redirs {
            let slot = r.io_number.unwrap_or(default_io(r.op)) as usize;
            if slot > 2 {
                // fds >2 not supported on spawn in v1
                return Err("redirections to fds >2 are unsupported".to_string());
            }
            match &r.op {
                RedirOp::Read => {
                    let p = expand_redirect_target(self.target_word(r)?, self)?;
                    let fd = self
                        .os
                        .open(&p, O_READ)
                        .map_err(|e| format!("{p}: {}", errno_str(e.0)))?;
                    fds[slot] = fd;
                    owned.push(fd);
                }
                RedirOp::Write | RedirOp::Clobber => {
                    let p = expand_redirect_target(self.target_word(r)?, self)?;
                    let fd = self
                        .os
                        .open(&p, O_WRITE | O_CREATE | O_TRUNC)
                        .map_err(|e| format!("{p}: {}", errno_str(e.0)))?;
                    fds[slot] = fd;
                    owned.push(fd);
                }
                RedirOp::Append => {
                    let p = expand_redirect_target(self.target_word(r)?, self)?;
                    let fd = self
                        .os
                        .open(&p, O_WRITE | O_CREATE | O_APPEND)
                        .map_err(|e| format!("{p}: {}", errno_str(e.0)))?;
                    fds[slot] = fd;
                    owned.push(fd);
                }
                RedirOp::ReadWrite => {
                    let p = expand_redirect_target(self.target_word(r)?, self)?;
                    let fd = self
                        .os
                        .open(&p, O_READ | O_WRITE | O_CREATE)
                        .map_err(|e| format!("{p}: {}", errno_str(e.0)))?;
                    fds[slot] = fd;
                    owned.push(fd);
                }
                RedirOp::DupOut | RedirOp::DupIn => match &r.target {
                    RedirTarget::Dup(DupSpec::Number(n)) => {
                        let src = *n as usize;
                        fds[slot] = if src <= 2 { fds[src] } else { -1 };
                    }
                    RedirTarget::Dup(DupSpec::Close) => {
                        fds[slot] = -1;
                    }
                    _ => return Err("bad fd duplication".to_string()),
                },
                RedirOp::Heredoc => {
                    if let RedirTarget::Here { body, expand } = &r.target {
                        let text = if *expand {
                            self.expand_heredoc(body)?
                        } else {
                            body.clone()
                        };
                        let path = self.tmp_path("hd");
                        let wfd = self
                            .os
                            .open(&path, O_WRITE | O_CREATE | O_TRUNC)
                            .map_err(|e| format!("heredoc: {}", errno_str(e.0)))?;
                        let _ = self.os.write_all(wfd, text.as_bytes());
                        self.os.close(wfd);
                        let rfd = self
                            .os
                            .open(&path, O_READ)
                            .map_err(|e| format!("heredoc: {}", errno_str(e.0)))?;
                        fds[slot] = rfd;
                        owned.push(rfd);
                    } else {
                        return Err("malformed heredoc".to_string());
                    }
                }
            }
        }
        Ok(Triple { fds, owned })
    }

    fn target_word<'a>(&self, r: &'a Redirect) -> Result<&'a Word, String> {
        match &r.target {
            RedirTarget::Word(w) => Ok(w),
            _ => Err("expected a filename".to_string()),
        }
    }

    fn expand_heredoc(&mut self, body: &str) -> Result<String, String> {
        // Heredoc bodies undergo parameter/command/arith expansion, but NOT
        // word-splitting or globbing. Lex the body as a double-quoted word.
        match crate::token::tokenize(&format!("\"{}\"", escape_for_dquote(body))) {
            Ok(toks) => {
                if let Some(crate::token::Token::Word(w)) = toks.first() {
                    return expand_to_string(w, self).map_err(|e| e.0);
                }
                Ok(body.to_string())
            }
            Err(_) => Ok(body.to_string()),
        }
    }

    /// Run `f` with the current fd triple swapped to `triple.fds` (for an
    /// in-process builtin/compound). No `dup2` onto std fds — builtins read/write
    /// `cur_fds` directly. Restores the previous triple and closes owned fds.
    fn run_with_fds<F: FnOnce(&mut Self) -> Flow>(&mut self, triple: Triple, f: F) -> Flow {
        let saved = self.cur_fds;
        self.cur_fds = triple.fds;
        let flow = f(self);
        self.cur_fds = saved;
        self.close_owned(&triple.owned);
        flow
    }

    fn close_owned(&mut self, owned: &[Fd]) {
        for &fd in owned {
            self.os.close(fd);
        }
    }

    // ================= temp assignments (VAR=val cmd) =================

    fn apply_temp_assigns(&mut self, assigns: &[(String, String)]) -> Vec<EnvRestore> {
        let mut restore = Vec::new();
        for (name, val) in assigns {
            let prev = self.vars.get(name).cloned();
            restore.push(EnvRestore {
                name: name.clone(),
                prev,
            });
            // temp assignments are exported to the command's environment
            self.vars.insert(
                name.clone(),
                VarVal {
                    value: val.clone(),
                    exported: true,
                },
            );
            self.os.setenv(name, val);
        }
        restore
    }

    fn apply_env_restore(&mut self, restore: Vec<EnvRestore>) {
        for r in restore.into_iter().rev() {
            match r.prev {
                Some(v) => {
                    if v.exported {
                        self.os.setenv(&r.name, &v.value);
                    } else {
                        self.os.unsetenv(&r.name);
                    }
                    self.vars.insert(r.name, v);
                }
                None => {
                    self.os.unsetenv(&r.name);
                    self.vars.remove(&r.name);
                }
            }
        }
    }

    // ================= PATH resolution =================

    fn resolve_path(&mut self, name: &str) -> Option<String> {
        if name.contains('/') {
            return Some(name.to_string());
        }
        let path = self
            .get_var("PATH")
            .unwrap_or_else(|| "/bin:/usr/bin".to_string());
        for dir in path.split(':') {
            if dir.is_empty() {
                continue;
            }
            let full = if dir.ends_with('/') {
                format!("{dir}{name}")
            } else {
                format!("{dir}/{name}")
            };
            if self.os.stat(&full).map(|s| !s.is_dir).unwrap_or(false) {
                return Some(full);
            }
        }
        None
    }

}


struct Snapshot {
    vars: BTreeMap<String, VarVal>,
    positional: Vec<String>,
    arg0: String,
    opts: Options,
    last_status: i32,
    cwd: String,
    exported: BTreeMap<String, String>,
}

struct EnvRestore {
    name: String,
    prev: Option<VarVal>,
}

pub(crate) struct Triple {
    fds: [Fd; 3],
    owned: Vec<Fd>,
}

enum Started {
    Pid { pid: Pid, restore: Vec<EnvRestore> },
    Done(i32),
    Control(Flow),
}

fn default_io(op: RedirOp) -> u32 {
    match op {
        RedirOp::Read | RedirOp::ReadWrite | RedirOp::DupIn | RedirOp::Heredoc => 0,
        RedirOp::Write | RedirOp::Append | RedirOp::Clobber | RedirOp::DupOut => 1,
    }
}

fn escape_for_dquote(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c == '"' || c == '\\' {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// Human text for a syscall errno. The numbers come from the contract
/// (`//contracts:constants_rust`), so this stays in lockstep with the `mc` ABI (B2).
fn errno_str(e: i32) -> String {
    let s = match e {
        abi::ENOENT => "No such file or directory",
        abi::EEXIST => "File exists",
        abi::ENOTDIR => "Not a directory",
        abi::EISDIR => "Is a directory",
        abi::EPERM => "Permission denied",
        abi::EINVAL => "Invalid argument",
        abi::ENOTEMPTY => "Directory not empty",
        abi::EIO => "I/O error",
        abi::EBADF => "Bad file descriptor",
        abi::ENOSYS => "Function not implemented",
        abi::EMFILE => "Too many open files",
        _ => return format!("error {}", e.abs()),
    };
    s.to_string()
}

/// Help text for a shell builtin, printed when its first argument is `--help`
/// or `-h` (see `dispatch_builtin`). Returns `None` for a name with no help (so
/// nothing is intercepted). The carry-both core set (echo/printf/pwd/test/[/
/// true/false/kill) mirrors its `/bin` twin; the rest document the builtin's own
/// surface. These are deliberately concise (like bash's `help`).

fn is_builtin(name: &str) -> bool {
    matches!(
        name,
        "cd" | "export"
            | "unset"
            | "exit"
            | "return"
            | "read"
            | "set"
            | "shift"
            | "test"
            | "["
            | ":"
            | "true"
            | "false"
            | "echo"
            | "pwd"
            | "printf"
            | "."
            | "source"
            | "eval"
            | "local"
            | "break"
            | "continue"
            | "jobs"
            | "fg"
            | "bg"
            | "kill"
            | "wait"
            | "command"
            | "umount"
            | "bind"
    )
}

// ===================== ExpandCtx impl =====================

impl<O: ShellOs> ExpandCtx for Interp<'_, O> {
    fn get(&mut self, name: &str) -> Option<String> {
        // Shell variable first; then fall back to the process environment
        // (`/env`) so externally-set vars (e.g. `echo v > /env/X`) and inherited
        // exports are visible as `$X`.
        match self.get_var(name) {
            Some(v) => Some(v),
            None => self.os.getenv(name),
        }
    }
    fn set(&mut self, name: &str, val: &str) {
        self.set_var_raw(name, val);
    }
    fn special(&mut self, name: &str) -> Option<String> {
        match name {
            "?" => Some(self.last_status.to_string()),
            "$" => Some(self.shell_pid.to_string()),
            "!" => Some(self.last_bg.map(|p| p.to_string()).unwrap_or_default()),
            "#" => Some(self.positional.len().to_string()),
            "-" => Some(self.opts_string()),
            "0" => Some(self.arg0.clone()),
            _ => {
                if let Ok(n) = name.parse::<usize>() {
                    if n >= 1 {
                        return self.positional.get(n - 1).cloned();
                    }
                }
                None
            }
        }
    }
    fn positionals(&mut self) -> Vec<String> {
        self.positional.clone()
    }
    fn command_subst(&mut self, raw: &str) -> String {
        self.command_subst_run(raw)
    }
    fn arith(&mut self, expr: &str) -> i64 {
        // POSIX: an arithmetic operand first undergoes parameter/command expansion.
        let expanded = self.expand_arith_operands(expr);
        // A one-borrow ArithEnv over the shell's variable map. The single-trait env
        // (vs two closures over the same map) is what lets this be a plain `&mut`
        // borrow — no raw pointers, no `unsafe`.
        struct VarEnv<'a>(&'a mut BTreeMap<String, VarVal>);
        impl crate::arith::ArithEnv for VarEnv<'_> {
            fn get(&mut self, name: &str) -> i64 {
                self.0
                    .get(name)
                    .and_then(|v| v.value.trim().parse::<i64>().ok())
                    .unwrap_or(0)
            }
            fn set(&mut self, name: &str, val: i64) {
                let exported = self.0.get(name).map(|x| x.exported).unwrap_or(false);
                self.0.insert(
                    name.to_string(),
                    VarVal {
                        value: val.to_string(),
                        exported,
                    },
                );
            }
        }
        let mut env = VarEnv(&mut self.vars);
        crate::arith::eval(&expanded, &mut env).unwrap_or(0)
    }
    fn list_dir(&mut self, path: &str) -> Option<Vec<String>> {
        self.os.readdir(path).ok()
    }
    fn cwd(&mut self) -> String {
        self.os.getcwd().unwrap_or_default()
    }
    fn ifs(&mut self) -> String {
        self.get_var("IFS").unwrap_or_else(|| " \t\n".to_string())
    }
    fn home(&mut self) -> Option<String> {
        self.get_var("HOME")
    }
}

impl<O: ShellOs> Interp<'_, O> {
    fn opts_string(&self) -> String {
        let mut s = String::new();
        if self.opts.errexit {
            s.push('e');
        }
        if self.opts.nounset {
            s.push('u');
        }
        if self.opts.xtrace {
            s.push('x');
        }
        s
    }
    /// Expand `$name` / `${...}` / `$(...)` inside an arithmetic expression to
    /// their (numeric-ish) string values before evaluation.
    fn expand_arith_operands(&mut self, expr: &str) -> String {
        // Reuse the word lexer: treat the expr as a double-quoted word so $..
        // expands but operators stay literal.
        match crate::token::tokenize(&format!("\"{}\"", escape_for_dquote(expr))) {
            Ok(toks) => {
                if let Some(crate::token::Token::Word(w)) = toks.first() {
                    return expand_to_string(w, self).unwrap_or_else(|_| expr.to_string());
                }
                expr.to_string()
            }
            Err(_) => expr.to_string(),
        }
    }
}
