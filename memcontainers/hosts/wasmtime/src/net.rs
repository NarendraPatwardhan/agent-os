//! Host network capability — the real thing, no mocks.
//!
//! `DeniedNet` is the default policy gate (every call `-1`; default-deny, A9).
//! `RealNet` performs genuine HTTP/HTTPS via `ureq` (rustls TLS) and
//! WebSocket via `tungstenite` (rustls). It is installed only under
//! `--allow-net`. The kernel wraps whatever handle we return in a kernel-side
//! abstraction owned by a builtin (`HttpReq`/`WsConn`), so the agent never
//! sees these integers. (An fd-level / `netfs` surface is deferred to a later
//! milestone, where user-space syscalls arrive.)
//!
//! HTTP uses a buffer-then-deliver model that composes with the kernel's
//! cooperative poll: `http_request` spawns a thread that runs the blocking
//! request and buffers the full response; `http_poll` returns `0` until the
//! buffer is complete, then the response head; `http_body` streams the body.

use std::collections::{HashMap, VecDeque};
use std::io::Read;
use std::net::TcpStream;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use crate::connections::ConnectionRegistry;

/// WebSocket send sentinels from the generated contract constants (B2): `-EAGAIN`
/// is retryable backpressure; `-EMSGSIZE` is a permanent oversized-frame error.
use constants_rust::{EAGAIN, EMSGSIZE};

/// The network bridge calls, behind the host's capability policy.
pub trait NetCapability: Send + 'static {
    fn http_request(&mut self, req: &[u8]) -> i32;
    fn http_poll(&mut self, handle: i32, buf: &mut [u8]) -> i32;
    fn http_body(&mut self, handle: i32, buf: &mut [u8]) -> i32;
    fn http_close(&mut self, handle: i32);
    fn ws_connect(&mut self, url: &str) -> i32;
    fn ws_send(&mut self, handle: i32, data: &[u8]) -> i32;
    /// Write-readiness probe for a parked guest write (the dual of `recv` probing
    /// the read side): `1` if a `ws_send` would make progress (the relay can take
    /// a frame, i.e. its bounded queue is below the mark) OR the socket is closed
    /// (so the parked write wakes and errors out), `0` only while genuinely
    /// would-block. The kernel gates a parked write on this.
    fn ws_ready(&mut self, handle: i32) -> i32;
    fn ws_recv(&mut self, handle: i32, buf: &mut [u8]) -> i32;
    fn ws_close(&mut self, handle: i32);
}

/// Refuse every network call. This is the real policy gate, not a mock —
/// the kernel must degrade gracefully (default-deny, A9) and surface denial to
/// the agent as an ordinary command error.
pub struct DeniedNet;

impl NetCapability for DeniedNet {
    fn http_request(&mut self, _req: &[u8]) -> i32 {
        -1
    }
    fn http_poll(&mut self, _h: i32, _buf: &mut [u8]) -> i32 {
        -1
    }
    fn http_body(&mut self, _h: i32, _buf: &mut [u8]) -> i32 {
        -1
    }
    fn http_close(&mut self, _h: i32) {}
    fn ws_connect(&mut self, _url: &str) -> i32 {
        -1
    }
    fn ws_send(&mut self, _h: i32, _data: &[u8]) -> i32 {
        -1
    }
    /// A denied send errors immediately, so a parked write must never block on a denied socket:
    /// report writable-to-error (1) so it wakes and surfaces the denial (mirrors JS `DeniedNet`).
    fn ws_ready(&mut self, _h: i32) -> i32 {
        1
    }
    fn ws_recv(&mut self, _h: i32, _buf: &mut [u8]) -> i32 {
        -1
    }
    fn ws_close(&mut self, _h: i32) {}
}

#[derive(Default)]
struct HttpSlot {
    done: bool,
    failed: bool,
    head: Vec<u8>,
    body: Vec<u8>,
    body_pos: usize,
}

