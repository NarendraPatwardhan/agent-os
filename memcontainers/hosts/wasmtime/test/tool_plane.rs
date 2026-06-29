use std::collections::BTreeMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use host::{
    CaptureSink, CatalogConnection, CatalogInjectOptions, CatalogSpecSource, ConnectionCredential,
    ConnectionRegistry, KernelHostBuilder, NetCapability, RealNet, ToolApprovalDecision,
    ToolApprovalFacts, ToolApprover, ToolPolicyAction, ToolPolicyOwner, ToolPolicyRule,
};

#[derive(Debug, Clone)]
struct RecordedRequest {
    method: String,
    path: String,
    headers: BTreeMap<String, String>,
}

struct RecordingServer {
    origin: String,
    requests: Arc<Mutex<Vec<RecordedRequest>>>,
    stop: Arc<AtomicBool>,
    join: Option<thread::JoinHandle<()>>,
}

impl RecordingServer {
    fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind recording server");
        listener
            .set_nonblocking(true)
            .expect("set recording server nonblocking");
        let port = listener.local_addr().unwrap().port();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let worker_requests = Arc::clone(&requests);
        let worker_stop = Arc::clone(&stop);
        let join = thread::spawn(move || {
            while !worker_stop.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, _)) => handle_http(stream, &worker_requests),
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2));
                    }
                    Err(_) => break,
                }
            }
        });
        Self {
            origin: format!("http://127.0.0.1:{port}"),
            requests,
            stop,
            join: Some(join),
        }
    }

    fn clear(&self) {
        self.requests.lock().unwrap().clear();
    }

    fn snapshot(&self) -> Vec<RecordedRequest> {
        self.requests.lock().unwrap().clone()
    }
}

impl Drop for RecordingServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = TcpStream::connect(self.origin.strip_prefix("http://").unwrap());
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

