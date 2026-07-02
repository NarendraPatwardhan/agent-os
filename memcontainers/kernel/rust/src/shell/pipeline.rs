//! Pipeline submission and cooperative driver.
//!
//! A pipeline of N commands becomes N tasks connected by N-1 ring-buffer
//! pipes. The scheduler owns the pipes (stable Box addresses); tasks
//! reference them through `PipeSink` / `PipeSource` wrappers from
//! `crate::io`.
//!
//! Submission is atomic: every redirect file is opened up front before
//! any task is spawned. If anything fails partway, no tasks have been
//! installed and the caller sees the error directly. Otherwise N tasks
//! land in the scheduler's ready queue, each carrying a `Box<dyn
//! Builtin>` program produced by the executor.
//!
//! The driver polls each task's `step()`. A builtin reports either
//! `Exit(code)`, `BlockedOnStdin`, or `BlockedOnStdout`; the runner
//! parks the task on the matching `BlockReason` and the scheduler's
//! `check_unblocked` wakes it once the pipe state changes. Foreground
//! and background pipelines both advance one round per `mc_tick` via
//! `step_pipeline_once`.

use alloc::boxed::Box;
use alloc::format;
use alloc::rc::Rc;
use alloc::string::String;
use alloc::vec::Vec;
use core::cell::RefCell;

use crate::builtins::{Builtin, BuiltinFactory, BuiltinStep};
use crate::io::{CaptureSink, FileSink, FileSource, PipeSink, PipeSource, ReadSource};
use crate::shell::executor::Executor;
use crate::shell::parser::Pipeline;
use crate::task::{BlockReason, Capabilities, Scheduler, TaskId, TaskState};
use crate::vfs::{Namespace, OpenFlags};
use crate::wasm::{declared_tier, exec_policy, resolve_program, GuestProgram, GuestRuntime};

use super::super::builtins::fs::resolve_path;

/// A command resolved to either a builtin (instantiated lazily) or a loaded
/// wasm guest program. A wasm command also carries the capability policy it is
/// `exec`'d with: pid 1's live policy narrowed by the binary's declared tier.
enum Prepared {
    Builtin(BuiltinFactory),
    Wasm(Box<dyn Builtin>, Capabilities, Option<String>),
}

/// Per-pipeline output capture for the host control channel (`mc_ctl_exec`):
/// the tail command's terminal-bound stdout and every command's stderr are
/// redirected into these shared buffers instead of the terminal, so a
/// host-initiated `exec` collects structured stdout/stderr (and a real exit
/// code) rather than scraping the shared terminal stream.
pub struct OutputCapture {
    pub stdout: Rc<RefCell<Vec<u8>>>,
    pub stderr: Rc<RefCell<Vec<u8>>>,
}

/// Open every redirect file and instantiate every program before
/// spawning any task. On failure, return the error message and do not
/// touch the scheduler. On success, spawn N tasks, install their fds,
/// and return their pids in order.
///
/// The tail command's stdout and all stderr go to the terminal (the
/// interactive shell path).
pub fn submit_pipeline(
    sched: &Scheduler,
    ns: &Namespace,
    executor: &Executor,
    engine: &GuestRuntime,
    path: &str,
    cwd: &str,
    pipeline: &Pipeline,
) -> Result<Vec<TaskId>, String> {
    submit_pipeline_inner(sched, ns, executor, engine, path, cwd, pipeline, None, None)
}

/// Like [`submit_pipeline`], but the tail command's (non-redirected) stdout
/// and every command's stderr are captured into `capture` rather than written
/// to the terminal — the host control-channel `exec` path.
pub fn submit_pipeline_captured(
    sched: &Scheduler,
    ns: &Namespace,
    executor: &Executor,
    engine: &GuestRuntime,
    path: &str,
    cwd: &str,
    pipeline: &Pipeline,
    capture: &OutputCapture,
    stdin: Option<Box<dyn ReadSource>>,
) -> Result<Vec<TaskId>, String> {
    submit_pipeline_inner(
        sched,
        ns,
        executor,
        engine,
        path,
        cwd,
        pipeline,
        Some(capture),
        stdin,
    )
}

