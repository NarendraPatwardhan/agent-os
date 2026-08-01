# VERIFY_CHUNK_1

Verdict: **PASS**

Hostile verifier for feature/cgit Chunk 1 (PR11 server connections). Tree: `feature/cgit` @ `c580f7e`+ with uncommitted PR11 wiring (including untracked `server/lib/agent_os/git/connections.ex`). No product code changed by this verifier.

---

## Acceptance matrix

| # | Requirement | Result | Evidence |
|---|-------------|--------|----------|
| 1 | Server clone/fetch/push **connections: only** (no `allowed_origins`) | **PASS** | See A1 |
| 2 | Empty connection origins fail closed | **PASS** | See A2 |
| 3 | Guest JSON cannot supply tokens (fail/ignore, no dial) | **PASS** | See A3 |
| 4 | Dual-host JS/BEAM connection semantics | **PASS** | See A4 |
| 5 | Push `block` / `require_approval` fail closed on server | **PASS** | See A5 |
| 6 | TASKS D1 D6 D7 D8 D10 DONE only with path evidence | **PASS** | See A6 |
| 7 | Mandatory tests green | **PASS** | See A7 |

No soft language. No partial credit. All seven hold.

---

## A1 — Product path: `connections:` only

**Code**

| Path | Proof |
|------|--------|
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/vm.ex` `do_attach_git_new/3` | When `connections != []`, stores connections/policies; sets `git_allowed_origins: []` and `git_auth: nil` (legacy flat keys ignored) |
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/vm.ex` `git_host_opts/1` | Product branch: `[connections: connections]` (+ `policies` if set). **No** `:allowed_origins` / flat `:auth` |
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/connections.ex` `resolve_remote/2` | Connection-bound: origins/auth from catalog; bare URL still needs legacy allowlist |
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/git/orchestrator.ex` | `resolve_binding` → `Connections.resolve_remote`; `apply_binding` splices host auth + binding origins into SmartHttp opts for clone/fetch/push |
| `/mnt/workspace/agent-os/agent-os-cgit/server/lib/agent_os/control_plane.ex` `attach_git/2` | Forwards opts to `Vm.attach_git`; docs state connections-only product path |

**Tests**

- `PR11 product path: attach_git connections-only → host_call clone via fixture` — attach with `connections:` only; host_call clone dials with spliced bearer; bare URL without connection does **not** dial (`dialed == 0`)
- `clone with connection ref + origins + fixture transport succeeds` — orch clone with `connections:` only (explicit comment: no legacy `allowed_origins`)
- `PR11 attach_git stores connections + policies` — `info.git_allowed_origins == []` when connections present; secret not in info

Shared resolve path covers fetch/push (same `resolve_binding`/`apply_binding` as clone).

---

## A2 — Empty connection origins fail closed

| Host | Path | Behavior |
|------|------|----------|
| BEAM | `Connections.bind_after_url/5` | `allowed == [] or not origin_allowed?` → `{:error, {:origin_not_allowlisted_for_connection, ref}}` |
| BEAM | `SmartHttp.origin_allowed?/2` | Empty list → `false` |
| JS | `resolveGitRemote` | `!allowed.length \|\| !originAllowed(...)` → fail stderr `origin not allowlisted for connection` |
| JS | `@mc/host` `originAllowed` | `.some` on empty list → false |

**Tests**

- BEAM: `empty origins on connection fails closed` — orch clone, `dialed == 0`
- BEAM: `resolve_remote: connection auth + origins; unknown / empty fail closed`
- JS: `git_connections.test.ts` empty origins block (resolve fails)

---

## A3 — Guest JSON tokens rejected without dial

| Host | Path | Behavior |
|------|------|----------|
| BEAM | `Connections.guest_args_carry_secrets?/1` + `resolve_remote` | Secret keys → `{:error, :guest_secrets_forbidden}` **before** dial |
| BEAM | `Orchestrator.map_remote_error` | Maps to stderr `must not include auth secrets` |
| JS | `guestArgsCarrySecrets` + `resolveGitRemote` | Reject; orch never reaches transport |

Secret key sets match dual-host (token, auth, password, bearer, authorization, apikey, access_token, …). Credentials never read from guest body for splice — only host catalog / host opts.

**Tests**

- BEAM: `guest body with fake token field rejected before dial (D7)` — `dialed == 0`, response omits `guest-stolen`
- JS: resolve reject + orch smuggle (`listRefsCalls === 0`)

