// @generated from contracts/browser.kdl by //contracts/codegen:projector — do not edit.
#![no_std]
#![allow(dead_code)]

pub const PROTOCOL_VERSION: u32 = 1;
pub const BROWSER_KIND: &str = "browser";
pub const BROWSER_CONTRACT_DIGEST: &str = "sha256:467c154dc423f6db81ceabce046c3044e2ca7dd780b4fbb3eb3e26fa29f83fca";
pub const BROWSER_RUNNER_PROFILE: &str = "browser";
pub const BROWSER_VERSION: u32 = 1;
pub const BROWSER_DEFAULT_TIMEOUT_SECONDS: u32 = 300;
pub const BROWSER_MIN_TIMEOUT_SECONDS: u32 = 10;
pub const BROWSER_MAX_TIMEOUT_SECONDS: u32 = 300;
pub const BROWSER_DEFAULT_VIEWPORT_WIDTH: u32 = 1280;
pub const BROWSER_DEFAULT_VIEWPORT_HEIGHT: u32 = 720;
pub const BROWSER_MIN_VIEWPORT_EDGE: u32 = 320;
pub const BROWSER_MAX_VIEWPORT_EDGE: u32 = 4096;
pub const BROWSER_MAX_URL_BYTES: u32 = 16384;
pub const BROWSER_MAX_PAGE_ID_BYTES: u32 = 96;
pub const BROWSER_MAX_SELECTOR_BYTES: u32 = 4096;
pub const BROWSER_MAX_TEXT_BYTES: u32 = 1048576;
pub const BROWSER_MAX_TYPE_DELAY_MS: u32 = 1000;
pub const BROWSER_MAX_PAGES: u32 = 32;
pub const BROWSER_MAX_SCREENSHOT_EDGE: u32 = 16384;
pub const BROWSER_MAX_SCREENSHOT_PIXELS: u32 = 16777216;
pub const BROWSER_WAIT_LOAD: u32 = 1;
pub const BROWSER_WAIT_DOM_CONTENT_LOADED: u32 = 2;
pub const BROWSER_WAIT_NETWORK_IDLE: u32 = 3;
pub const BROWSER_WAIT_COMMIT: u32 = 4;
pub const BROWSER_OP_PAGES_LIST: &str = "pages.list";
pub const BROWSER_OP_PAGES_GOTO: &str = "pages.goto";
pub const BROWSER_OP_PAGES_TITLE: &str = "pages.title";
pub const BROWSER_OP_PAGES_TEXT: &str = "pages.text";
pub const BROWSER_OP_PAGES_CLICK: &str = "pages.click";
pub const BROWSER_OP_PAGES_FILL: &str = "pages.fill";
pub const BROWSER_OP_COMPUTER_SCREENSHOT: &str = "computer.screenshot";
pub const BROWSER_OP_COMPUTER_CLICK: &str = "computer.click";
pub const BROWSER_OP_COMPUTER_TYPE: &str = "computer.type";
pub const BROWSER_OP_COMPUTER_KEY: &str = "computer.key";
pub const BROWSER_OP_COMPUTER_SCROLL: &str = "computer.scroll";

extern crate alloc;
use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WireError { WrongMessage, UnsupportedVersion, Truncated, InvalidUtf8, NonCanonicalMap, InvalidPresence, TrailingBytes }

