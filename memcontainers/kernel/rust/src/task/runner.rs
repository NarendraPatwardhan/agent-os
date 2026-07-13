//! The cooperative task driver shared by `mc_tick` and threaded workers.

use crate::builtins::BuiltinStep;
use crate::vfs::Namespace;

use super::{BlockReason, Scheduler};

/// Niceness gap per skipped round in the cooperative priority scheme.
const NICE_SKIP_DIVISOR: u16 = 2;

/// Pop one ready task and drive it a single bounded step.
pub fn run_next(sched: &Scheduler, ns: &Namespace) -> bool {
    let pid = match sched.pop_ready() {
        Some(pid) => pid,
        None => return false,
    };
    if !sched.process_signals(pid) {
        return true;
    }
    let task = match sched.get_task(pid) {
        Some(task) => task,
        None => return true,
    };
    let floor = sched.min_ready_nice().min(task.nice);
    let relative = (task.nice as i32) - (floor as i32);
    if relative > 0 {
        let credit = task.skip_credit();
        if credit > 0 {
            task.set_skip_credit(credit - 1);
            sched.requeue(pid);
            return true;
        }
        task.set_skip_credit(relative as u16 / NICE_SKIP_DIVISOR);
    }
    match task.step(ns, sched) {
        Some(BuiltinStep::Exit(code)) => {
            task.close_stdout();
            task.close_stdin();
            task.close_stderr();
            task.clear_program();
            sched.exit_task(pid, code);
        }
        Some(BuiltinStep::BlockedOnStdout) => {
            if let Some(addr) = task.stdout_mut().block_handle() {
                sched.block_task(pid, BlockReason::PipeWrite { pipe_ptr: addr });
            } else {
                sched.requeue(pid);
            }
        }
        Some(BuiltinStep::Pending) => sched.requeue(pid),
        Some(BuiltinStep::BlockedOn(reason)) => sched.block_task(pid, reason),
        None => {
            task.clear_program();
            sched.exit_task(pid, 0);
        }
    }
    true
}

/// Step every task that was ready at entry exactly once.
pub fn run_round(sched: &Scheduler, ns: &Namespace) {
    let count = sched.ready_count();
    for _ in 0..count {
        if !run_next(sched, ns) {
            break;
        }
    }
}
