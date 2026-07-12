# Coreutils implementation notes

This document preserves the implementation-level decisions cited by the Zig coreutils sources.
It is subordinate to the repository design contract in [`SYSTEMS.md`](../../../SYSTEMS.md), especially
section 10.2. If the two disagree, `SYSTEMS.md` wins and this note must be updated in the same change.

## 1. Scope

AgentOS ships a tier-partitioned multicall binary rather than a native host utility set. Applets use
the guest sysroot, operate on the VM filesystem, and are selected from one generated registry. The
goal is the documented uutils/GNU behavior that is useful inside AgentOS, bounded by the kernel ABI,
image budget, and deterministic execution model.

The roster in `src/registry_data.zig` is the authoritative inventory. Each applet's leading comment
states its implemented option and behavior scope; this section replaces the deleted milestone inventory
those comments historically cited.

## 2. Parity policy

Observable output, exit status, option precedence, and failure behavior are parity surfaces. Small
diagnostic differences may be accepted when host-dependent or hardware-specific behavior cannot exist
inside the VM; those exceptions must be stated beside the implementation and pinned by tests. Debug
or hardware-capability chatter may be a no-op when it cannot change the requested operation.

Concrete scope rulings and oracle observations remain beside the affected applet and its regression
tests. This section replaces the deleted parity ledger as their common policy, not as a duplicate list.

Text processing is byte-oriented unless an applet explicitly documents Unicode behavior. The shared
line model accepts CRLF, strips one trailing `\r`, and still yields an unterminated final line.

## 3. Dependency boundaries

- Applets may import `core/`, `engines/`, `sys/`, and shared types; applets never import one another.
- Engines contain reusable algorithms and normally avoid applet policy. An engine may use `sys` or
  `Ctx` when the reusable operation intrinsically owns I/O, as in checksum verification.
- Only `sys/` imports the generated AgentOS syscall module. There are no applet-local extern blocks.
- Shipped code avoids high-level `std.fs`, `std.Io`, and `std.fmt` machinery when the guest sysroot or
  a small local implementation is sufficient; this is a wasm-size constraint, not a style preference.

## 4. System boundary

### 4.1 Applet-facing sys API

`sys/root.zig` exposes the real mc backend; shipped coreutils have no native/WASI backend selector.
Pure native tests exercise engine modules without replacing that shipped boundary. `sys/types.zig`
owns the shared fd, process, stat, signal, polling, and error types. Applets consume this typed API
rather than raw ABI values.

Arguments cross `spawn` as one NUL-separated blob without a required trailing NUL. `waitpidNohang`
returns `null` when a child has not changed state. Kernel `unlink` removes files and empty directories;
recursive deletion therefore empties a directory before unlinking it.

### 4.2 mc backend

`sys/mc.zig` maps the applet API onto the generated mc syscall module. Errnos, flags, tiers, signals,
poll bits, seek values, and stat-record layout come from generated contract constants. The adapter may
translate those values into nutils types but must never reproduce their wire numbers.

### 4.3 Environment

There is no inherited native `envp`. The VM environment is the file tree under `/env`; reading,
setting, unsetting, or clearing a variable is a filesystem operation. `core/envfs.zig` is the shared
adapter for applets that manipulate that tree.

## 5. Program structure

### 5.1 One registry

`registry_data.zig` is the only applet roster. It drives dispatch, help/version behavior, generated
image symlinks, and `mc_applets` metadata. Adding or removing an applet anywhere else is incomplete.
Function references in the registry provide the dead-code roots; there is no secondary hand list.

### 5.2 Applets and engines

An applet owns command-line policy and user-facing diagnostics. Reusable parsing and algorithms live
in `core/` or `engines/`. This keeps similar commands behaviorally aligned without coupling their
entrypoints.

### 5.3 Context and allocation

Every applet receives `*Ctx`: allocator, argv, stdio, and the shared output/error path. The process
allocator is commonly an arena released wholesale at exit, so builders copy values instead of relying
on mutable aliasing. Streaming applets bound their buffers; explicitly whole-buffer engines document
that choice and inherit the guest memory budget.

## 6. Shared facades

The reusable facades are deliberately small:

- `textio`: CRLF-tolerant line iteration and common operand loops;
- `fsutil`: lexical paths, canonicalization, recursive copy/remove, and symlink policy;
- `proc`: argv-blob construction and EINTR-safe spawn/wait helpers;
- `sizes`: shared human-size parsing;
- `spool`: bounded memory with `/scratch` spill;
- `fmtnum`: the C-style formatting subset used by `printf`-family applets; and
- `civil`: UTC civil-time conversion for stat and date rendering.

### 6.1 Command-line parsing

`core/cli.zig` handles the common short/long flag grammar, precedence, help, and operands. Applets
hand-parse when operands are ambiguous with options, option meaning depends on position, or the grammar
needs `allow_hyphen_values`/trailing arguments that the shared shape cannot express cleanly.

### 6.2 Help

Each applet provides structured, agent-readable help through `core/help.zig`. Help text and dispatch
metadata come from the same registry entry as the executable function.

## 7. Engines

### 7.1 Regex

The shared regex engine is a pure-Zig Pike VM. It is reusable by grep, sed, awk, and future applets;
word-boundary assertions were added as part of the grep milestone (M3).

### 7.2 Glob

Glob matching uses iterative backtracking with explicit pathname and dotfile rules. It does not call
the host filesystem or a libc matcher.

### 7.3 Hashing

The hash engine owns digest implementations, checksum-line parsing, and the shared compute loop used
by the checksum applets. Algorithm selection and CLI presentation remain applet policy.

### 7.4 Codecs

The codec engine owns RFC 4648 base16/base32/base32hex/base64/base64url behavior. Base applets may
duplicate a tiny option declaration, but not the codec implementation.

### 7.5 Compression and archives

Compression/archive engines use a whole-buffer model bounded by the guest memory budget. Tar writes
explicit POSIX ustar headers. Zip parses and writes its in-memory records directly rather than pulling
in file-oriented `std.Io` machinery. gzip emits a deterministic header with mtime zero and no filename.
No zip64 support is claimed.

### 7.6 Diff and magic

Diff uses a Myers line algorithm. File detection uses a compact signature table plus explicit text,
JSON, XML, HTML, and shebang heuristics. Both return small result types and leave CLI rendering to the
applet.

### 7.7 Sort matrix

Sort stores input bytes once and sorts line offset/length records. Global comparison flags are inherited
by keys unless a key overrides them. External sorting uses bounded batches and the shared spool facade.

### 7.8 Date and calendar

Date parsing/formatting is proleptic Gregorian and supports UTC plus fixed numeric offsets. AgentOS
ships no timezone database, so named IANA zones and locale-dependent calendar behavior are outside the
contract.

## 8. Memory model

Streaming filters use bounded read/write buffers. Algorithms that require a global view—compression,
archives, some sort/diff modes—may read a complete input, but must state that fact and remain subject to
the stamped guest memory ceiling. `/scratch` is the sanctioned spill path when an algorithm supports it.

## 11. Size rules

1. Prefer shared facades and engine code over applet-local copies of nontrivial logic.
2. Do not import host-oriented filesystem/IO stacks into shipped wasm merely for convenience.
3. Keep diagnostics on the minimal formatter unless an engine truly requires richer formatting.

These are enforced by the built artifact's size budget as well as review.

## 14. Adapter checklist

R1: every ABI value comes from the generated contracts. The mc adapter translates types and calling
conventions only. It must preserve all known errnos, use the generated stat layout, and keep unsupported
values explicit (`EUNKNOWN`) rather than guessing.
