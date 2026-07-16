#![no_std]
#![no_main]

extern crate alloc;

use alloc::format;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;
use browser_rust as browser;
use constants_rust::{O_CREATE, O_TRUNC, O_WRITE};
use json::{self, Json};
use sidecar_rust as sidecar;
use sysroot as rt;

#[global_allocator]
static ALLOCATOR: talc::wasm::WasmDynamicTalc = talc::wasm::new_wasm_dynamic_allocator();

fn main() {
    let mut buffer = [0_u8; 32 * 1024];
    let count = rt::args_into(&mut buffer);
    let args = buffer[..count]
        .split(|byte| *byte == 0)
        .filter(|value| !value.is_empty())
        .map(|value| String::from_utf8_lossy(value).into_owned())
        .collect();
    match run(args) {
        Ok(value) => {
            rt::print(&json::to_string(&value));
            rt::print("\n");
        }
        Err(message) => {
            rt::eprint("browser: ");
            rt::eprint(&message);
            rt::eprint("\n");
            rt::exit(1);
        }
    }
}

fn run(args: Vec<String>) -> Result<Json, String> {
    if args.len() < 3 {
        return Err(
            "usage: browser GRANT create|retrieve|list|delete|pages OP|computer OP [JSON]".into(),
        );
    }
    let grant = bounded_str("grant", &args[1], sidecar::SIDECAR_MAX_NAME_BYTES, false)?;
    match args[2].as_str() {
        "create" => create(grant, &input(&args, 3)?),
        "retrieve" => retrieve(grant, required_str(&input(&args, 3)?, "id")?),
        "list" => list_json(grant),
        "delete" => delete(grant, required_str(&input(&args, 3)?, "id")?),
        "pages" => pages(grant, args.get(3).map(String::as_str), &input(&args, 4)?),
        "computer" => computer(grant, args.get(3).map(String::as_str), &input(&args, 4)?),
        other => Err(format!("unknown command {other}")),
    }
}

fn create(grant: &str, options: &Json) -> Result<Json, String> {
    if optional_bool(options, "headless")? == Some(false) {
        return Err("browser v1 supports headless sessions only".into());
    }
    let viewport = match options.get("viewport") {
        Some(value) => {
            if value.as_obj().is_none() {
                return Err("viewport must be an object".into());
            }
            let width =
                optional_u32(value, "width")?.unwrap_or(browser::BROWSER_DEFAULT_VIEWPORT_WIDTH);
            let height =
                optional_u32(value, "height")?.unwrap_or(browser::BROWSER_DEFAULT_VIEWPORT_HEIGHT);
            range(
                "viewport.width",
                width,
                browser::BROWSER_MIN_VIEWPORT_EDGE,
                browser::BROWSER_MAX_VIEWPORT_EDGE,
            )?;
            range(
                "viewport.height",
                height,
                browser::BROWSER_MIN_VIEWPORT_EDGE,
                browser::BROWSER_MAX_VIEWPORT_EDGE,
            )?;
            Some(browser::BrowserViewport { width, height })
        }
        None => Some(browser::BrowserViewport {
            width: browser::BROWSER_DEFAULT_VIEWPORT_WIDTH,
            height: browser::BROWSER_DEFAULT_VIEWPORT_HEIGHT,
        }),
    };
    let timeout_seconds = optional_u32(options, "timeoutSeconds")?
        .unwrap_or(browser::BROWSER_DEFAULT_TIMEOUT_SECONDS);
    range(
        "timeoutSeconds",
        timeout_seconds,
        browser::BROWSER_MIN_TIMEOUT_SECONDS,
        browser::BROWSER_MAX_TIMEOUT_SECONDS,
    )?;
    let request = sidecar::SidecarCreate {
        grant: grant.into(),
        kind: browser::BROWSER_KIND.into(),
        body: browser::BrowserCreateOptions {
            headless: true,
            timeout_seconds,
            viewport,
        }
        .encode(),
        idempotency_key: format!(
            "browser-{}-{}",
            rt::getpid(),
            rt::time_monotonic().map_err(|_| "monotonic clock is unavailable")?
        ),
        timeout_ms: i64::from(timeout_seconds) * 1000,
    };
    let instance = sidecar::SidecarInstance::decode(&host_request(&request.encode())?)
        .map_err(|_| "host returned a malformed browser instance")?;
    instance_json(&instance)
}

fn retrieve(grant: &str, id: &str) -> Result<Json, String> {
    instance_json(&resolve(grant, id)?)
}

