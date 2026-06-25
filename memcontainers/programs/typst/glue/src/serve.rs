//! Service mode: the warm `svc_serve` loop. Fonts load once into [`Warm`]; each `compile` builds a
//! per-request [`CompileWorld`], runs `typst::compile` + `typst_pdf::pdf`, and STREAMS the PDF back
//! through the bounded-buffer protocol — `svc_respond` returns `EAGAIN` at the kernel high-water, so the
//! response is parked and resumed on the `DrainReady` the kernel delivers, never blocking other clients.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use sysroot as rt;

use typst::diag::{SourceDiagnostic, Warned};
use typst::layout::PagedDocument;
use typst::syntax::Span;
use typst::World;
use typst_pdf::PdfOptions;

use crate::proto::{frame, Diagnostic, Header, Request, PROTO_VERSION};
use crate::world::{CompileWorld, Warm};

const SERVICE_NAME: &str = "typst";

/// The compiler version reported by `op:"version"` and the CLI's `--version` (matches the `typst` dep).
pub const TYPST_VERSION: &str = "0.14.2";

/// Per-respond chunk; well under the 64 KiB kernel high-water so a chunk always fits when the buffer is
/// drained. The PDF is produced whole, so streaming just paces an in-memory buffer to the kernel.
const CHUNK: usize = 32 * 1024;

/// The recv buffer: a request envelope plus a blob up to the kernel's ~1 MiB `svc_call` cap (an inline
/// source bigger than this should arrive as a `main` file path instead; the CLI always uses `main`).
const MAX_REQ: usize = 1024 * 1024 + 64 * 1024;

/// A response being streamed to one in-flight `(session, req_id)`. The whole frame is built up front;
/// `offset` tracks how much the kernel has accepted.
struct PdfStream {
    frame: Vec<u8>,
    offset: usize,
}

enum Pump {
    Done,
    Parked,
    Failed,
}

/// Run the resident service. Never returns (exits when the channel closes).
pub fn run() -> ! {
    let warm = Warm::load();
    if warm.fonts_empty() {
        // Keep serving — each compile then returns a clear diagnostic — but make the cause visible in
        // the service's stderr too.
        eprintln!("typst: no fonts found under /usr/share/fonts (the paper font layer is missing)");
    }

    let server = match rt::svc_serve(SERVICE_NAME) {
        Ok(fd) => fd,
        Err(_) => std::process::exit(1),
    };
    let mut buf = vec![0u8; MAX_REQ];
    let mut hbuf = [0i32; 0]; // typst accepts no delegated handles
    let mut parked: BTreeMap<(u32, u32), PdfStream> = BTreeMap::new();

    loop {
        let n = match rt::svc_recv(server, &mut buf, &mut hbuf) {
            Ok(n) => n,
            Err(_) => std::process::exit(0), // channel closed: nothing more to serve
        };
        let Some(req) = rt::parse_svc_request(&buf[..n], &hbuf) else {
            continue;
        };
        match req.kind {
            rt::SvcKind::Call => {
                let key = (req.session, req.req_id);
                let resp = handle_call(&warm, req.blob);
                let mut stream = PdfStream {
                    frame: resp,
                    offset: 0,
                };
                if let Pump::Parked = pump(server, key, &mut stream) {
                    parked.insert(key, stream);
                }
            }
            rt::SvcKind::DrainReady => {
                let key = (req.session, req.req_id);
                if let Some(mut stream) = parked.remove(&key) {
                    if let Pump::Parked = pump(server, key, &mut stream) {
                        parked.insert(key, stream);
                    }
                }
            }
            rt::SvcKind::SessionClosed => {
                // The client went away — drop any response still parked for that session.
                parked.retain(|&(session, _), _| session != req.session);
            }
        }
    }
}