fn ctl_put_u16(out: &mut Vec<u8>, v: u16) { out.extend_from_slice(&v.to_le_bytes()); }
fn ctl_put_u32(out: &mut Vec<u8>, v: u32) { out.extend_from_slice(&v.to_le_bytes()); }
fn ctl_put_i32(out: &mut Vec<u8>, v: i32) { out.extend_from_slice(&v.to_le_bytes()); }
fn ctl_put_i64(out: &mut Vec<u8>, v: i64) { out.extend_from_slice(&v.to_le_bytes()); }
fn ctl_put_bool(out: &mut Vec<u8>, v: bool) { out.push(if v { 1 } else { 0 }); }
fn ctl_put_bytes(out: &mut Vec<u8>, v: &[u8]) { ctl_put_u32(out, v.len() as u32); out.extend_from_slice(v); }
fn ctl_put_str(out: &mut Vec<u8>, v: &str) { ctl_put_bytes(out, v.as_bytes()); }
fn ctl_put_strmap(out: &mut Vec<u8>, v: &BTreeMap<String, String>) { ctl_put_u32(out, v.len() as u32); for (k, val) in v { ctl_put_str(out, k); ctl_put_str(out, val); } }
fn ctl_put_message_list<T, F>(out: &mut Vec<u8>, values: &[T], mut encode: F) where F: FnMut(&T) -> Vec<u8> { ctl_put_u32(out, values.len() as u32); for value in values { let frame = encode(value); ctl_put_bytes(out, &frame); } }
fn ctl_need<'a>(bytes: &'a [u8], off: &mut usize, len: usize) -> Result<&'a [u8], WireError> { let end = off.checked_add(len).ok_or(WireError::Truncated)?; if end > bytes.len() { return Err(WireError::Truncated); } let out = &bytes[*off..end]; *off = end; Ok(out) }
fn ctl_read_u8(bytes: &[u8], off: &mut usize) -> Result<u8, WireError> { Ok(ctl_need(bytes, off, 1)?[0]) }
fn ctl_read_u16(bytes: &[u8], off: &mut usize) -> Result<u16, WireError> { let b = ctl_need(bytes, off, 2)?; Ok(u16::from_le_bytes([b[0], b[1]])) }
fn ctl_read_u32(bytes: &[u8], off: &mut usize) -> Result<u32, WireError> { let b = ctl_need(bytes, off, 4)?; Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]])) }
fn ctl_read_i32(bytes: &[u8], off: &mut usize) -> Result<i32, WireError> { let b = ctl_need(bytes, off, 4)?; Ok(i32::from_le_bytes([b[0], b[1], b[2], b[3]])) }
fn ctl_read_i64(bytes: &[u8], off: &mut usize) -> Result<i64, WireError> { let b = ctl_need(bytes, off, 8)?; Ok(i64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]])) }
fn ctl_read_bool(bytes: &[u8], off: &mut usize) -> Result<bool, WireError> { match ctl_read_u8(bytes, off)? { 0 => Ok(false), 1 => Ok(true), _ => Err(WireError::InvalidPresence) } }
fn ctl_read_bytes(bytes: &[u8], off: &mut usize) -> Result<Vec<u8>, WireError> { let len = ctl_read_u32(bytes, off)? as usize; Ok(ctl_need(bytes, off, len)?.to_vec()) }
fn ctl_read_str(bytes: &[u8], off: &mut usize) -> Result<String, WireError> { String::from_utf8(ctl_read_bytes(bytes, off)?).map_err(|_| WireError::InvalidUtf8) }
fn ctl_read_strmap(bytes: &[u8], off: &mut usize) -> Result<BTreeMap<String, String>, WireError> { let n = ctl_read_u32(bytes, off)? as usize; if n > bytes.len().saturating_sub(*off) / 8 { return Err(WireError::Truncated); } let mut out = BTreeMap::new(); let mut prev: Option<String> = None; for _ in 0..n { let k = ctl_read_str(bytes, off)?; if prev.as_ref().map_or(false, |p| p >= &k) { return Err(WireError::NonCanonicalMap); } let v = ctl_read_str(bytes, off)?; prev = Some(k.clone()); out.insert(k, v); } Ok(out) }

fn ctl_read_message_list<T, F>(bytes: &[u8], off: &mut usize, mut decode: F) -> Result<Vec<T>, WireError> where F: FnMut(&[u8]) -> Result<T, WireError> { let n = ctl_read_u32(bytes, off)? as usize; if n > bytes.len().saturating_sub(*off) / 4 { return Err(WireError::Truncated); } let mut out = Vec::with_capacity(n); for _ in 0..n { let frame = ctl_read_bytes(bytes, off)?; out.push(decode(&frame)?); } Ok(out) }

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserViewport {
    pub width: u32,
    pub height: u32,
}

