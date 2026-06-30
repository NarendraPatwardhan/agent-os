// @generated from contracts/wire.kdl by //contracts/codegen:projector — do not edit.
#![no_std]

pub const WIRE_VERSION: u32 = 2;
pub const HEADER_LEN: usize = 9;

pub const HELLO: u8 = 0x00;
pub const WELCOME: u8 = 0x01;
pub const SHELL_IN: u8 = 0x10;
pub const SHELL_OUT: u8 = 0x11;
pub const HOST_CALL: u8 = 0x20;
pub const HOST_RESULT: u8 = 0x21;
pub const SESSION_START: u8 = 0x30;
pub const SESSION_EVENT: u8 = 0x31;
pub const SESSION_END: u8 = 0x32;
pub const PERMISSION_REQUEST: u8 = 0x40;
pub const PERMISSION_RESPONSE: u8 = 0x41;

pub struct WireMessage { pub name: &'static str, pub tag: u8, pub dir: &'static str, pub body: &'static str }
pub const MESSAGES: &[WireMessage] = &[
    WireMessage { name: "HELLO", tag: 0x00, dir: "client->server", body: "json" },
    WireMessage { name: "WELCOME", tag: 0x01, dir: "server->client", body: "json" },
    WireMessage { name: "SHELL_IN", tag: 0x10, dir: "client->server", body: "binary" },
    WireMessage { name: "SHELL_OUT", tag: 0x11, dir: "server->client", body: "binary" },
    WireMessage { name: "HOST_CALL", tag: 0x20, dir: "server->client", body: "binary" },
    WireMessage { name: "HOST_RESULT", tag: 0x21, dir: "client->server", body: "binary" },
    WireMessage { name: "SESSION_START", tag: 0x30, dir: "client->server", body: "json" },
    WireMessage { name: "SESSION_EVENT", tag: 0x31, dir: "server->client", body: "json" },
    WireMessage { name: "SESSION_END", tag: 0x32, dir: "server->client", body: "json" },
    WireMessage { name: "PERMISSION_REQUEST", tag: 0x40, dir: "server->client", body: "json" },
    WireMessage { name: "PERMISSION_RESPONSE", tag: 0x41, dir: "client->server", body: "json" },
];
