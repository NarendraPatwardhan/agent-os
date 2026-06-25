//! The host's half of the `env` bridge (A4) — GENERATED from `contracts/bridge.kdl`
//! (projected to `env_rust`), the same contract the kernel's import block is generated
//! from, so the two cannot drift (B2). `mc_bridge_table!` hands each import to the host's
//! `$emit` (`register_env`), which maps the contract's ABI type tokens to the wasm value
//! types the host sees and registers a `func_wrap` forwarding to a handler in `handlers`.
//! Adding an `env` import emits a registration calling a handler that does not exist yet —
//! a compile error until the host implements it (drift = compile error). The
//! handlers themselves are host logic: stdout/clock/rng act directly, the gateable
//! capabilities (net/persist/host_call) dispatch to the installed policy (Denied by
//! default, A9).

use anyhow::Result;
use wasmtime::{Caller, Linker};

use crate::HostState;

/// Map a contract ABI type token to the wasm value type the host sees. A guest pointer
/// (cptr/mptr) is an `i32` offset into the kernel's linear memory that the handler
/// translates through the `Caller`; `void`/`noreturn` are the unit type (`mc_exit` records
/// the code and returns — the host's tick loop stops on it).
macro_rules! host_ty {
    (cptr) => { i32 };
    (mptr) => { i32 };
    (len) => { i32 };
    (i32) => { i32 };
    (i64) => { i64 };
    (void) => { () };
    (noreturn) => { () };
}

