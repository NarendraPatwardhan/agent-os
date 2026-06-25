//! The Big Kernel Lock (BKL) and threading coordination flags.
//!
//! The threaded build serializes all task execution behind one step-granular
//! ticket lock: every `task.step()` runs while the lock is held, so any worker
//! interleaving is equivalent to *some* serial ordering of steps — i.e. a
//! legal cooperative schedule (cooperative-equivalence).
//!
//! Two build shapes share one API:
//!   * `--features threads` (the DEFAULT): a real ticket lock plus
//!     `WORKERS` / `QUIESCE` atomics. On the current Option-B stable build
//!     (no `+atomics`) the atomics lower to plain loads/stores — correct
//!     because exactly one OS thread ever touches memory; the lock is
//!     always uncontended. On a future Option-A `+atomics` + shared-memory
//!     build the same code emits real atomic instructions and synchronizes
//!     across host worker threads with no source change.
//!   * `--no-default-features`: every primitive is a no-op ZST, so the
//!     cooperative-only artifact is byte-identical to the pre-threading
//!     kernel and carries none of the threading exports.
//!
//! Entry points (`mc_tick`, `mc_input`, `mc_worker_entry`) take the lock;
//! the quiesce flag is flipped *without* the lock so a snapshot request
//! can never deadlock behind a worker that is mid-step.

#[cfg(feature = "threads")]
mod imp {
    use core::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, Ordering};

    /// FIFO ticket lock used as the Big Kernel Lock.
    pub struct TicketLock {
        next: AtomicU32,
        owner: AtomicU32,
    }

    impl TicketLock {
        pub const fn new() -> Self {
            Self {
                next: AtomicU32::new(0),
                owner: AtomicU32::new(0),
            }
        }

        pub fn lock(&self) -> Guard<'_> {
            let ticket = self.next.fetch_add(1, Ordering::Acquire);
            while self.owner.load(Ordering::Acquire) != ticket {
                core::hint::spin_loop();
            }
            Guard { lock: self }
        }
    }

    /// RAII guard; releases the BKL on drop by serving the next ticket.
    pub struct Guard<'a> {
        lock: &'a TicketLock,
    }

    impl Drop for Guard<'_> {
        fn drop(&mut self) {
            self.lock.owner.fetch_add(1, Ordering::Release);
        }
    }

    static KERNEL_LOCK: TicketLock = TicketLock::new();
    /// Negotiated worker count (`mc_threads_init` result, clamped ≥ 0).
    static WORKERS: AtomicI32 = AtomicI32::new(0);
    /// Set by `mc_quiesce_request`; polled by workers at their safe point.
    static QUIESCE: AtomicBool = AtomicBool::new(false);

    /// Acquire the BKL for the duration of the returned guard.
    pub fn lock_kernel() -> Guard<'static> {
        KERNEL_LOCK.lock()
    }

    pub fn set_workers(n: i32) {
        WORKERS.store(if n > 0 { n } else { 0 }, Ordering::Release);
    }

    pub fn workers() -> i32 {
        WORKERS.load(Ordering::Acquire)
    }

    /// True when the host provisioned ≥ 1 worker: stepping is delegated to
    /// `mc_worker_entry` and `mc_tick` does coordination only.
    pub fn threaded() -> bool {
        workers() > 0
    }

    pub fn request_quiesce() {
        QUIESCE.store(true, Ordering::Release);
    }

    pub fn release_quiesce() {
        QUIESCE.store(false, Ordering::Release);
    }

    pub fn quiesce_requested() -> bool {
        QUIESCE.load(Ordering::Acquire)
    }
}

#[cfg(not(feature = "threads"))]
#[allow(dead_code)] // negotiation / quiesce helpers are unused without threads
mod imp {
    /// Zero-sized no-op guard: the cooperative-only build takes no lock,
    /// so its artifact is byte-identical to the pre-threading kernel.
    pub struct Guard;

    pub fn lock_kernel() -> Guard {
        Guard
    }

    pub fn set_workers(_n: i32) {}

    pub fn workers() -> i32 {
        0
    }

    pub fn threaded() -> bool {
        false
    }

    pub fn request_quiesce() {}

    pub fn release_quiesce() {}

    pub fn quiesce_requested() -> bool {
        false
    }
}

pub use imp::*;