/// Real network egress. Each in-flight request is a background thread
/// buffering into a shared slot; the bridge calls read the slot.
pub struct RealNet {
    next_handle: i32,
    http: HashMap<i32, Arc<Mutex<HttpSlot>>>,
    ws: HashMap<i32, Arc<Mutex<WsSlot>>>,
    connections: ConnectionRegistry,
}

impl RealNet {
    pub fn new() -> Self {
        Self {
            next_handle: 1,
            http: HashMap::new(),
            ws: HashMap::new(),
            connections: ConnectionRegistry::new(),
        }
    }

    pub fn with_connections(mut self, connections: ConnectionRegistry) -> Self {
        self.connections = connections;
        self
    }
}

impl Default for RealNet {
    fn default() -> Self {
        Self::new()
    }
}

impl NetCapability for RealNet {
    fn http_request(&mut self, req: &[u8]) -> i32 {
        let req = match self.connections.inject_http_request(req) {
            Ok(req) => req,
            Err(_) => return -1,
        };
        let Some((method, url, headers, body)) = parse_blob(&req) else {
            return -1;
        };
        let slot = Arc::new(Mutex::new(HttpSlot::default()));
        let worker = Arc::clone(&slot);
        thread::spawn(move || {
            let mut r = ureq::request(&method, &url);
            for (k, v) in &headers {
                // ureq derives Content-Length from the body itself.
                if !k.eq_ignore_ascii_case("content-length") {
                    r = r.set(k, v);
                }
            }
            let result = if body.is_empty() {
                r.call()
            } else {
                r.send_bytes(&body)
            };
            // 4xx/5xx are still real responses worth delivering (the agent
            // wants the body and the status); only transport errors fail.
            let resp = match result {
                Ok(resp) => Some(resp),
                Err(ureq::Error::Status(_code, resp)) => Some(resp),
                Err(ureq::Error::Transport(_)) => None,
            };
            let mut s = worker.lock().unwrap();
            match resp {
                Some(resp) => {
                    let status = resp.status();
                    let reason = resp.status_text().to_string();
                    let mut head = format!("{status} {reason}\r\n").into_bytes();
                    for name in resp.headers_names() {
                        if let Some(v) = resp.header(&name) {
                            head.extend_from_slice(format!("{name}: {v}\r\n").as_bytes());
                        }
                    }
                    head.extend_from_slice(b"\r\n");
                    let mut body_buf = Vec::new();
                    let read_ok = resp.into_reader().read_to_end(&mut body_buf).is_ok();
                    s.head = head;
                    s.body = body_buf;
                    s.failed = !read_ok;
                    s.done = true;
                }
                None => {
                    s.failed = true;
                    s.done = true;
                }
            }
        });
        let h = self.next_handle;
        self.next_handle += 1;
        self.http.insert(h, slot);
        h
    }

    fn http_poll(&mut self, h: i32, buf: &mut [u8]) -> i32 {
        slot_http_poll(&self.http, h, buf)
    }

    fn http_body(&mut self, h: i32, buf: &mut [u8]) -> i32 {
        slot_http_body(&self.http, h, buf)
    }

    fn http_close(&mut self, h: i32) {
        self.http.remove(&h);
    }

    fn ws_connect(&mut self, url: &str) -> i32 {
        let slot = Arc::new(Mutex::new(WsSlot::default()));
        let worker = Arc::clone(&slot);
        let url = url.to_string();
        thread::spawn(move || ws_relay(url, worker));
        let h = self.next_handle;
        self.next_handle += 1;
        self.ws.insert(h, slot);
        h
    }

    fn ws_send(&mut self, h: i32, data: &[u8]) -> i32 {
        slot_ws_send(&self.ws, h, data)
    }

    fn ws_ready(&mut self, h: i32) -> i32 {
        slot_ws_ready(&self.ws, h)
    }

    fn ws_recv(&mut self, h: i32, buf: &mut [u8]) -> i32 {
        slot_ws_recv(&self.ws, h, buf)
    }