fn list_json(grant: &str) -> Result<Json, String> {
    let instances = list(grant)?;
    let mut values = Vec::with_capacity(instances.len());
    for instance in instances {
        values.push(instance_json(&instance)?);
    }
    Ok(Json::Arr(values))
}

fn delete(grant: &str, id: &str) -> Result<Json, String> {
    let instance = resolve(grant, id)?;
    host_request(
        &sidecar::SidecarDelete {
            id: instance.id,
            generation: instance.generation,
            grant: grant.into(),
            kind: browser::BROWSER_KIND.into(),
        }
        .encode(),
    )?;
    ok()
}

fn pages(grant: &str, operation: Option<&str>, options: &Json) -> Result<Json, String> {
    let id = required_str(options, "id")?;
    match operation.ok_or("missing pages operation")? {
        "list" => {
            let body = invoke(grant, id, browser::BROWSER_OP_PAGES_LIST, Vec::new())?;
            let pages = browser::BrowserPages::decode(&body)
                .map_err(|_| "browser returned a malformed page list")?;
            let mut values = Vec::with_capacity(pages.items.len());
            for page in &pages.items {
                values.push(page_json(page)?);
            }
            Ok(Json::Arr(values))
        }
        "goto" => {
            let wait = match optional_str(options, "waitUntil")?.unwrap_or("load") {
                "load" => browser::BROWSER_WAIT_LOAD,
                "domcontentloaded" => browser::BROWSER_WAIT_DOM_CONTENT_LOADED,
                "networkidle" => browser::BROWSER_WAIT_NETWORK_IDLE,
                "commit" => browser::BROWSER_WAIT_COMMIT,
                _ => return Err("invalid waitUntil".into()),
            };
            let body = invoke(
                grant,
                id,
                browser::BROWSER_OP_PAGES_GOTO,
                browser::BrowserGotoRequest {
                    page_id: optional_string(options, "pageId")?,
                    url: bounded_required_str(options, "url", browser::BROWSER_MAX_URL_BYTES)?
                        .into(),
                    wait_until: wait,
                }
                .encode(),
            )?;
            let page = browser::BrowserPage::decode(&body)
                .map_err(|_| "browser returned a malformed page")?;
            page_json(&page)
        }
        "title" => string_operation(
            grant,
            id,
            browser::BROWSER_OP_PAGES_TITLE,
            page_target(options)?,
        ),
        "text" => string_operation(
            grant,
            id,
            browser::BROWSER_OP_PAGES_TEXT,
            browser::BrowserLocatorRequest {
                page_id: optional_string(options, "pageId")?,
                selector: bounded_required_str(
                    options,
                    "selector",
                    browser::BROWSER_MAX_SELECTOR_BYTES,
                )?
                .into(),
            }
            .encode(),
        ),
        "click" => {
            invoke(
                grant,
                id,
                browser::BROWSER_OP_PAGES_CLICK,
                browser::BrowserLocatorRequest {
                    page_id: optional_string(options, "pageId")?,
                    selector: bounded_required_str(
                        options,
                        "selector",
                        browser::BROWSER_MAX_SELECTOR_BYTES,
                    )?
                    .into(),
                }
                .encode(),
            )?;
            ok()
        }
        "fill" => {
            invoke(
                grant,
                id,
                browser::BROWSER_OP_PAGES_FILL,
                browser::BrowserFillRequest {
                    page_id: optional_string(options, "pageId")?,
                    selector: bounded_required_str(
                        options,
                        "selector",
                        browser::BROWSER_MAX_SELECTOR_BYTES,
                    )?
                    .into(),
                    value: bounded_str(
                        "value",
                        required_string(options, "value")?,
                        browser::BROWSER_MAX_TEXT_BYTES,
                        true,
                    )?
                    .into(),
                }
                .encode(),
            )?;
            ok()
        }
        other => Err(format!("unknown pages operation {other}")),
    }
}