/// `$emit` for the env bridge: one `func_wrap` per import, forwarding to its handler. The
/// leading `$(#[$attr])*` carries any contract row metadata (none on the env imports
/// today). The `$variant` label is unused here (the kernel's import block keys on it).
macro_rules! register_env {
    ( $( $(#[$attr:meta])* $name:ident => $variant:ident ( $($arg:ident : $ty:tt),* ) [$ret:tt]; )* ) => {
        pub fn register_bridge(linker: &mut Linker<HostState>) -> Result<()> {
            $(
                $(#[$attr])*
                linker.func_wrap(
                    "env",
                    stringify!($name),
                    |mut caller: Caller<'_, HostState>, $($arg: host_ty!($ty)),*|
                        -> host_ty!($ret) {
                        handlers::$name(&mut caller $(, $arg)*)
                    },
                )?;
            )*
            Ok(())
        }
    };
}

env_rust::mc_bridge_table!(register_env);

/// The host's `env` import bodies. The contract fixes each signature; these supply the
/// behavior. Each takes the `Caller` first (some ignore it).
mod handlers {
    use wasmtime::Caller;

    // The capability/sink methods resolve through their trait objects (`Box<dyn …>`), so
    // the traits need not be imported here — only the helpers and `HostState`.
    use crate::{HostState, host_call_read_into, net_read_into, persist_read_into, read_memory};

    // ── terminal I/O ─────────────────────────────────────────────────────────
    pub fn mc_stdout_write(caller: &mut Caller<'_, HostState>, ptr: i32, len: i32) {
        if let Some(bytes) = read_memory(caller, ptr, len) {
            let state = caller.data_mut();
            state.bytes_written = state.bytes_written.saturating_add(bytes.len() as u64);
            // Track the last two bytes for prompt detection.
            for &b in bytes.iter().rev().take(2).rev() {
                state.stdout_tail = [state.stdout_tail[1], b];
            }
            state.stdout.write(&bytes);
        }
    }

    pub fn mc_stderr_write(caller: &mut Caller<'_, HostState>, ptr: i32, len: i32) {
        if let Some(bytes) = read_memory(caller, ptr, len) {
            let state = caller.data_mut();
            state.bytes_written = state.bytes_written.saturating_add(bytes.len() as u64);
            state.stderr.write(&bytes);
        }
    }

    pub fn mc_stdin_read(_caller: &mut Caller<'_, HostState>, _buf: i32, _len: i32) -> i32 {
        // Input is pushed via mc_input; pull-based stdin is a no-op for both CLI and tests.
        0
    }

    // ── time (CAP_AMBIENT) ───────────────────────────────────────────────────
    pub fn mc_time_now(caller: &mut Caller<'_, HostState>) -> i64 {
        caller.data_mut().clock.now_millis()
    }

    pub fn mc_time_monotonic(caller: &mut Caller<'_, HostState>) -> i64 {
        caller.data_mut().clock.monotonic_millis()
    }

    // ── randomness (CAP_AMBIENT) ─────────────────────────────────────────────
    pub fn mc_random(caller: &mut Caller<'_, HostState>, ptr: i32, len: i32) {
        let memory = match caller.data().memory() {
            Some(m) => m,
            None => return,
        };
        let mut buf = vec![0u8; len as usize];
        caller.data_mut().rng.fill(&mut buf);
        let data = memory.data_mut(&mut *caller);
        let start = ptr as usize;
        let end = start.saturating_add(buf.len());
        if end <= data.len() {
            data[start..end].copy_from_slice(&buf);
        }
    }

    // ── HTTP — dispatched to the net capability (DeniedNet refuses, A9) ───────
    pub fn mc_http_request(caller: &mut Caller<'_, HostState>, ptr: i32, len: i32) -> i32 {
        let req = match read_memory(caller, ptr, len) {
            Some(b) => b,
            None => return -1,
        };
        caller.data_mut().net.http_request(&req)
    }
    pub fn mc_http_response_poll(caller: &mut Caller<'_, HostState>, h: i32, ptr: i32, len: i32) -> i32 {
        net_read_into(caller, ptr, len, |net, buf| net.http_poll(h, buf))
    }
    pub fn mc_http_response_body(caller: &mut Caller<'_, HostState>, h: i32, ptr: i32, len: i32) -> i32 {
        net_read_into(caller, ptr, len, |net, buf| net.http_body(h, buf))
    }
    pub fn mc_http_request_close(caller: &mut Caller<'_, HostState>, h: i32) {
        caller.data_mut().net.http_close(h);
    }

    // ── WebSocket ────────────────────────────────────────────────────────────
    pub fn mc_ws_connect(caller: &mut Caller<'_, HostState>, ptr: i32, len: i32) -> i32 {
        let url = match read_memory(caller, ptr, len).and_then(|b| String::from_utf8(b).ok()) {
            Some(u) => u,
            None => return -1,
        };
        caller.data_mut().net.ws_connect(&url)
    }
    pub fn mc_ws_send(caller: &mut Caller<'_, HostState>, h: i32, ptr: i32, len: i32) -> i32 {
        let data = match read_memory(caller, ptr, len) {
            Some(b) => b,
            None => return -1,
        };
        caller.data_mut().net.ws_send(h, &data)
    }
    pub fn mc_ws_recv(caller: &mut Caller<'_, HostState>, h: i32, ptr: i32, len: i32) -> i32 {
        net_read_into(caller, ptr, len, |net, buf| net.ws_recv(h, buf))
    }
    pub fn mc_ws_close(caller: &mut Caller<'_, HostState>, h: i32) {
        caller.data_mut().net.ws_close(h);
    }

    // ── host call — dispatched to the host-call capability (Denied refuses) ───
    pub fn mc_host_call(caller: &mut Caller<'_, HostState>, ptr: i32, len: i32) -> i32 {
        let req = match read_memory(caller, ptr, len) {
            Some(b) => b,
            None => return -1,
        };
        caller.data_mut().host_call.start(&req)
    }
    pub fn mc_host_call_poll(caller: &mut Caller<'_, HostState>, h: i32, _ptr: i32, _len: i32) -> i32 {
        caller.data_mut().host_call.poll(h)
    }
    pub fn mc_host_call_body(caller: &mut Caller<'_, HostState>, h: i32, ptr: i32, len: i32) -> i32 {
        host_call_read_into(caller, ptr, len, |hc, buf| hc.body(h, buf))
    }
    pub fn mc_host_call_close(caller: &mut Caller<'_, HostState>, h: i32) {
        caller.data_mut().host_call.close(h);
    }

    // ── persistence — dispatched to the persist capability (Denied refuses) ───
    pub fn mc_persist_get(caller: &mut Caller<'_, HostState>, kp: i32, kl: i32, vp: i32, vl: i32) -> i32 {
        let key = match read_memory(caller, kp, kl) {
            Some(k) => k,
            None => return -1,
        };
        persist_read_into(caller, vp, vl, |p, out| p.get(&key, out))
    }
    pub fn mc_persist_put(caller: &mut Caller<'_, HostState>, kp: i32, kl: i32, vp: i32, vl: i32) -> i32 {
        let key = match read_memory(caller, kp, kl) {
            Some(k) => k,
            None => return -1,
        };
        let val = match read_memory(caller, vp, vl) {
            Some(v) => v,
            None => return -1,
        };
        caller.data_mut().persist.put(&key, &val)
    }
    pub fn mc_persist_delete(caller: &mut Caller<'_, HostState>, kp: i32, kl: i32) -> i32 {
        let key = match read_memory(caller, kp, kl) {
            Some(k) => k,
            None => return -1,
        };
        caller.data_mut().persist.delete(&key)
    }
    pub fn mc_persist_list(caller: &mut Caller<'_, HostState>, pp: i32, pl: i32, bp: i32, bl: i32) -> i32 {
        let prefix = match read_memory(caller, pp, pl) {
            Some(p) => p,
            None => return -1,
        };
        persist_read_into(caller, bp, bl, |p, out| p.list(&prefix, out))
    }

    // ── threading — the host advertises its worker count; spawn/park inert ────
    pub fn mc_threads_init(caller: &mut Caller<'_, HostState>, max: i32) -> i32 {
        // Return 0 <= n <= max_workers. Clamp the advertised count to the kernel-supplied
        // ceiling and record what was actually granted.
        let granted = caller.data().workers.clamp(0, max.max(0));
        caller.data_mut().workers_granted = granted;
        granted
    }
    pub fn mc_thread_spawn(_caller: &mut Caller<'_, HostState>, _entry: i32, _arg: i32) -> i32 {
        -1
    }
    pub fn mc_thread_park(_caller: &mut Caller<'_, HostState>, _timeout: i32) -> i32 {
        0
    }
    pub fn mc_thread_unpark(_caller: &mut Caller<'_, HostState>, _handle: i32) {}

    // ── control ──────────────────────────────────────────────────────────────
    pub fn mc_yield(_caller: &mut Caller<'_, HostState>) {}

    /// mc_exit MUST NOT call `std::process::exit` — that would kill the test process when a
    /// kernel builtin invokes exit. Record the code on `HostState`; the tick loop drives to
    /// a graceful stop.
    pub fn mc_exit(caller: &mut Caller<'_, HostState>, code: i32) {
        caller.data_mut().exit_code = Some(code);
    }

    pub fn mc_log(caller: &mut Caller<'_, HostState>, level: i32, ptr: i32, len: i32) {
        let bytes = read_memory(caller, ptr, len).unwrap_or_default();
        let prefix: &[u8] = match level {
            0 => b"[DEBUG] ",
            1 => b"[INFO] ",
            2 => b"[WARN] ",
            3 => b"[ERROR] ",
            _ => b"[LOG] ",
        };
        let mut line = Vec::with_capacity(prefix.len() + bytes.len() + 1);
        line.extend_from_slice(prefix);
        line.extend_from_slice(&bytes);
        if !line.ends_with(b"\n") {
            line.push(b'\n');
        }
        let state = caller.data_mut();
        state.bytes_written = state.bytes_written.saturating_add(line.len() as u64);
        state.log.write(&line);
    }

    // ── boot / image loading ─────────────────────────────────────────────────
    pub fn mc_load_base_image(caller: &mut Caller<'_, HostState>, buf: i32, buf_len: i32) -> i32 {
        let memory = match caller.data().memory() {
            Some(m) => m,
            None => return -1,
        };
        let image = match &caller.data().base_image {
            Some(v) => v.clone(),
            None => return -1,
        };
        let data = memory.data_mut(&mut *caller);
        let start = buf as usize;
        let len = buf_len as usize;
        let end = match start.checked_add(len) {
            Some(e) if e <= data.len() => e,
            _ => return -1,
        };
        let to_copy = image.len().min(len);
        data[start..start + to_copy].copy_from_slice(&image[..to_copy]);
        let _ = end;
        // Return the FULL image length (not just what fit): the kernel probes with a
        // zero-length read to size its buffer, then reads the whole image.
        image.len() as i32
    }

    /// Write the boot runtime contract `[i32 tier][i32 mem_mib][i64 fuel]` (LE, 16 bytes).
    /// `0` written ⇒ no contract.
    pub fn mc_boot_contract(caller: &mut Caller<'_, HostState>, buf: i32, buf_len: i32) -> i32 {
        let tier = caller.data().boot_tier;
        let mib = caller.data().boot_budget_mib;
        let fuel = caller.data().boot_budget_fuel;
        if tier == 0 && mib <= 0 && fuel <= 0 {
            return 0;
        }
        let memory = match caller.data().memory() {
            Some(m) => m,
            None => return -1,
        };
        let data = memory.data_mut(&mut *caller);
        let start = buf as usize;
        if buf_len < 16 || start.checked_add(16).is_none_or(|e| e > data.len()) {
            return -1;
        }
        data[start..start + 4].copy_from_slice(&tier.to_le_bytes());
        data[start + 4..start + 8].copy_from_slice(&mib.to_le_bytes());
        data[start + 8..start + 16].copy_from_slice(&fuel.to_le_bytes());
        16
    }
}
