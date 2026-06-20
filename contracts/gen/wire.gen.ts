// @generated from contracts/wire.kdl by //contracts/codegen:projector — do not edit.

export const WIRE_VERSION = 1;
export const HEADER_LEN = 9;

export const HELLO = 0x00;
export const WELCOME = 0x01;
export const SHELL_IN = 0x10;
export const SHELL_OUT = 0x11;
export const HOST_CALL = 0x20;
export const HOST_RESULT = 0x21;
export const SESSION_START = 0x30;
export const SESSION_EVENT = 0x31;
export const SESSION_END = 0x32;
export const PERMISSION_REQUEST = 0x40;
export const PERMISSION_RESPONSE = 0x41;

export const MESSAGES = [
  { name: "HELLO", tag: 0x00, dir: "client->server", body: "json" },
  { name: "WELCOME", tag: 0x01, dir: "server->client", body: "json" },
  { name: "SHELL_IN", tag: 0x10, dir: "client->server", body: "binary" },
  { name: "SHELL_OUT", tag: 0x11, dir: "server->client", body: "binary" },
  { name: "HOST_CALL", tag: 0x20, dir: "server->client", body: "binary" },
  { name: "HOST_RESULT", tag: 0x21, dir: "client->server", body: "binary" },
  { name: "SESSION_START", tag: 0x30, dir: "client->server", body: "json" },
  { name: "SESSION_EVENT", tag: 0x31, dir: "server->client", body: "json" },
  { name: "SESSION_END", tag: 0x32, dir: "server->client", body: "json" },
  { name: "PERMISSION_REQUEST", tag: 0x40, dir: "server->client", body: "json" },
  { name: "PERMISSION_RESPONSE", tag: 0x41, dir: "client->server", body: "json" },
] as const;