/// Send chunks until the kernel buffer backs up (`EAGAIN` → park) or the frame is fully delivered.
fn pump(server: i32, key: (u32, u32), stream: &mut PdfStream) -> Pump {
    loop {
        let remaining = stream.frame.len() - stream.offset;
        let chunk = remaining.min(CHUNK);
        let last = stream.offset + chunk == stream.frame.len();
        let data = &stream.frame[stream.offset..stream.offset + chunk];
        match rt::svc_respond(server, key.0, key.1, 0, data, last) {
            Ok(()) => {
                stream.offset += chunk;
                if last {
                    return Pump::Done;
                }
            }
            Err(e) if e == rt::EAGAIN => return Pump::Parked,
            Err(_) => return Pump::Failed, // transport error: drop the stream
        }
    }
}

/// Decode the request and dispatch. Always returns a complete response frame (errors included).
fn handle_call(warm: &Warm, blob: &[u8]) -> Vec<u8> {
    let req: Request = match serde_json::from_slice(blob) {
        Ok(r) => r,
        Err(_) => return frame(&Header::fail("invalid request JSON"), &[]),
    };
    if req.v != PROTO_VERSION {
        return frame(&Header::fail("unsupported protocol version"), &[]);
    }
    match req.op.as_str() {
        "compile" => compile(warm, &req),
        "version" => frame(
            &Header {
                ok: true,
                diagnostics: Vec::new(),
            },
            TYPST_VERSION.as_bytes(),
        ),
        other => frame(&Header::fail(&format!("unknown op: {other}")), &[]),
    }
}

/// Compile one request to a PDF frame. Warnings ride a successful header; errors a failed one.
fn compile(warm: &Warm, req: &Request) -> Vec<u8> {
    let world = match build_world(warm, req) {
        Ok(w) => w,
        Err(msg) => return frame(&Header::fail(&msg), &[]),
    };

    let Warned { output, warnings } = typst::compile::<PagedDocument>(&world);
    let document = match output {
        Ok(doc) => doc,
        Err(errors) => {
            return frame(
                &Header {
                    ok: false,
                    diagnostics: collect(&world, &errors, "error"),
                },
                &[],
            )
        }
    };

    let pdf = match typst_pdf::pdf(&document, &PdfOptions::default()) {
        Ok(bytes) => bytes,
        Err(errors) => {
            return frame(
                &Header {
                    ok: false,
                    diagnostics: collect(&world, &errors, "error"),
                },
                &[],
            )
        }
    };

    frame(
        &Header {
            ok: true,
            diagnostics: collect(&world, &warnings, "warning"),
        },
        &pdf,
    )
}

/// Build the per-request world from the request — inline source XOR a VFS `main` path.
fn build_world<'a>(warm: &'a Warm, req: &Request) -> Result<CompileWorld<'a>, String> {
    let root = req.root.as_ref().map(PathBuf::from);
    match (&req.source, &req.main) {
        (Some(text), None) => Ok(CompileWorld::inline(
            warm,
            text.clone(),
            root.unwrap_or_else(|| PathBuf::from("/")),
        )),
        (None, Some(path)) => CompileWorld::file(warm, Path::new(path), root),
        (Some(_), Some(_)) => Err("request sets both `source` and `main`; set exactly one".into()),
        (None, None) => Err("request sets neither `source` nor `main`; set exactly one".into()),
    }
}

/// Turn typst diagnostics into the protocol's structured form, resolving spans to `file:line:col`.
fn collect(world: &CompileWorld, diags: &[SourceDiagnostic], severity: &str) -> Vec<Diagnostic> {
    diags
        .iter()
        .map(|d| {
            let (file, line, col) = match span_location(world, d.span) {
                Some((f, l, c)) => (Some(f), Some(l), Some(c)),
                None => (None, None, None),
            };
            Diagnostic {
                severity: severity.to_string(),
                message: d.message.to_string(),
                file,
                line,
                col,
                hints: d.hints.iter().map(|h| h.to_string()).collect(),
            }
        })
        .collect()
}

/// Resolve a [`Span`] to `(file, 1-based line, 1-based column)`, or `None` for a detached span.
fn span_location(world: &CompileWorld, span: Span) -> Option<(String, usize, usize)> {
    let id = span.id()?;
    let source = world.source(id).ok()?;
    let range = source.range(span)?;
    let (line, col) = source.lines().byte_to_line_column(range.start)?;
    let name = id.vpath().as_rootless_path().display().to_string();
    Some((name, line + 1, col + 1))
}