pub const BROWSER_VIEWPORT_MSG_ID: u16 = 1;
pub const BROWSER_VIEWPORT_VERSION: u8 = 1;
impl BrowserViewport {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_VIEWPORT_MSG_ID);
        out.push(BROWSER_VIEWPORT_VERSION);
        ctl_put_u32(&mut out, self.width);
        ctl_put_u32(&mut out, self.height);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_VIEWPORT_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_VIEWPORT_VERSION { return Err(WireError::UnsupportedVersion); }
        let width = ctl_read_u32(bytes, &mut off)?;
        let height = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            width,
            height,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserCreateOptions {
    pub headless: bool,
    pub timeout_seconds: u32,
    pub viewport: Option<BrowserViewport>,
}

pub const BROWSER_CREATE_OPTIONS_MSG_ID: u16 = 2;
pub const BROWSER_CREATE_OPTIONS_VERSION: u8 = 1;
impl BrowserCreateOptions {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_CREATE_OPTIONS_MSG_ID);
        out.push(BROWSER_CREATE_OPTIONS_VERSION);
        ctl_put_bool(&mut out, self.headless);
        ctl_put_u32(&mut out, self.timeout_seconds);
        match &self.viewport {
            Some(v) => {
                out.push(1);
        let frame = (v).encode();
        ctl_put_bytes(&mut out, &frame);
            }
            None => out.push(0),
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_CREATE_OPTIONS_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_CREATE_OPTIONS_VERSION { return Err(WireError::UnsupportedVersion); }
        let headless = ctl_read_bool(bytes, &mut off)?;
        let timeout_seconds = ctl_read_u32(bytes, &mut off)?;
        let viewport = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(BrowserViewport::decode(&ctl_read_bytes(bytes, &mut off)?)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            headless,
            timeout_seconds,
            viewport,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserMetadata {
    pub headless: bool,
    pub viewport: BrowserViewport,
    pub active_page_id: String,
}

pub const BROWSER_METADATA_MSG_ID: u16 = 3;
pub const BROWSER_METADATA_VERSION: u8 = 1;
impl BrowserMetadata {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_METADATA_MSG_ID);
        out.push(BROWSER_METADATA_VERSION);
        ctl_put_bool(&mut out, self.headless);
        let frame = (&self.viewport).encode();
        ctl_put_bytes(&mut out, &frame);
        ctl_put_str(&mut out, &self.active_page_id);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_METADATA_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_METADATA_VERSION { return Err(WireError::UnsupportedVersion); }
        let headless = ctl_read_bool(bytes, &mut off)?;
        let viewport = BrowserViewport::decode(&ctl_read_bytes(bytes, &mut off)?)?;
        let active_page_id = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            headless,
            viewport,
            active_page_id,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserPage {
    pub id: String,
    pub url: String,
    pub title: String,
}

pub const BROWSER_PAGE_MSG_ID: u16 = 4;
pub const BROWSER_PAGE_VERSION: u8 = 1;
impl BrowserPage {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_PAGE_MSG_ID);
        out.push(BROWSER_PAGE_VERSION);
        ctl_put_str(&mut out, &self.id);
        ctl_put_str(&mut out, &self.url);
        ctl_put_str(&mut out, &self.title);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_PAGE_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_PAGE_VERSION { return Err(WireError::UnsupportedVersion); }
        let id = ctl_read_str(bytes, &mut off)?;
        let url = ctl_read_str(bytes, &mut off)?;
        let title = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            id,
            url,
            title,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserPages {
    pub items: Vec<BrowserPage>,
}

pub const BROWSER_PAGES_MSG_ID: u16 = 5;
pub const BROWSER_PAGES_VERSION: u8 = 1;
impl BrowserPages {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_PAGES_MSG_ID);
        out.push(BROWSER_PAGES_VERSION);
        ctl_put_message_list(&mut out, &self.items, |v| v.encode());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_PAGES_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_PAGES_VERSION { return Err(WireError::UnsupportedVersion); }
        let items = ctl_read_message_list(bytes, &mut off, BrowserPage::decode)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            items,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserPageTarget {
    pub page_id: Option<String>,
}

pub const BROWSER_PAGE_TARGET_MSG_ID: u16 = 6;
pub const BROWSER_PAGE_TARGET_VERSION: u8 = 1;
impl BrowserPageTarget {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_PAGE_TARGET_MSG_ID);
        out.push(BROWSER_PAGE_TARGET_VERSION);
        match &self.page_id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_PAGE_TARGET_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_PAGE_TARGET_VERSION { return Err(WireError::UnsupportedVersion); }
        let page_id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            page_id,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserGotoRequest {
    pub page_id: Option<String>,
    pub url: String,
    pub wait_until: u32,
}

pub const BROWSER_GOTO_REQUEST_MSG_ID: u16 = 7;
pub const BROWSER_GOTO_REQUEST_VERSION: u8 = 1;
impl BrowserGotoRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_GOTO_REQUEST_MSG_ID);
        out.push(BROWSER_GOTO_REQUEST_VERSION);
        match &self.page_id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_str(&mut out, &self.url);
        ctl_put_u32(&mut out, self.wait_until);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_GOTO_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_GOTO_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let page_id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let url = ctl_read_str(bytes, &mut off)?;
        let wait_until = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            page_id,
            url,
            wait_until,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserLocatorRequest {
    pub page_id: Option<String>,
    pub selector: String,
}

pub const BROWSER_LOCATOR_REQUEST_MSG_ID: u16 = 8;
pub const BROWSER_LOCATOR_REQUEST_VERSION: u8 = 1;
impl BrowserLocatorRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_LOCATOR_REQUEST_MSG_ID);
        out.push(BROWSER_LOCATOR_REQUEST_VERSION);
        match &self.page_id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_str(&mut out, &self.selector);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_LOCATOR_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_LOCATOR_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let page_id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let selector = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            page_id,
            selector,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserFillRequest {
    pub page_id: Option<String>,
    pub selector: String,
    pub value: String,
}