    fn ws_close(&mut self, h: i32) {
        if let Some(slot) = self.ws.remove(&h) {
            slot.lock().unwrap().close_req = true;
        }
    }
}

// The bridge calls that just read the shared slots are independent of the
// worker that fills the slot, so they live here as free helpers.

fn slot_http_poll(http: &HashMap<i32, Arc<Mutex<HttpSlot>>>, h: i32, buf: &mut [u8]) -> i32 {
    let Some(slot) = http.get(&h) else {
        return -1;
    };
    let s = slot.lock().unwrap();
    if !s.done {
        return 0;
    }
    if s.failed {
        return -1;
    }
    let n = s.head.len().min(buf.len());
    buf[..n].copy_from_slice(&s.head[..n]);
    n as i32
}

fn slot_http_body(http: &HashMap<i32, Arc<Mutex<HttpSlot>>>, h: i32, buf: &mut [u8]) -> i32 {
    let Some(slot) = http.get(&h) else {
        return -1;
    };
    let mut s = slot.lock().unwrap();
    if !s.done {
        return 0;
    }
    if s.failed {
        return -1;
    }
    let start = s.body_pos;
    let remaining = s.body.len() - start;
    if remaining == 0 {
        return 0; // EOF
    }
    let n = remaining.min(buf.len());
    buf[..n].copy_from_slice(&s.body[start..start + n]);
    s.body_pos += n;
    n as i32
}

fn slot_ws_send(ws: &HashMap<i32, Arc<Mutex<WsSlot>>>, h: i32, data: &[u8]) -> i32 {
    let Some(slot) = ws.get(&h) else {
        return -1;
    };
    let mut s = slot.lock().unwrap();
    if s.closed {
        return -1; // closed → the write errors out
    }
    if data.len() > WS_SEND_MARK {
        return -EMSGSIZE; // permanent: this frame can never fit the host window
    }
    // A pre-handshake socket cannot accept (matching JS CONNECTING), and a send
    // that would cross the mark must park until the relay drains enough room.
    // Since oversized frames already failed above, every `-EAGAIN` can make
    // progress later; the host buffers NOTHING extra and keeps the queued hold
    // within the flow-control window (A1/B5).
    if !s.open || s.queued_bytes + data.len() > WS_SEND_MARK {
        return -EAGAIN;
    }
    s.queued_bytes += data.len();
    s.outgoing.push_back(data.to_vec());
    data.len() as i32
}

/// Write-readiness for a parked guest write (the dual of `recv` probing the read
/// side): `1` if a `ws_send` would make progress (queue below the mark) OR the
/// socket is closed/unknown (so the parked write WAKES and errors out — POSIX: a
/// closed socket is write-ready), `0` only while genuinely would-block (queue at/
/// above the mark). Never-true would hang the guest; true-while-would-block would
/// busy-loop it.
fn slot_ws_ready(ws: &HashMap<i32, Arc<Mutex<WsSlot>>>, h: i32) -> i32 {
    let Some(slot) = ws.get(&h) else {
        return 1; // unknown handle → wake-to-error, never park
    };
    let s = slot.lock().unwrap();
    if s.closed || (s.open && s.queued_bytes < WS_SEND_MARK) {
        1
    } else {
        0
    }
}

fn slot_ws_recv(ws: &HashMap<i32, Arc<Mutex<WsSlot>>>, h: i32, buf: &mut [u8]) -> i32 {
    let Some(slot) = ws.get(&h) else {
        return -1;
    };
    let mut s = slot.lock().unwrap();
    let front_len = match s.incoming.front() {
        Some(f) => f.len(),
        None => return if s.closed { -1 } else { 0 },
    };
    let n = (front_len - s.front_pos).min(buf.len());
    let start = s.front_pos;
    buf[..n].copy_from_slice(&s.incoming.front().unwrap()[start..start + n]);
    s.front_pos += n;
    if s.front_pos >= front_len {
        s.incoming.pop_front();
        s.front_pos = 0;
    }
    n as i32
}