fn handle_http(mut stream: TcpStream, requests: &Arc<Mutex<Vec<RecordedRequest>>>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    let mut header_end = None;
    let mut content_len = 0usize;
    loop {
        let Ok(n) = stream.read(&mut tmp) else { return };
        if n == 0 {
            return;
        }
        buf.extend_from_slice(&tmp[..n]);
        if header_end.is_none() {
            header_end = find_bytes(&buf, b"\r\n\r\n").map(|i| i + 4);
            if let Some(end) = header_end {
                let head = String::from_utf8_lossy(&buf[..end]).to_string();
                content_len = head
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse::<usize>().ok())
                            .flatten()
                    })
                    .unwrap_or(0);
            }
        }
        if let Some(end) = header_end {
            if buf.len() >= end + content_len {
                break;
            }
        }
    }
    let end = header_end.unwrap();
    let head = String::from_utf8_lossy(&buf[..end]).to_string();
    let mut lines = head.lines();
    let first = lines.next().unwrap_or("");
    let mut first_parts = first.split_whitespace();
    let method = first_parts.next().unwrap_or("").to_string();
    let path = first_parts.next().unwrap_or("").to_string();
    let mut headers = BTreeMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.to_ascii_lowercase(), value.trim().to_string());
        }
    }
    requests.lock().unwrap().push(RecordedRequest {
        method,
        path,
        headers,
    });
    let body = br#"{"marker":"rust-host-adapter","ok":true}"#;
    let response = format!(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.write_all(body);
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

#[derive(Clone)]
struct SharedApprover {
    prompts: Arc<Mutex<Vec<ToolApprovalFacts>>>,
    allow: Arc<AtomicBool>,
}

impl ToolApprover for SharedApprover {
    fn approve(&self, facts: ToolApprovalFacts) -> ToolApprovalDecision {
        self.prompts.lock().unwrap().push(facts);
        ToolApprovalDecision {
            allow: self.allow.load(Ordering::SeqCst),
            remember_session: false,
        }
    }
}

fn runfile(path: &str) -> PathBuf {
    let r = runfiles::Runfiles::create().expect("runfiles unavailable");
    r.rlocation(path)
        .unwrap_or_else(|| panic!("{path} not found in runfiles"))
}

fn read_runfile(path: &str) -> Vec<u8> {
    std::fs::read(runfile(path)).unwrap_or_else(|e| panic!("read {path}: {e}"))
}

fn exec_stdout(host: &mut host::KernelHost, cmd: &str) -> String {
    let result = host.exec(cmd, 2_000_000).expect("exec command");
    assert_eq!(
        result.exit_code,
        0,
        "{cmd}: stderr={}",
        String::from_utf8_lossy(&result.stderr)
    );
    String::from_utf8(result.stdout).expect("stdout utf8")
}

fn configured_net(
    origin: &str,
    approver: SharedApprover,
    policies: Vec<ToolPolicyRule>,
) -> RealNet {
    let mut registry = ConnectionRegistry::new();
    registry
        .insert(
            "github.org.main",
            ConnectionCredential::Bearer {
                token: "fixture-token".to_string(),
            },
            [origin.to_string()],
        )
        .expect("insert connection");
    RealNet::new()
        .with_connections(registry)
        .with_tool_policies(policies)
        .expect("tool policies")
        .with_tool_approver(Arc::new(approver))
}

#[test]
fn injects_catalog_and_gates_connection_egress() {
    let server = RecordingServer::start();
    let prompts = Arc::new(Mutex::new(Vec::new()));
    let allow = Arc::new(AtomicBool::new(true));
    let approver = SharedApprover {
        prompts: Arc::clone(&prompts),
        allow: Arc::clone(&allow),
    };

    let kernel = read_runfile("_main/memcontainers/kernel/rust/kernel.wasm");
    let image = read_runfile("_main/memcontainers/images/loom.tar");
    let compiler = read_runfile("_main/memcontainers/lib/catalog-compiler/catalog-compiler.wasm");
    let fixture = String::from_utf8(read_runfile(
        "_main/memcontainers/lib/catalog-compiler/data/github_issues.openapi.json",
    ))
    .unwrap()
    .replace("https://api.github.com", &server.origin);

    let (sink, _stdout) = CaptureSink::new();
    let mut host = KernelHostBuilder::new(kernel)
        .with_base_image(Some(image))
        .with_stdout(Box::new(sink))
        .with_net(Box::new(configured_net(
            &server.origin,
            approver.clone(),
            Vec::new(),
        )))
        .deterministic()
        .build()
        .expect("boot loom");

    let status = host
        .inject_catalog(CatalogInjectOptions {
            compiler_wasm: compiler,
            generation: 1,
            tools: vec!["github/issues".to_string()],
            host_tools: vec![],
            connections: vec![CatalogConnection {
                reference: "github.org.main".to_string(),
                spec: Some(CatalogSpecSource::Bytes {
                    bytes: fixture.into_bytes(),
                    format: Some("openapi".to_string()),
                    source_format: Some("json".to_string()),
                    base_url: None,
                    endpoint: None,
                }),
                tools: Vec::new(),
            }],
        })
        .expect("inject catalog")
        .expect("catalog status");
    assert_eq!(status.tools, 2);

    let listed = exec_stdout(&mut host, "tools list");
    assert!(listed.contains("github.org.main.issues-list"), "{listed}");
    assert!(listed.contains("github.org.main.issues-create"), "{listed}");
    assert!(!listed.contains("github.org.main.pulls-list"), "{listed}");

    let get = exec_stdout(
        &mut host,
        "tools call github.org.main.issues-list '{\"path\":{\"owner\":\"octo\",\"repo\":\"hello\"},\"query\":{\"state\":\"open\"}}'",
    );
    assert!(get.contains("rust-host-adapter"), "{get}");
    let requests = server.snapshot();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, "GET");
    assert_eq!(requests[0].path, "/repos/octo/hello/issues?state=open");
    assert_eq!(
        requests[0].headers.get("authorization").map(String::as_str),
        Some("Bearer fixture-token")
    );
    assert!(prompts.lock().unwrap().is_empty(), "GET should not prompt");

    server.clear();
    let post = exec_stdout(
        &mut host,
        "tools call github.org.main.issues-create '{\"path\":{\"owner\":\"octo\",\"repo\":\"hello\"},\"body\":{\"title\":\"allow\"}}'",
    );
    assert!(post.contains("rust-host-adapter"), "{post}");
    let prompt = prompts.lock().unwrap().pop().expect("POST prompt");
    assert_eq!(prompt.connection, "github.org.main");
    assert_eq!(prompt.method, "POST");
    assert_eq!(
        prompt.url,
        format!("{}/repos/octo/hello/issues", server.origin)
    );
    assert_eq!(prompt.origin, server.origin);
    assert!(prompt
        .args_digest
        .unwrap()
        .chars()
        .all(|c| c.is_ascii_hexdigit()));
    let requests = server.snapshot();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, "POST");
    assert_eq!(
        requests[0].headers.get("authorization").map(String::as_str),
        Some("Bearer fixture-token")
    );

    server.clear();
    allow.store(false, Ordering::SeqCst);
    let rejected = exec_stdout(
        &mut host,
        "tools call github.org.main.issues-create '{\"path\":{\"owner\":\"octo\",\"repo\":\"hello\"},\"body\":{\"title\":\"reject\"}}'",
    );
    assert!(rejected.contains("declined"), "{rejected}");
    assert!(
        server.snapshot().is_empty(),
        "rejected call reached upstream"
    );

    server.clear();
    allow.store(true, Ordering::SeqCst);
    let bypass_script = format!(
        r#"
local sys = require("sys")
local json = require("json")
local fd = assert(sys.svc.connect("adapters"))
local raw = assert(sys.svc.call(fd, json.encode({{
  op = "invoke",
  adapter = "openapi",
  binding = {{ method = "DELETE", url_template = "{origin}/direct", parameters = {{}} }},
  connection_ref = "github.org.main",
  args = {{}},
}})))
assert(sys.svc.close(fd))
local res = assert(json.decode(raw))
assert(res.ok, raw)
local fetched = assert(sys.net.fetch("{origin}/raw", {{
  method = "DELETE",
  headers = {{ ["X-MC-Connection"] = "github.org.main" }},
}}))
assert(fetched.status == 200, tostring(fetched.status))
print("bypass-ok")
"#,
        origin = server.origin
    );
    host.write_file("/tmp/bypass.luau", bypass_script.as_bytes())
        .expect("write bypass script");
    let bypass = exec_stdout(&mut host, "luau /tmp/bypass.luau");
    assert!(bypass.contains("bypass-ok"), "{bypass}");
    let requests = server.snapshot();
    let seen = requests
        .iter()
        .map(|r| format!("{} {}", r.method, r.path))
        .collect::<Vec<_>>();
    assert!(seen.contains(&"DELETE /direct".to_string()), "{seen:?}");
    assert!(seen.contains(&"DELETE /raw".to_string()), "{seen:?}");
    assert!(requests.iter().all(
        |r| r.headers.get("authorization").map(String::as_str) == Some("Bearer fixture-token")
    ));
}