fn computer(grant: &str, operation: Option<&str>, options: &Json) -> Result<Json, String> {
    let id = required_str(options, "id")?;
    match operation.ok_or("missing computer operation")? {
        "screenshot" => {
            let output = required_str(options, "output")?;
            let body = invoke(
                grant,
                id,
                browser::BROWSER_OP_COMPUTER_SCREENSHOT,
                browser::BrowserScreenshotRequest {
                    page_id: optional_string(options, "pageId")?,
                    full_page: optional_bool(options, "fullPage")?.unwrap_or(false),
                }
                .encode(),
            )?;
            let screenshot = browser::BrowserBytes::decode(&body)
                .map_err(|_| "browser returned a malformed screenshot")?;
            let fd = rt::open(output, O_WRITE | O_CREATE | O_TRUNC)
                .map_err(|_| format!("could not open {output}"))?;
            let result = rt::write_all(fd, &screenshot.value)
                .map_err(|_| format!("could not write {output}"));
            rt::close(fd);
            result?;
            Ok(Json::Obj(vec![
                ("output".into(), Json::Str(output.into())),
                ("bytes".into(), Json::Num(screenshot.value.len() as f64)),
            ]))
        }
        "click" => {
            invoke(
                grant,
                id,
                browser::BROWSER_OP_COMPUTER_CLICK,
                browser::BrowserPointRequest {
                    page_id: optional_string(options, "pageId")?,
                    x: required_u32(options, "x")?,
                    y: required_u32(options, "y")?,
                }
                .encode(),
            )?;
            ok()
        }
        "type" => {
            let delay_ms = optional_u32(options, "delayMs")?.unwrap_or(0);
            range("delayMs", delay_ms, 0, browser::BROWSER_MAX_TYPE_DELAY_MS)?;
            invoke(
                grant,
                id,
                browser::BROWSER_OP_COMPUTER_TYPE,
                browser::BrowserTypeRequest {
                    page_id: optional_string(options, "pageId")?,
                    text: bounded_str(
                        "text",
                        required_string(options, "text")?,
                        browser::BROWSER_MAX_TEXT_BYTES,
                        true,
                    )?
                    .into(),
                    delay_ms,
                }
                .encode(),
            )?;
            ok()
        }
        "key" => {
            invoke(
                grant,
                id,
                browser::BROWSER_OP_COMPUTER_KEY,
                browser::BrowserKeyRequest {
                    page_id: optional_string(options, "pageId")?,
                    key: bounded_required_str(options, "key", browser::BROWSER_MAX_SELECTOR_BYTES)?
                        .into(),
                }
                .encode(),
            )?;
            ok()
        }
        "scroll" => {
            invoke(
                grant,
                id,
                browser::BROWSER_OP_COMPUTER_SCROLL,
                browser::BrowserScrollRequest {
                    page_id: optional_string(options, "pageId")?,
                    delta_x: optional_i32(options, "deltaX")?.unwrap_or(0),
                    delta_y: optional_i32(options, "deltaY")?.unwrap_or(0),
                }
                .encode(),
            )?;
            ok()
        }
        other => Err(format!("unknown computer operation {other}")),
    }
}

fn string_operation(
    grant: &str,
    id: &str,
    operation: &str,
    request: Vec<u8>,
) -> Result<Json, String> {
    let body = invoke(grant, id, operation, request)?;
    let value =
        browser::BrowserString::decode(&body).map_err(|_| "browser returned a malformed string")?;
    bounded_str(
        "browser text",
        &value.value,
        browser::BROWSER_MAX_TEXT_BYTES,
        true,
    )?;
    Ok(Json::Obj(vec![("value".into(), Json::Str(value.value))]))
}

fn page_target(options: &Json) -> Result<Vec<u8>, String> {
    Ok(browser::BrowserPageTarget {
        page_id: optional_string(options, "pageId")?,
    }
    .encode())
}

fn invoke(grant: &str, id: &str, operation: &str, body: Vec<u8>) -> Result<Vec<u8>, String> {
    let instance = resolve(grant, id)?;
    host_request(
        &sidecar::SidecarCall {
            id: instance.id,
            generation: instance.generation,
            grant: grant.into(),
            kind: browser::BROWSER_KIND.into(),
            operation: operation.into(),
            body,
            idempotency_key: None,
            timeout_ms: i64::from(sidecar::SIDECAR_MAX_OPERATION_TIMEOUT_MS),
        }
        .encode(),
    )
}

fn resolve(grant: &str, id: &str) -> Result<sidecar::SidecarInstance, String> {
    bounded_str("browser id", id, sidecar::SIDECAR_MAX_NAME_BYTES, false)?;
    list(grant)?
        .into_iter()
        .find(|instance| instance.id == id)
        .ok_or_else(|| format!("browser instance not found: {id}"))
}