fn submit_pipeline_inner(
    sched: &Scheduler,
    ns: &Namespace,
    executor: &Executor,
    engine: &GuestRuntime,
    path: &str,
    cwd: &str,
    pipeline: &Pipeline,
    capture: Option<&OutputCapture>,
    mut stdin: Option<Box<dyn ReadSource>>,
) -> Result<Vec<TaskId>, String> {
    let n = pipeline.commands.len();
    if n == 0 {
        return Ok(Vec::new());
    }
    let (parent_caps, parent_root) = sched
        .get_task(1)
        .map(|parent| (parent.caps, parent.confine_root.clone()))
        .unwrap_or_else(|| (Capabilities::all(), None));

    // Phase 1: resolve every command up front. A builtin resolves to its
    // factory; anything else is looked up as a wasm program on the path and
    // fully loaded (compile + instantiate) here, so an invalid/missing program
    // fails the whole pipeline before any task is spawned (no stray zombies).
    let mut prepared: Vec<Option<Prepared>> = Vec::with_capacity(n);
    for cmd in &pipeline.commands {
        match executor.lookup(&cmd.cmd) {
            Some(f) => prepared.push(Some(Prepared::Builtin(f))),
            None => match resolve_program(ns, cwd, &cmd.cmd, path) {
                Some(bytes) => {
                    // argv[0] is the program name (POSIX); the rest are args.
                    let mut argv = Vec::with_capacity(cmd.args.len() + 1);
                    argv.push(cmd.cmd.clone());
                    argv.extend(cmd.args.iter().cloned());
                    match GuestProgram::load(engine, &bytes, argv, path) {
                        Ok(g) => {
                            // Exec policy: pid 1's live policy is the parent
                            // ceiling; the binary's declared tier narrows it.
                            let (caps, root) = exec_policy(
                                parent_caps,
                                parent_root.clone(),
                                declared_tier(&bytes),
                                None,
                                cwd,
                            );
                            prepared.push(Some(Prepared::Wasm(Box::new(g), caps, root)));
                        }
                        Err(msg) => return Err(format!("{}: {}", cmd.cmd, msg)),
                    }
                }
                None => return Err(format!("{}: command not found", cmd.cmd)),
            },
        }
    }

    // Phase 2: open every redirect file BEFORE spawning. Every command in a
    // pipeline may carry its own `< file` / `> file` / `>> file`.
    struct Plan {
        stdin: Option<Box<dyn crate::io::ReadSource>>,
        stdout: Option<Box<dyn crate::io::WriteSink>>,
    }
    let mut plans: Vec<Plan> = Vec::with_capacity(n);
    for cmd in &pipeline.commands {
        let stdin = match &cmd.redirect_in {
            Some(path) => {
                let p = resolve_path(cwd, path);
                // Shell redirection acts as the agent (pid 1).
                match ns.open_as(1, &p, OpenFlags::READ) {
                    Ok(h) => Some(Box::new(FileSource(h)) as Box<dyn crate::io::ReadSource>),
                    Err(e) => {
                        return Err(format!(
                            "{}: {}",
                            p.as_str(),
                            crate::builtins::fs_error_str(e)
                        ));
                    }
                }
            }
            None => None,
        };
        let stdout = match &cmd.redirect_out {
            Some((path, append)) => {
                let p = resolve_path(cwd, path);
                let flags = if *append {
                    OpenFlags::APPEND
                } else {
                    OpenFlags::TRUNCATE
                };
                match ns.open_as(1, &p, flags) {
                    Ok(h) => Some(Box::new(FileSink(h)) as Box<dyn crate::io::WriteSink>),
                    Err(e) => {
                        return Err(format!(
                            "{}: {}",
                            p.as_str(),
                            crate::builtins::fs_error_str(e)
                        ));
                    }
                }
            }
            None => None,
        };
        plans.push(Plan { stdin, stdout });
    }

    // Phase 3: allocate N-1 pipes. Each connects command[i].stdout →
    // command[i+1].stdin **unless** an explicit redirect overrides one
    // of those ends — per POSIX, redirections win over pipe wiring.
    let mut pipes: Vec<&crate::ipc::Pipe> = Vec::with_capacity(n.saturating_sub(1));
    for _ in 0..n.saturating_sub(1) {
        pipes.push(sched.alloc_pipe());
    }

    // Phase 4: spawn tasks and install their fds + programs.
    //
    // When a redirect wins over a pipe end, the *other* end of that pipe
    // must be closed up front — otherwise the surviving end blocks
    // forever waiting for a partner that will never arrive. Example:
    // `echo a > /tmp/x | cat` — echo's stdout is the file, but cat's
    // stdin is still the pipe's read end. Without closing the pipe's
    // write end here, cat would block on `PipeRead` indefinitely.
    let mut pids = Vec::with_capacity(n);
    for (i, cmd) in pipeline.commands.iter().enumerate() {
        let pid = sched.spawn(
            Some(1),
            cmd.cmd.clone(),
            cmd.cmd.clone(),
            cmd.args.clone(),
            String::from(cwd),
        );
        let task = sched.get_task(pid).expect("just spawned");

        // Give the command its own per-process namespace, forked from the
        // shell's (root) view.
        task.set_namespace(ns.fork(pid));

        let plan = plans.get_mut(i).expect("plan present");

        // stdin: redirect wins, else inbound pipe, else optional control-channel stdin,
        // else default Empty.
        if let Some(src) = plan.stdin.take() {
            task.set_stdin(src);
            // Producer side will never have a reader on the pipe →
            // close the pipe's read end so producer's write returns
            // BrokenPipe and it exits cleanly instead of blocking on
            // PipeWrite forever.
            if i > 0 {
                pipes[i - 1].close_read();
            }
        } else if i > 0 {
            task.set_stdin(Box::new(PipeSource::new(pipes[i - 1])));
        } else if let Some(src) = stdin.take() {
            task.set_stdin(src);
        }

        // stdout: redirect wins, else outbound pipe, else terminal.
        if let Some(sink) = plan.stdout.take() {
            task.set_stdout(sink);
            // Consumer side will never receive bytes through the pipe →
            // close the pipe's write end so the consumer's stdin source
            // sees EOF on its first read.
            if i + 1 < n {
                pipes[i].close_write();
            }
        } else if i + 1 < n {
            task.set_stdout(Box::new(PipeSink::new(pipes[i])));
        }

        // Control-channel capture: every command's stderr is collected, and
        // the tail command's stdout is collected too — unless it has its own
        // `>`/`>>` redirect (a redirect always wins, matching POSIX and the
        // terminal path above). Intermediate commands keep their pipe stdout.
        if let Some(cap) = capture {
            task.set_stderr(Box::new(CaptureSink(cap.stderr.clone())));
            if i + 1 == n && cmd.redirect_out.is_none() {
                task.set_stdout(Box::new(CaptureSink(cap.stdout.clone())));
            }
        }

        let program: Box<dyn Builtin> = match prepared[i].take().expect("prepared command") {
            Prepared::Builtin(f) => f(cmd.args.clone()),
            Prepared::Wasm(g, caps, root) => {
                sched.set_task_policy(pid, caps, root);
                g
            }
        };
        task.set_program(program);

        pids.push(pid);
    }

    Ok(pids)
}