#[test]
fn host_policy_block_and_approve_match_js_ordering() {
    let server = RecordingServer::start();
    let prompts = Arc::new(Mutex::new(Vec::new()));
    let allow = Arc::new(AtomicBool::new(true));
    let approver = SharedApprover {
        prompts: Arc::clone(&prompts),
        allow: Arc::clone(&allow),
    };
    let block = vec![ToolPolicyRule {
        owner: ToolPolicyOwner::Org,
        pattern: "github.org.main.*".to_string(),
        action: ToolPolicyAction::Block,
    }];
    let mut net = configured_net(&server.origin, approver.clone(), block);
    let req = format!(
        "DELETE {}/blocked\nX-MC-Connection: github.org.main\n\n",
        server.origin
    );
    let handle = net.http_request(req.as_bytes());
    assert!(handle > 0);
    let body = drain_http_body(&mut net, handle);
    assert!(String::from_utf8_lossy(&body).contains("declined"));
    assert!(server.snapshot().is_empty());
    assert!(prompts.lock().unwrap().is_empty());

    let approve = vec![ToolPolicyRule {
        owner: ToolPolicyOwner::Org,
        pattern: "github.org.main.*".to_string(),
        action: ToolPolicyAction::Approve,
    }];
    let mut net = configured_net(&server.origin, approver, approve);
    let req = format!(
        "DELETE {}/approved\nX-MC-Connection: github.org.main\n\n",
        server.origin
    );
    let handle = net.http_request(req.as_bytes());
    assert!(handle > 0);
    let body = drain_http_body(&mut net, handle);
    assert!(String::from_utf8_lossy(&body).contains("rust-host-adapter"));
    let requests = server.snapshot();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].method, "DELETE");
    assert_eq!(requests[0].path, "/approved");
    assert!(prompts.lock().unwrap().is_empty());
}

fn drain_http_body(net: &mut RealNet, handle: i32) -> Vec<u8> {
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut head = [0u8; 2048];
    loop {
        let n = net.http_poll(handle, &mut head);
        if n > 0 {
            break;
        }
        assert!(n == 0, "http_poll failed");
        assert!(Instant::now() < deadline, "http_poll timed out");
        thread::sleep(Duration::from_millis(2));
    }
    let mut out = Vec::new();
    loop {
        let mut buf = [0u8; 2048];
        let n = net.http_body(handle, &mut buf);
        if n == 0 {
            break;
        }
        assert!(n > 0, "http_body failed");
        out.extend_from_slice(&buf[..n as usize]);
    }
    net.http_close(handle);
    out
}