pub const BROWSER_FILL_REQUEST_MSG_ID: u16 = 9;
pub const BROWSER_FILL_REQUEST_VERSION: u8 = 1;
impl BrowserFillRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_FILL_REQUEST_MSG_ID);
        out.push(BROWSER_FILL_REQUEST_VERSION);
        match &self.page_id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_str(&mut out, &self.selector);
        ctl_put_str(&mut out, &self.value);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_FILL_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_FILL_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let page_id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let selector = ctl_read_str(bytes, &mut off)?;
        let value = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            page_id,
            selector,
            value,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserPointRequest {
    pub page_id: Option<String>,
    pub x: u32,
    pub y: u32,
}

pub const BROWSER_POINT_REQUEST_MSG_ID: u16 = 10;
pub const BROWSER_POINT_REQUEST_VERSION: u8 = 1;
impl BrowserPointRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_POINT_REQUEST_MSG_ID);
        out.push(BROWSER_POINT_REQUEST_VERSION);
        match &self.page_id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_u32(&mut out, self.x);
        ctl_put_u32(&mut out, self.y);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_POINT_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_POINT_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let page_id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let x = ctl_read_u32(bytes, &mut off)?;
        let y = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            page_id,
            x,
            y,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserTypeRequest {
    pub page_id: Option<String>,
    pub text: String,
    pub delay_ms: u32,
}

pub const BROWSER_TYPE_REQUEST_MSG_ID: u16 = 11;
pub const BROWSER_TYPE_REQUEST_VERSION: u8 = 1;
impl BrowserTypeRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_TYPE_REQUEST_MSG_ID);
        out.push(BROWSER_TYPE_REQUEST_VERSION);
        match &self.page_id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_str(&mut out, &self.text);
        ctl_put_u32(&mut out, self.delay_ms);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_TYPE_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_TYPE_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let page_id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let text = ctl_read_str(bytes, &mut off)?;
        let delay_ms = ctl_read_u32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            page_id,
            text,
            delay_ms,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserKeyRequest {
    pub page_id: Option<String>,
    pub key: String,
}