---

## A4 — Dual-host semantics (spot-check)

Reference table: `memcontainers/sdk-js/core/src/git/connections.ts` (header dual-host table). BEAM mirror: `server/lib/agent_os/git/connections.ex`.

| Concern | JS | BEAM | Match? |
|---------|----|------|--------|
| Credential source | `ConnectionDefinition.auth` only | connection catalog `:auth` (bare host `:auth` legacy) | Yes |
| Guest body secrets | Reject | `:guest_secrets_forbidden` | Yes |
| Empty connection origins | Fail closed | Fail closed | Yes |
| Push block | Before dial | `gate_push_policy` before dial | Yes |
| Push require_approval | Callback or false (fail closed) | `on_push_approval` / `push_approval` or reject | Yes |
| Auth splice host-only | `spliceCredentialHeaders` | `SmartHttp.auth_headers` | Yes |
| Userinfo URL | Reject | `public_remote_url` nil | Yes |
| Auth kind catalog | none/bearer/header/**query** | none/bearer/header/**basic** (+ query normalize pass-through; SmartHttp no-op) | Documented subset parity |

Not a divergence that breaks A4: kinds are catalog-documented dual-host differences, both host-only splice.

---

## A5 — Push policy fail closed (server)

| Path | Proof |
|------|--------|
| `Connections.evaluate_push_policy/2` | Most restrictive of matching rules (`approve` < `require_approval` < `block`) |
| `Orchestrator.gate_push_policy/1` | `:block` → `{:error, :push_blocked}` before `list_refs` |
| `Orchestrator.maybe_require_push_approval/4` | No fun / non-true `push_approval` → `{:error, :push_requires_approval}`; **no** `push_packs` |
| `Vm.attach_git` + `git_host_opts` | Forwards `policies` / approval opts into orch |

**Tests**

- `push policy block fails before dial` — `dialed == 0`
- `push policy require_approval fails closed without fun` — no push, `dialed_push == 0`
- JS: `git_connections.test.ts` block; `git_push.test.ts` require_approval fail-closed + deny callback

---

## A6 — TASKS D1 / D6 / D7 / D8 / D10 not false DONE

| ID | TASKS status | Path evidence verified | False DONE? |
|----|--------------|------------------------|-------------|
| D1 | DONE | `connections.ex` resolve+splice; `Vm.attach_git(connections:)`; orch `resolve_binding`/`apply_binding`; product e2e host_call clone; JS `git_connections.test.ts` | **No** |
| D6 | DONE | Guest `connection`/`agentos` → `resolve_remote`; unknown ref + empty origins fail closed; connections-only clone; `git_host_opts` forwards connections+policies | **No** |
| D7 | DONE | JS `guestArgsCarrySecrets`; BEAM `guest_args_carry_secrets?` → `:guest_secrets_forbidden`; dual-host fail-before-dial tests | **No** |
| D8 | DONE | BEAM `auth_headers` none/bearer/header/basic (+ string keys, unit test); bearer connection e2e; JS splice none/bearer/header/query + header orch fixture | **No** |
| D10 | DONE | JS `evaluatePushPolicy` + orch block/require_approval; BEAM `evaluate_push_policy` + policies on attach; block-before-dial + require_approval fail-closed tests both hosts | **No** |

Evidence columns name real symbols/tests present in tree. Campaign chunk 1 remains **OPEN** until this PASS (correct; not a DONE lie).

---

## A7 — Mandatory tests

### JS (forced re-run, `--cache_test_results=no`)

```
bazel --output_user_root=/mnt/workspace/agent-os/bazel-cache test \
  //memcontainers/sdk-js/core:git_connections_test \
  //memcontainers/sdk-js/core:git_remote_test \
  //memcontainers/sdk-js/core:git_push_test \
  --test_output=errors --cache_test_results=no
```

Result: **3/3 PASSED**

### Elixir

```
export AGENTOS_GIT_ENGINE=<realpath of //memcontainers/lib/git-engine:git-engine>
cd server && mix test test/agent_os/git_orchestrator_test.exs test/agent_os/git_engine_test.exs
```

Result: **46/46 passed** (includes PR11 product path, empty origins, guest secrets, push block, require_approval fail-closed, git-engine Port suite).

---

## Mandatory fix list (if FAIL)

*(none — verdict PASS)*