/// Pop one ready task and drive it a single step. This is the kernel's
/// **single execution primitive**, shared verbatim by the cooperative
/// tick (`run_round`) and the threaded worker (`mc_worker_entry`): both
/// consume the same FIFO ready queue under the Big Kernel Lock, so the
/// sequence of `task.step()` calls is identical regardless of mode or
/// worker count (the determinism invariant behind cooperative-equivalence).
///
/// Returns true if a task was stepped, false if the ready queue was empty.
///
/// Niceness gap per skipped round (the `K` in the cooperative `nice` scheme): a
/// task whose niceness exceeds the runnable floor by `rel` is skipped
/// `rel / NICE_SKIP_DIVISOR` rounds between steps. Small enough that a gap of a
/// couple of levels already deprioritizes; large enough that even the widest gap
/// keeps a job comfortably within the e2e tick budget.
const NICE_SKIP_DIVISOR: u16 = 2;

pub fn run_next(sched: &Scheduler, ns: &Namespace) -> bool {
    let pid = match sched.pop_ready() {
        Some(p) => p,
        None => return false,
    };
    // Apply any signals raised while this task sat in the ready queue (or that
    // it raised on itself last step, which were deferred to this boundary). If
    // a signal terminated it, it is now a zombie — don't step it.
    if !sched.process_signals(pid) {
        return true;
    }
    let task = match sched.get_task(pid) {
        Some(t) => t,
        // Task vanished between pop and lookup (shouldn't happen); clear
        // the stale `current` by requeuing nothing and report progress.
        None => return true,
    };
    // Cooperative `nice`: a task whose niceness exceeds the lowest among
    // currently-runnable tasks is skipped for some rounds, proportional to the
    // gap. This is RELATIVE (a negative-nice task becomes the floor and makes its
    // peers skip), and it never steps a task twice — a skip just yields this
    // visit, requeuing the task un-stepped. `process_signals` already ran above,
    // so a skipped task still takes a pending SIGKILL promptly. The floor folds
    // in this task's own niceness since `pop_ready` already removed it from the
    // ready set.
    let floor = sched.min_ready_nice().min(task.nice);
    let rel = (task.nice as i32) - (floor as i32);
    if rel > 0 {
        let credit = task.skip_credit();
        if credit > 0 {
            task.set_skip_credit(credit - 1);
            sched.requeue(pid);
            return true;
        }
        // This task's turn: reload its skip quota, then step it now.
        task.set_skip_credit(rel as u16 / NICE_SKIP_DIVISOR);
    }
    match task.step(ns, sched) {
        Some(BuiltinStep::Exit(code)) => {
            // Close all three std streams so upstream writers see broken-pipe and
            // downstream readers see EOF, instead of either side getting wedged on
            // the dead task's fd. stderr is closed too (POSIX: every fd closes on
            // exit) so a child whose stderr is a pipe write end — combined
            // stdout+stderr capture — still delivers EOF before it is reaped.
            task.close_stdout();
            task.close_stdin();
            task.close_stderr();
            // POSIX: every fd closes on exit. close_std* handled 0/1/2; dropping the
            // program closes the guest's OTHER fds — a served-fs / svc-service channel
            // closes here, so a crashed server's clients fail rather than hang on it.
            task.clear_program();
            sched.exit_task(pid, code);
        }
        Some(BuiltinStep::BlockedOnStdin) => {
            if let Some(addr) = task.stdin_mut().block_handle() {
                sched.block_task(pid, BlockReason::PipeRead { pipe_ptr: addr });
            } else {
                // No pipe behind stdin → not truly parked; re-ready it so
                // its next step sees is_eof() == true and exits.
                sched.requeue(pid);
            }
        }
        Some(BuiltinStep::BlockedOnStdout) => {
            if let Some(addr) = task.stdout_mut().block_handle() {
                sched.block_task(pid, BlockReason::PipeWrite { pipe_ptr: addr });
            } else {
                // No pipe behind stdout (terminal / file) — the builtin
                // asked to be re-entered; re-ready it for another step.
                sched.requeue(pid);
            }
        }
        Some(BuiltinStep::Pending) => {
            // Made no progress (e.g. waiting on a host capability). Not
            // parked on a pipe — re-ready it so it polls again next tick.
            sched.requeue(pid);
        }
        Some(BuiltinStep::BlockedOn(reason)) => {
            // A guest blocked on an explicit reason (an arbitrary pipe fd or
            // a child it is waiting on). `check_unblocked` / `exit_task` wake it.
            sched.block_task(pid, reason);
        }
        None => {
            task.clear_program();
            sched.exit_task(pid, 0);
        }
    }
    true
}

/// Step every currently-ready task exactly once. Bounded by the ready
/// count captured at entry so a task that re-readies itself within the
/// round is not stepped twice. Used by the cooperative `mc_tick`; in
/// threaded mode the host drives `run_next` through `mc_worker_entry`
/// instead.
pub fn run_round(sched: &Scheduler, ns: &Namespace) {
    let n = sched.ready_count();
    for _ in 0..n {
        if !run_next(sched, ns) {
            break;
        }
    }
}

/// Reap any pids whose task is a zombie. Used after a background
/// pipeline finishes to free linear memory.
pub fn reap_finished(sched: &Scheduler, pids: &[TaskId]) -> bool {
    let mut all_done = true;
    for &pid in pids {
        match sched.get_task(pid) {
            None => {}
            Some(t) if matches!(t.state, TaskState::Zombie) => {
                sched.reap_zombie(pid);
            }
            Some(_) => {
                all_done = false;
            }
        }
    }
    if all_done {
        sched.drop_dead_pipes();
    }
    all_done
}