pub const BROWSER_KEY_REQUEST_MSG_ID: u16 = 12;
pub const BROWSER_KEY_REQUEST_VERSION: u8 = 1;
impl BrowserKeyRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_KEY_REQUEST_MSG_ID);
        out.push(BROWSER_KEY_REQUEST_VERSION);
        match &self.page_id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_str(&mut out, &self.key);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_KEY_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_KEY_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let page_id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let key = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            page_id,
            key,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserScrollRequest {
    pub page_id: Option<String>,
    pub delta_x: i32,
    pub delta_y: i32,
}

pub const BROWSER_SCROLL_REQUEST_MSG_ID: u16 = 13;
pub const BROWSER_SCROLL_REQUEST_VERSION: u8 = 1;
impl BrowserScrollRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_SCROLL_REQUEST_MSG_ID);
        out.push(BROWSER_SCROLL_REQUEST_VERSION);
        match &self.page_id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_i32(&mut out, self.delta_x);
        ctl_put_i32(&mut out, self.delta_y);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_SCROLL_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_SCROLL_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let page_id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let delta_x = ctl_read_i32(bytes, &mut off)?;
        let delta_y = ctl_read_i32(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            page_id,
            delta_x,
            delta_y,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserScreenshotRequest {
    pub page_id: Option<String>,
    pub full_page: bool,
}

pub const BROWSER_SCREENSHOT_REQUEST_MSG_ID: u16 = 14;
pub const BROWSER_SCREENSHOT_REQUEST_VERSION: u8 = 1;
impl BrowserScreenshotRequest {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_SCREENSHOT_REQUEST_MSG_ID);
        out.push(BROWSER_SCREENSHOT_REQUEST_VERSION);
        match &self.page_id {
            Some(v) => {
                out.push(1);
        ctl_put_str(&mut out, v);
            }
            None => out.push(0),
        }
        ctl_put_bool(&mut out, self.full_page);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_SCREENSHOT_REQUEST_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_SCREENSHOT_REQUEST_VERSION { return Err(WireError::UnsupportedVersion); }
        let page_id = match ctl_read_u8(bytes, &mut off)? {
            0 => None,
            1 => Some(ctl_read_str(bytes, &mut off)?),
            _ => return Err(WireError::InvalidPresence),
        };
        let full_page = ctl_read_bool(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            page_id,
            full_page,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserString {
    pub value: String,
}

pub const BROWSER_STRING_MSG_ID: u16 = 15;
pub const BROWSER_STRING_VERSION: u8 = 1;
impl BrowserString {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_STRING_MSG_ID);
        out.push(BROWSER_STRING_VERSION);
        ctl_put_str(&mut out, &self.value);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_STRING_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_STRING_VERSION { return Err(WireError::UnsupportedVersion); }
        let value = ctl_read_str(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            value,
        })
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct BrowserBytes {
    pub value: Vec<u8>,
}

pub const BROWSER_BYTES_MSG_ID: u16 = 16;
pub const BROWSER_BYTES_VERSION: u8 = 1;
impl BrowserBytes {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        ctl_put_u16(&mut out, BROWSER_BYTES_MSG_ID);
        out.push(BROWSER_BYTES_VERSION);
        ctl_put_bytes(&mut out, &self.value);
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, WireError> {
        let mut off = 0usize;
        if ctl_read_u16(bytes, &mut off)? != BROWSER_BYTES_MSG_ID { return Err(WireError::WrongMessage); }
        if ctl_read_u8(bytes, &mut off)? != BROWSER_BYTES_VERSION { return Err(WireError::UnsupportedVersion); }
        let value = ctl_read_bytes(bytes, &mut off)?;
        if off != bytes.len() { return Err(WireError::TrailingBytes); }
        Ok(Self {
            value,
        })
    }
}
