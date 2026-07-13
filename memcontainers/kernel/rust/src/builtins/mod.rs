//! Cooperative task-program boundary.
//!
//! A task owns one `Builtin` state machine. Each scheduler step performs
//! bounded work, exits, or reports why the task must wait.

use alloc::string::String;
use alloc::vec::Vec;

use crate::io::{ReadSource, WriteSink};
use crate::task::{BlockReason, Scheduler, TaskId};
use crate::vfs::Namespace;

pub mod fs;

/// What a program's `step` reports back to the runner.
#[derive(Debug)]
pub enum BuiltinStep {
    /// The builtin has produced all its output and exited.
    Exit(i32),
    /// The builtin wants to write more output but stdout returned 0
    /// bytes accepted. The runner parks the task on
    /// `BlockReason::PipeWrite`.
    BlockedOnStdout,
    /// The builtin made no progress this step and wants to be re-stepped
    /// next tick — e.g. a network builtin waiting on a host capability
    /// whose response is not ready yet. The runner re-readies the task
    /// (it is not parked on a pipe). One poll per tick, bounded.
    Pending,
    /// Park the task on an explicit block reason. Used by user-space guests
    /// to block on an arbitrary pipe fd or on `waitpid` — the runner calls
    /// `block_task(pid, reason)` directly.
    BlockedOn(BlockReason),
}

/// Per-step context handed to a program. Owned by the Task; the runner
/// constructs it from the task's fd table on every step.
pub struct BuiltinCtx<'a> {
    /// This task's (per-process) namespace.
    pub ns: &'a Namespace,
    pub cwd: &'a mut String,
    pub stdin: &'a mut dyn ReadSource,
    pub stdout: &'a mut dyn WriteSink,
    pub stderr: &'a mut dyn WriteSink,
    /// The scheduler and this task's id — used by user-space guests to spawn
    /// children, allocate pipes, and wait.
    pub sched: &'a Scheduler,
    pub pid: TaskId,
}

/// A running task program. Steps are cooperative — bounded work per
/// call, no internal loops that can hang the scheduler.
pub trait Builtin {
    fn step(&mut self, ctx: &mut BuiltinCtx<'_>) -> BuiltinStep;

    /// Optional resident-program control request. Ordinary programs do not
    /// expose one; `/bin/sh` uses it for bounded, syscall-free completion
    /// probe/render calls while its main invocation is suspended on stdin.
    fn control(&mut self, _request: &[u8]) -> Result<Vec<u8>, i32> {
        Err(crate::wasm::abi::ENOSYS)
    }

    fn has_control(&self) -> bool {
        false
    }
}