fn list(grant: &str) -> Result<Vec<sidecar::SidecarInstance>, String> {
    let body = host_request(
        &sidecar::SidecarList {
            grant: grant.into(),
            kind: browser::BROWSER_KIND.into(),
        }
        .encode(),
    )?;
    sidecar::SidecarInstances::decode(&body)
        .map(|instances| instances.items)
        .map_err(|_| "host returned a malformed browser list".into())
}

fn host_request(payload: &[u8]) -> Result<Vec<u8>, String> {
    let mut request = Vec::with_capacity(sidecar::SIDECAR_HOST_BINDING.len() + payload.len() + 1);
    request.extend_from_slice(sidecar::SIDECAR_HOST_BINDING.as_bytes());
    request.push(0);
    request.extend_from_slice(payload);
    let fd = rt::host_call(&request).map_err(|_| "sidecar host is unavailable")?;
    let result = read_response(fd);
    rt::close(fd);
    let result = sidecar::SidecarResult::decode(&result?)
        .map_err(|_| "sidecar host returned a malformed response")?;
    if result.ok {
        Ok(result.body)
    } else {
        Err(result
            .error
            .map(|error| format!("{}: {}", error.code, error.message))
            .unwrap_or_else(|| "sidecar request failed".into()))
    }
}

fn read_response(fd: i32) -> Result<Vec<u8>, String> {
    let maximum = sidecar::SIDECAR_MAX_RESULT_BYTES as usize + 64 * 1024;
    let mut output = Vec::new();
    let mut chunk = [0_u8; 32 * 1024];
    loop {
        let count = rt::read(fd, &mut chunk).map_err(|_| "could not read sidecar response")?;
        if count == 0 {
            return Ok(output);
        }
        if output.len().saturating_add(count) > maximum {
            return Err("sidecar response exceeds the CLI limit".into());
        }
        output.extend_from_slice(&chunk[..count]);
    }
}

fn instance_json(instance: &sidecar::SidecarInstance) -> Result<Json, String> {
    let metadata = browser::BrowserMetadata::decode(&instance.metadata)
        .map_err(|_| "host returned malformed browser metadata")?;
    if !metadata.headless {
        return Err("host returned invalid browser metadata".into());
    }
    range(
        "browser viewport width",
        metadata.viewport.width,
        browser::BROWSER_MIN_VIEWPORT_EDGE,
        browser::BROWSER_MAX_VIEWPORT_EDGE,
    )?;
    range(
        "browser viewport height",
        metadata.viewport.height,
        browser::BROWSER_MIN_VIEWPORT_EDGE,
        browser::BROWSER_MAX_VIEWPORT_EDGE,
    )?;
    bounded_str(
        "active page id",
        &metadata.active_page_id,
        browser::BROWSER_MAX_PAGE_ID_BYTES,
        false,
    )?;
    Ok(Json::Obj(vec![
        ("id".into(), Json::Str(instance.id.clone())),
        ("grant".into(), Json::Str(instance.grant.clone())),
        ("state".into(), Json::Str(state(instance.state)?.into())),
        (
            "generation".into(),
            Json::Num(f64::from(instance.generation)),
        ),
        ("headless".into(), Json::Bool(metadata.headless)),
        ("activePageId".into(), Json::Str(metadata.active_page_id)),
        (
            "viewport".into(),
            Json::Obj(vec![
                (
                    "width".into(),
                    Json::Num(f64::from(metadata.viewport.width)),
                ),
                (
                    "height".into(),
                    Json::Num(f64::from(metadata.viewport.height)),
                ),
            ]),
        ),
    ]))
}

fn page_json(page: &browser::BrowserPage) -> Result<Json, String> {
    bounded_str(
        "page id",
        &page.id,
        browser::BROWSER_MAX_PAGE_ID_BYTES,
        false,
    )?;
    bounded_str("page url", &page.url, browser::BROWSER_MAX_URL_BYTES, true)?;
    bounded_str(
        "page title",
        &page.title,
        browser::BROWSER_MAX_TEXT_BYTES,
        true,
    )?;
    Ok(Json::Obj(vec![
        ("id".into(), Json::Str(page.id.clone())),
        ("url".into(), Json::Str(page.url.clone())),
        ("title".into(), Json::Str(page.title.clone())),
    ]))
}