/// Flow-control mark for egress backpressure (the wasmtime dual of the JS host's
/// `WS_SEND_MARK`): the relay stops draining `outgoing` into the socket once the
/// socket would-block, so `outgoing` fills; `ws_send` accepts a whole message only
/// when `queued_bytes + len <= WS_SEND_MARK`. This bounds the relay queue at the
/// mark (A1) and turns a slow/stuck peer into real backpressure on the guest
/// instead of host memory growth.
const WS_SEND_MARK: usize = 1024 * 1024;

#[derive(Default)]
struct WsSlot {
    /// The relay has completed the host WebSocket handshake. Before this point,
    /// send/ready must mirror JS CONNECTING: `-EAGAIN` / not writable.
    open: bool,
    /// Messages accepted from the guest but not yet handed to the socket. Bounded
    /// by `WS_SEND_MARK` via `queued_bytes`; the relay only drains it while the
    /// socket can actually accept (so it reflects real transport backpressure).
    outgoing: VecDeque<Vec<u8>>,
    /// Sum of the byte lengths currently in `outgoing` — the flow-control gauge.
    queued_bytes: usize,
    incoming: VecDeque<Vec<u8>>,
    /// Read offset into the front incoming message (messages may be larger
    /// than one kernel recv buffer).
    front_pos: usize,
    closed: bool,
    close_req: bool,
}

