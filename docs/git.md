# Git

AgentOS Git is an optional host source plane. The guest sees an ordinary mounted worktree and a thin
`/bin/git`; repository state and Git protocol semantics remain in a Gitz-based host engine. Enable it
with the `git` create option. Omit the option to attach no Git capability.

```js
const vm = await mc.create({
  git: {
    identity: { name: "Agent", email: "agent@example.com" },
    durable: { id: "session-1" },
  },
  connections: [{
    ref: "github.user.work",
    auth: { kind: "bearer", token },
    origins: ["https://github.com"],
  }],
});
```

`git: true` resolves the standard engine artifact. The object form may supply explicit artifact bytes,
mounts, sparse prefixes, identity, read-only policy, durability, and remote-effect policy. The default
mount is `/workspace/repo`.

## Architecture

One Zig/Gitz core is compiled into two host-appropriate products:

- JavaScript and browsers instantiate zero-import `git_engine.wasm` with the standard WebAssembly API.
- The served Elixir runtime supervises the native `git-engine` executable as a BEAM Port.

The artifacts share commands, mount behavior, object/ref/pack operations, remote state machines, limits,
errors, and the generated binary contract. Browser state uses Gitz memory storage and opaque engine
snapshots. Native state uses Gitz filesystem storage rooted in a host-authorized directory.

JavaScript and Elixir own capabilities and effects: connection authorization, origin policy,
credentials, TLS/HTTP, persistence placement, and engine lifecycle. They do not parse pkt-lines, select
wants/haves, interpret packs, or decide ref updates. Credentials never enter engine memory.

There is no libgit2, Emscripten, MEMFS bridge, system-Git fallback, JSON engine ABI, Smart HTTP
implementation in the hosts, pack cache, or private `.git` mailbox.

## Guest surface

| Surface | Role |
| --- | --- |
| Mounted worktree | Ordinary files backed by generated engine mount operations |
| `/bin/git` | Thin argv/result adapter, not a Git implementation |
| host call `"git"` | Selects the attached engine for every guest verb |

The guest host-call body is the public `{op,args,mount?}` request form. The trusted host adapter maps it
to generated binary engine messages; JSON never crosses the Wasm or Port boundary. Local verbs execute
directly against the selected engine. Clone/fetch/pull/push additionally yield typed HTTP effects to the
host and resume only after the host returns bounded response messages.

The thin CLI supports the documented reduced surface: `init`, `status`, `add`, `rm`, `commit`, `log`,
`diff --cached`/`--staged`, `show`, `rev-parse`, `branch`, `checkout`/`switch`, `reset`, `tag`, limited `config` and `remote`,
plus `clone`, `fetch`, `pull`, and `push`. Unknown or unsupported forms fail closed.

The reduced `diff` operation returns a bounded, newline-delimited staged change summary such as
`<Modify path>`. It is not a unified patch. Unstaged diff and path-filtered diff are not exposed.

## Remotes and credentials

Remote Git requires an authorized host connection or an explicit non-empty bare-URL allowlist. The
guest may pass a public URL and connection reference, but never credentials. The engine emits method,
URL, public headers, and an optional request-body stream. The host revalidates the origin, attaches
credentials, performs HTTP/TLS without following redirects, and returns `BEGIN`, bounded `CHUNK`s, and
`END` (or `ABORT`). The engine alone interprets the Git response and publishes the final operation.

Push is rejected inside the shared core for read-only mounts. Malformed effect sequences, stale handles,
oversized bodies, ambiguous mount selection, empty origin policy, redirects, and credential-bearing guest
arguments fail closed.

## Multiple repositories

```js
const vm = await mc.create({
  git: {
    mounts: [
      { path: "/workspace/app" },
      { path: "/workspace/lib", sparse: ["src"], readOnly: true },
    ],
  },
});
```

Each distinct path owns one engine and one writer. Requests select a repository with `mount` (or
`args.mount`); the first attached path is the default. Duplicate paths and unknown selectors are errors.
Snapshots are refused while a remote operation is in flight.

## Durability

Kernel snapshots do not contain host Git state. Opt into a durable backend and reattach it when restoring
or forking:

```js
const vm = await mc.create({
  git: { durable: { id: "agent-session-1", diskDir: "/var/lib/agentos/git" } },
});
```

JavaScript stores opaque engine-produced snapshots; it never interprets the ODB, index, refs, or
worktree. The native server reopens its rooted filesystem repository. Without durability the engine is
ephemeral.

## Artifact resolution

The browser artifact is `git-engine.tar` containing only `git_engine.wasm`. Resolution order is:

1. explicit `git.engine` / `GitEngine.load({engine})` bytes;
2. `MC_GIT_ENGINE_TAR`;
3. `$AGENTOS_DIR/git-engine.tar` or `$MC_ARTIFACT_HOME/git-engine.tar`;
4. the AgentOS artifact cache;
5. optional fetch when `MC_ARTIFACT_FETCH=1`;
6. otherwise fail closed.

The server package contains the native executable instead. Neither artifact contains C headers,
Emscripten glue, shared libraries, or libgit2 notices.

## LLB and advanced APIs

`llb.git` uses the same engine remote state machine and HTTP effect pump, then walks the typed worktree
into a deterministic archive. It never shells out to system Git.

Advanced SDK exports include `GitEngine`, `GitRemoteEffectPump`, `registerGitHostCall`,
`gitHostCallHandler`, `materializeLlbGit`, and `createEngineGitSource`. Applications should normally use
`mc.create({git: ...})`.