fn state(value: u32) -> Result<&'static str, String> {
    match value {
        sidecar::SIDECAR_STATE_ALLOCATING | sidecar::SIDECAR_STATE_STARTING => Ok("starting"),
        sidecar::SIDECAR_STATE_READY => Ok("ready"),
        sidecar::SIDECAR_STATE_SUSPENDED => Ok("suspended"),
        sidecar::SIDECAR_STATE_FAILED => Ok("failed"),
        sidecar::SIDECAR_STATE_CLOSING => Ok("closing"),
        sidecar::SIDECAR_STATE_CLOSED => Ok("closed"),
        sidecar::SIDECAR_STATE_DETACHED => Ok("detached"),
        _ => Err("host returned an invalid browser state".into()),
    }
}

fn input(args: &[String], index: usize) -> Result<Json, String> {
    let source = args.get(index).map(String::as_str).unwrap_or("{}");
    let parsed = json::parse(source).map_err(|_| "invalid JSON arguments")?;
    if parsed.as_obj().is_none() {
        return Err("arguments must be a JSON object".into());
    }
    Ok(parsed)
}

fn nonempty<'a>(name: &str, value: &'a str) -> Result<&'a str, String> {
    if value.is_empty() {
        Err(format!("{name} is required"))
    } else {
        Ok(value)
    }
}

fn required_str<'a>(value: &'a Json, key: &str) -> Result<&'a str, String> {
    nonempty(
        key,
        value
            .get(key)
            .and_then(Json::as_str)
            .ok_or_else(|| format!("{key} must be a string"))?,
    )
}

fn required_string<'a>(value: &'a Json, key: &str) -> Result<&'a str, String> {
    value
        .get(key)
        .and_then(Json::as_str)
        .ok_or_else(|| format!("{key} must be a string"))
}

fn bounded_required_str<'a>(value: &'a Json, key: &str, maximum: u32) -> Result<&'a str, String> {
    bounded_str(key, required_str(value, key)?, maximum, false)
}

fn bounded_str<'a>(
    key: &str,
    value: &'a str,
    maximum: u32,
    allow_empty: bool,
) -> Result<&'a str, String> {
    if (!allow_empty && value.is_empty()) || value.len() > maximum as usize {
        Err(format!("{key} is empty or too large"))
    } else {
        Ok(value)
    }
}

fn optional_str<'a>(value: &'a Json, key: &str) -> Result<Option<&'a str>, String> {
    value
        .get(key)
        .map(|item| {
            item.as_str()
                .ok_or_else(|| format!("{key} must be a string"))
        })
        .transpose()
}

fn optional_string(value: &Json, key: &str) -> Result<Option<String>, String> {
    optional_str(value, key)?
        .map(|item| bounded_str(key, item, browser::BROWSER_MAX_PAGE_ID_BYTES, false))
        .transpose()
        .map(|item| item.map(String::from))
}

fn optional_bool(value: &Json, key: &str) -> Result<Option<bool>, String> {
    value
        .get(key)
        .map(|item| {
            item.as_bool()
                .ok_or_else(|| format!("{key} must be a boolean"))
        })
        .transpose()
}

fn optional_u32(value: &Json, key: &str) -> Result<Option<u32>, String> {
    value
        .get(key)
        .map(|item| {
            let number = item
                .as_f64()
                .ok_or_else(|| format!("{key} must be an integer"))?;
            let integer = number as u32;
            if f64::from(integer) != number {
                Err(format!("{key} is outside the supported range"))
            } else {
                Ok(integer)
            }
        })
        .transpose()
}

fn range(name: &str, value: u32, minimum: u32, maximum: u32) -> Result<(), String> {
    if value < minimum || value > maximum {
        Err(format!("{name} is outside the supported range"))
    } else {
        Ok(())
    }
}

fn optional_i32(value: &Json, key: &str) -> Result<Option<i32>, String> {
    value
        .get(key)
        .map(|item| {
            let number = item
                .as_f64()
                .ok_or_else(|| format!("{key} must be an integer"))?;
            let integer = number as i32;
            if f64::from(integer) != number {
                Err(format!("{key} is outside the supported range"))
            } else {
                Ok(integer)
            }
        })
        .transpose()
}

fn required_u32(value: &Json, key: &str) -> Result<u32, String> {
    let number = optional_u32(value, key)?.ok_or_else(|| format!("{key} is required"))?;
    if number >= browser::BROWSER_MAX_VIEWPORT_EDGE {
        Err(format!("{key} is outside the supported range"))
    } else {
        Ok(number)
    }
}

fn ok() -> Result<Json, String> {
    Ok(Json::Obj(vec![("ok".into(), Json::Bool(true))]))
}

rt::entry!(main);