/// Real WebSocket relay thread (one per connection). Does the real handshake
/// (and TLS for `wss`) via tungstenite, then pumps the shared queues with a
/// non-blocking socket so both directions make progress.
fn ws_relay(url: String, slot: Arc<Mutex<WsSlot>>) {
    use tungstenite::Message;

    let mut socket = match tungstenite::connect(&url) {
        Ok((s, _resp)) => s,
        Err(_) => {
            slot.lock().unwrap().closed = true;
            return;
        }
    };
    if let Some(tcp) = inner_tcp(socket.get_ref()) {
        let _ = tcp.set_nonblocking(true);
    }
    slot.lock().unwrap().open = true;

    loop {
        // Pump queued messages into the socket, but only WHILE it can actually accept:
        // gate each pull on a successful FLUSH (an empty tungstenite send buffer ⇒ the
        // socket is writable). The moment a flush would block, the socket is full — STOP
        // pulling, leaving everything in `outgoing` so the queue (and `queued_bytes`)
        // backs up and exerts real backpressure (`ws_send` → -EAGAIN; the guest's write
        // parks, its bytes staying in the guest's own memory, B5). This bounds the
        // relay queue at WS_SEND_MARK; using `write` (queue) + `flush`
        // (drain) rather than `send` (= write + flush) is exactly what lets the leading
        // flush be the gate: a plain `send` would shovel the whole queue into tungstenite's
        // own buffer even with the socket stuck, defeating the bound.
        loop {
            match socket.flush() {
                Ok(()) => {}
                // Socket full: don't pull more — `outgoing` stays put and backs up.
                Err(tungstenite::Error::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    break;
                }
                Err(_) => {
                    slot.lock().unwrap().closed = true;
                    return;
                }
            }
            // Flush succeeded (buffer empty) → the socket can take a frame; pull one.
            let next = {
                let mut s = slot.lock().unwrap();
                match s.outgoing.pop_front() {
                    Some(data) => {
                        s.queued_bytes = s.queued_bytes.saturating_sub(data.len());
                        Some(data)
                    }
                    None => None,
                }
            };
            let Some(data) = next else { break };
            let msg = match std::str::from_utf8(&data) {
                Ok(t) => Message::text(t),
                Err(_) => Message::binary(data),
            };
            match socket.write(msg) {
                // Queued (and partly written); the next iteration's flush drains it, or
                // stops pulling once the socket has filled.
                Ok(()) => {}
                Err(tungstenite::Error::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => {
                    slot.lock().unwrap().closed = true;
                    return;
                }
            }
        }
        // A final drain attempt for the last written frame (harmless if already flushed).
        let _ = socket.flush();

        let close_req = slot.lock().unwrap().close_req;
        if close_req {
            let _ = socket.close(None);
            let _ = socket.flush();
            slot.lock().unwrap().closed = true;
            return;
        }

        match socket.read() {
            Ok(Message::Text(t)) => slot
                .lock()
                .unwrap()
                .incoming
                .push_back(t.as_bytes().to_vec()),
            Ok(Message::Binary(b)) => slot.lock().unwrap().incoming.push_back(b.to_vec()),
            Ok(Message::Close(_)) => {
                slot.lock().unwrap().closed = true;
                return;
            }
            // Ping/Pong/Frame: tungstenite queues the pong itself.
            Ok(_) => {}
            Err(tungstenite::Error::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => {
                slot.lock().unwrap().closed = true;
                return;
            }
        }

        thread::sleep(Duration::from_millis(2));
    }
}

/// Reach the underlying `TcpStream` of a (possibly TLS) tungstenite stream so
/// we can set it non-blocking.
fn inner_tcp(s: &tungstenite::stream::MaybeTlsStream<TcpStream>) -> Option<&TcpStream> {
    use tungstenite::stream::MaybeTlsStream;
    match s {
        MaybeTlsStream::Plain(t) => Some(t),
        MaybeTlsStream::Rustls(r) => Some(r.get_ref()),
        _ => None,
    }
}

/// Parse the kernel's request blob: `METHOD URL\n` + `Header: v\n` lines + a
/// blank line + body. Returns `(method, url, headers, body)`.
fn parse_blob(req: &[u8]) -> Option<(String, String, Vec<(String, String)>, Vec<u8>)> {
    let sep = req.windows(2).position(|w| w == b"\n\n")?;
    let head = &req[..sep];
    let body = req.get(sep + 2..).unwrap_or(&[]).to_vec();
    let head_str = std::str::from_utf8(head).ok()?;
    let mut lines = head_str.split('\n');
    let first = lines.next()?;
    let (method, url) = first.split_once(' ')?;
    let mut headers = Vec::new();
    for line in lines {
        if line.is_empty() {
            continue;
        }
        if let Some((k, v)) = line.split_once(':') {
            headers.push((k.trim().to_string(), v.trim().to_string()));
        }
    }
    Some((method.to_string(), url.to_string(), headers, body))
}

// ── TokioNet — the async, runtime-integrated egress capability ───────────────
// Behind the `tokio-net` feature so the CLI build never pulls an async HTTP client; the
// async host (the mc-server, axum/tokio) enables it.

/// Real network egress over the Tokio runtime. Identical slot/poll contract to `RealNet`,
/// but each HTTP request is a cheap `reqwest` FUTURE (not an OS thread), so thousands can be
/// in flight at once. WebSocket reuses the proven sync relay on the runtime's BOUNDED
/// blocking pool (long-lived, low fan-out).
#[cfg(feature = "tokio-net")]
pub struct TokioNet {
    handle: tokio::runtime::Handle,
    client: reqwest::Client,
    next_handle: i32,
    http: HashMap<i32, Arc<Mutex<HttpSlot>>>,
    ws: HashMap<i32, Arc<Mutex<WsSlot>>>,
    connections: ConnectionRegistry,
}

#[cfg(feature = "tokio-net")]
impl TokioNet {
    /// Build over the ambient Tokio runtime — call from inside it (e.g. the per-VM actor
    /// task) so `tokio::runtime::Handle::current()` is valid.
    pub fn new(handle: tokio::runtime::Handle) -> Self {
        Self {
            handle,
            client: reqwest::Client::builder()
                .build()
                .expect("build reqwest client"),
            next_handle: 1,
            http: HashMap::new(),
            ws: HashMap::new(),
            connections: ConnectionRegistry::new(),
        }
    }

    pub fn with_connections(mut self, connections: ConnectionRegistry) -> Self {
        self.connections = connections;
        self
    }
}

#[cfg(feature = "tokio-net")]
impl NetCapability for TokioNet {
    fn http_request(&mut self, req: &[u8]) -> i32 {
        let req = match self.connections.inject_http_request(req) {
            Ok(req) => req,
            Err(_) => return -1,
        };
        let Some((method, url, headers, body)) = parse_blob(&req) else {
            return -1;
        };
        let slot = Arc::new(Mutex::new(HttpSlot::default()));
        let worker = Arc::clone(&slot);
        let client = self.client.clone();
        self.handle
            .spawn(async move { http_worker(client, method, url, headers, body, worker).await });
        let h = self.next_handle;
        self.next_handle += 1;
        self.http.insert(h, slot);
        h
    }

    fn http_poll(&mut self, h: i32, buf: &mut [u8]) -> i32 {
        slot_http_poll(&self.http, h, buf)
    }
    fn http_body(&mut self, h: i32, buf: &mut [u8]) -> i32 {
        slot_http_body(&self.http, h, buf)
    }
    fn http_close(&mut self, h: i32) {
        self.http.remove(&h);
    }

    fn ws_connect(&mut self, url: &str) -> i32 {
        let slot = Arc::new(Mutex::new(WsSlot::default()));
        let worker = Arc::clone(&slot);
        let url = url.to_string();
        // Run the sync tungstenite relay on the runtime's bounded blocking pool (vs an
        // unbounded raw thread). HTTP — the high-fan-out path — is fully async above.
        self.handle.spawn_blocking(move || ws_relay(url, worker));
        let h = self.next_handle;
        self.next_handle += 1;
        self.ws.insert(h, slot);
        h
    }
    fn ws_send(&mut self, h: i32, data: &[u8]) -> i32 {
        slot_ws_send(&self.ws, h, data)
    }
    fn ws_ready(&mut self, h: i32) -> i32 {
        slot_ws_ready(&self.ws, h)
    }
    fn ws_recv(&mut self, h: i32, buf: &mut [u8]) -> i32 {
        slot_ws_recv(&self.ws, h, buf)
    }
    fn ws_close(&mut self, h: i32) {
        if let Some(slot) = self.ws.remove(&h) {
            slot.lock().unwrap().close_req = true;
        }
    }
}

/// Perform one HTTP request as an async future, buffering the full response into the shared
/// slot (mirrors `RealNet`'s thread worker). 4xx/5xx are delivered (the agent wants the body
/// + status); only a transport error sets `failed`.
#[cfg(feature = "tokio-net")]
async fn http_worker(
    client: reqwest::Client,
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: Vec<u8>,
    slot: Arc<Mutex<HttpSlot>>,
) {
    let method = reqwest::Method::from_bytes(method.as_bytes()).unwrap_or(reqwest::Method::GET);
    let mut rb = client.request(method, &url);
    for (k, v) in &headers {
        // reqwest sets Content-Length from the body itself.
        if !k.eq_ignore_ascii_case("content-length") {
            rb = rb.header(k, v);
        }
    }
    if !body.is_empty() {
        rb = rb.body(body);
    }
    let resp = match rb.send().await {
        Ok(r) => r,
        Err(_) => {
            let mut s = slot.lock().unwrap();
            s.failed = true;
            s.done = true;
            return;
        }
    };
    let status = resp.status();
    let mut head = format!(
        "{} {}\r\n",
        status.as_u16(),
        status.canonical_reason().unwrap_or("")
    )
    .into_bytes();
    for (name, value) in resp.headers() {
        if let Ok(v) = value.to_str() {
            head.extend_from_slice(format!("{name}: {v}\r\n").as_bytes());
        }
    }
    head.extend_from_slice(b"\r\n");
    let body_result = resp.bytes().await;
    let mut s = slot.lock().unwrap();
    s.head = head;
    match body_result {
        Ok(b) => s.body = b.to_vec(),
        Err(_) => s.failed = true,
    }
    s.done = true;
}
