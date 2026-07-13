# Shells, sessions, and services

Use `vm.exec()` for bounded commands, `vm.shell()` for terminal-style byte streaming, and
`vm.session()` for framed agent events. They are different interaction models over the same VM.

## `vm.shell(options?)`

Returns an interactive `Shell` immediately.

```js
const shell = vm.shell();
const unsubscribe = shell.on((bytes) => {
  process.stdout.write(bytes);
});

shell.write("pwd\n");
shell.write(new TextEncoder().encode("ls -la\n"));
```

### Options

| Field | Values | Default |
|---|---|---|
| `language` | `"sh"`, `"luau"` | `"sh"` |

`language: "luau"` writes `luau\n` into a shell and enters the Luau REPL. Exiting that nested process
returns to the underlying shell.

### Shell methods

| Method | Meaning |
|---|---|
| `on(callback)` | Subscribe to output bytes; returns an unsubscribe function |
| `write(data)` | Send string or bytes as keystrokes/input |
| `history()` | Return all bytes emitted so far |

`write()` is not line buffered. Append `\n` when you mean Enter. `history()` is used by terminals to
replay boot output and scrollback after attaching.

An embedded backend has one underlying output fanout. Interactive output and host-driven commands may
therefore be visible to a terminal attached to the canonical shell. Applications should not assume
independent PTYs.

## `vm.session(agentType?)`

Starts the named in-VM agent program and returns a framed session handle.

```js
const session = vm.session("agent");
const off = session.on((event) => {
  console.log(event.type, event.text ?? "");
});

const events = await session.prompt("Inspect /workspace and summarize it.");
off();
```

`agentType` defaults to `"agent"` and selects a safe `/bin` program name. Shell metacharacters and
unsafe names are rejected rather than interpolated into a command.

### Session handle

| Member | Meaning |
|---|---|
| `id` | Session identifier |
| `prompt(text)` | Run one prompt and resolve with all framed events from that prompt |
| `on(callback)` | Subscribe to events as they arrive; returns unsubscribe |

A session event always has `type` and may have `text` plus program-defined JSON fields. Consumers
should switch on known `type` values and preserve or ignore unknown fields for forward compatibility.

## `vm.luauSession()`

Equivalent to `vm.session("luau")`.

```js
const session = vm.luauSession();
const events = await session.prompt(`
local log = require("log")
log.info("hello from Luau")
`);
```

Each prompt is executed as a Luau script. Structured log-battery events become `SessionEvent` objects.

## When to use which API

| Need | API |
|---|---|
| One command and complete stdout/stderr | `vm.exec()` |
| One multi-step Luau program | `vm.luau()` |
| Human or xterm interaction | `vm.shell()` |
| Structured streaming agent events | `vm.session()` |
| Raw resident-service protocol | `vm.serviceCall()` |

## Resident services

Resident services live inside the VM and retain warm state. A snapshot captures that memory. The host
can call one through `vm.serviceCall(name, bytes)`, while guest programs ordinarily open or invoke
the service through its filesystem/client convention.

Service calls count as in-flight egress. A snapshot taken between request receipt and response would
lose a live WebAssembly stack, so snapshot capture refuses until the call completes.

## Cleanup

Calling `on()` returns an unsubscribe function; use it when a UI or request scope ends. Closing the VM
terminates the underlying backend, but explicit unsubscription avoids retaining application callbacks
for the rest of the VM lifetime.
