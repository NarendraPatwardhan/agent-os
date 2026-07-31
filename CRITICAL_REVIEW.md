# Critical code quality review — `feature/cgit`

**Date of review:** 2026-07-31  
**Branch:** `feature/cgit`  
**Review baseline commit:** `020cc8b` (*git: server remotes via BEAM HTTPS, not C TLS (K16)*)  
**Scope vs `develop`:** 12 commits / ~70 files / **+12 447 / −29** lines  
**Method:** Five parallel explore agents (C/native, TS/SDK, Elixir/server, `GIT.md` remaining-work audit, develop-norms divergence) plus direct verification of the highest-severity claims.  
**Tracker:** [`TASKS.md`](./TASKS.md) — implementation checkboxes mapped to finding IDs below.  
**This document is the durable full report.** It is intentionally long. Do not replace it with a bullet checklist.

### Post-review note (Wave 1, same day)

After this report was delivered, Wave 1 remediation landed **uncommitted** on P0.1–P0.2 and P0.4–P0.9 (see `TASKS.md`). Findings below describe the tree **as reviewed at `020cc8b`** unless a **Post-review** note says otherwise. Keep historical findings; mark remediation in the tracker, not by erasing the report.

---

## 1. Executive summary

Architecture intent is strong: host source plane, dial-free engine, CAP_NET-gated remotes, BEAM HTTPS for server remotes (K16 revised). **Product readiness is not.** Remotes GA and multi-tenant server use are blocked by security holes, false-green tests, unfinished tails of PR7–PR15, and triple-orchestrator drift.

Treat the branch as a **scaffold with real bones**, not a finished feature. **Do not treat “PR0–PR15 landed” as remotes-ready.**

| Layer | Grade | One-line |
|-------|-------|----------|
| C engine / Port | **D+** | Spike substrate; lifetime bugs, triple orch, untested apply |
| TS / SDK | **C+** | Best-shaped orch; dual-queue race, over-export, soft tests |
| Elixir / server | **D+** | Right ownership cut; open SSRF, false-green clone, sync on VM |
| Docs / remaining | **C−** | Draft + contradictions; PR0–15 “landed” overstates honesty |
| Develop norms | **C** | Layout OK; public API / docs / toolchain dialect drift |

### Harsh dimension scores (cross-cutting)

| Dimension | Score | Notes |
|-----------|-------|-------|
| Security (server remotes) | **F** | SSRF-class open URL dial; no origins; status/size weak |
| Test honesty | **F / D** | Empty-pack success; soft JS remote asserts; no real pack C tests |
| Single-writer correctness | **D** | Dual promise queues engine vs gitfs |
| Dual-host algorithm parity | **D+** | TS richest; BEAM subset; C fixture still on Port type-1 |
| Naming / module boundaries | **C−** | Mixed prefixes; god files; Elixir `Jason_like` |
| Packaging / Bazel placement | **B** | Right planes; size_limit / license gates incomplete |
| Develop convention adherence | **C** | Structure good; export hygiene and docs lag critical |

### What landed well (credit)

- Correct plane cut: guest paths + thin `/bin/git`; engine never dials at the `ge_run_json` face; remotes host-mediated by design.
- Packaging: hermetic libgit2 1.9.x, emcc wasm, size-gate *intent*, Bazel under `memcontainers/lib/git-engine`, guest under `programs/git`.
- Server lifecycle sketch: BEAM-owned Port, unlinked engine + monitor + detach on DOWN, type-4 binary MOUNT_OP framing.
- K16 revision direction is right: BEAM `:httpc`/`:ssl`, no Node on server, no C TLS for product remotes.
- JS path has real connection/origin ideas (fail-closed empty origins when connection-bound).
- `solve-node` engine-first default (vs develop’s ambient system `git`) is the correct product move; `MC_GIT_USE_SYSTEM=1` is demoted to emergency.
- Guest program shape (`rust_binary` + `mc_rust_program(tier = "full")`) matches browser/other programs.
- Control plane demux order (sidecar first, then git) is sensible.

---

## 2. Inventory of the change surface

```
feature/cgit @ 020cc8b (review baseline)
  GIT.md, docs/git.md
  memcontainers/lib/git-engine/**          (~engine + Port + orch + fixtures)
  memcontainers/programs/git/**            (thin pure-mc CLI)
  memcontainers/sdk-js/core/src/git/**     (engine, gitfs, orch, smart-http, connections, pack-cache, durable, llb-git)
  memcontainers/sdk-js/core/src/{memcontainer,solve-node,index,types}.ts
  server/lib/agent_os/{git_engine.ex, git/*.ex, vm.ex, control_plane.ex}
  server/test/agent_os/git_*.exs
  third_party/libgit2/**
  bazel/{force_opt,pick_file}.bzl, MODULE.bazel (+ hermetic_cc, emsdk, libgit2)
```

Approx line counts at review (order of magnitude):

| Area | ~LOC |
|------|-----:|
| C engine sources | ~2.5k |
| TS git module | ~2.1k |
| Elixir git path | ~1.0k |
| Thin CLI (Rust) | ~0.5k |
| Design docs | ~1.6k (`GIT.md`) + product stub |

---

## 3. Critical findings (block remotes GA)

### C1 — Server SSRF / missing origin + connection policy

**Severity:** Critical  
**Layer:** Elixir / BEAM  
**Tracker:** P0.1  

**Where (review baseline):**

- `server/lib/agent_os/git/orchestrator.ex` — `url_of/1` accepted any non-empty URL string; no scheme gate, no userinfo strip, no origin allowlist.
- `server/lib/agent_os/vm.ex` — `answer_git_event/2` called `GitEngine.handle_host_call/3` **without** connections catalog, auth, or allowlist opts.
- `server/lib/agent_os/git/smart_http.ex` — dialed via `:httpc` with peer verify, but no origin policy, largely ignored HTTP status, no max body, `extract_pack` could return the **entire** response if `PACK` magic missing.
- Contrast TS: `memcontainers/sdk-js/core/src/git/connections.ts` — `originAllowed`, empty origins fail-closed when connection-bound.

**Why it matters:** With `CAP_NET` + guest `host_call "git"`, the **control plane** dials arbitrary HTTPS (classic SSRF into BEAM egress). Docs (`docs/git.md`) claim origin/connection policy is owned by BEAM — **false in code at review**. Worse than the kernel HTTP path, which at least binds secret-bearing connections to known origins in the NIF model.

**Fix:** Port `resolveGitRemote` / empty-origins-fail-closed into BEAM before any dial; scheme allowlist http(s); reject userinfo; disable/limit autoredirect; max body 64 MiB; fail non-2xx; never return whole body as pack.

**Post-review:** Stream D added `SmartHttp.ensure_url_allowed/2`, `origin_allowed?/2`, max pack, status fail-closed, no-pack-magic error, pre-dial gate in Orchestrator. Full connection-catalog splice (PR11 server) still open (P2.6).

---

### C2 — False-green remotes (empty pack → `ok:true` “cloned”)

**Severity:** Critical  
**Layer:** Elixir tests + orch; JS soft remote tests  
**Tracker:** P0.2, P0.3  

**Where (review baseline):**

```elixir
# orchestrator.ex — product path skipped apply on empty pack
defp maybe_apply_refs_and_checkout(_pid, _tip, pack, _mode) when pack == <<>>, do: :ok
defp apply_pack(_pid, pack) when pack == <<>>, do: :ok
```

```elixir
# git_orchestrator_test.exs — fixture returned empty pack and asserted success
pack = <<>>
assert json =~ "\"ok\":true"
assert json =~ "cloned"
```

JS `git_remote.test.ts` accepted either success **or** any post-list-refs failure as long as the response shape existed — not a real clone.

**Why it matters:** CI can green forever without `ge_import_pack`, `refs.import`, or `clone.apply` working. Production empty/malformed packs can report success if extract_pack yields empty.

**Fix:** Never report clone success without successful import + apply; ship real minimal PACK fixtures; fail closed on empty/non-PACK.

**Post-review:** Empty-pack success removed; tests assert `ok:false`. Synthetic non-empty PACK in tests exercises “not empty”; full import→worktree e2e with real objects still incomplete (P0.3 open).

---

### C3 — `fetch.apply` is unconditional success (no-op)

**Severity:** Critical  
**Layer:** C engine  
**Tracker:** P0.4  

**Where (review baseline):**

```c
/* engine.c */
if (strcmp(op, "fetch.apply") == 0) {
  return resp_ok("", NULL);
}
```

Used by C orch and (via empty call) by TS/BEAM after pack import.

**Why it matters:** Fetch “success” does not update remote-tracking, merge, or checkout. Partial apply leaves ODB objects + one refs.import tip without documented fetch semantics. False green for remote algorithm traces.

**Fix:** Implement tracking-ref updates / FETCH_HEAD from name+hash, or fail closed with “not implemented” — never silent success.

**Post-review:** `op_fetch_apply` requires `name`+`hash`; creates tip ref, `refs/remotes/<remote>/<branch>`, `FETCH_HEAD`. BEAM/TS orch must pass args (serial glue applied). Empty args fail closed.

---

### C4 — Port type-1 re-routes remotes into C fixture orch

**Severity:** Critical  
**Layer:** C Port  
**Tracker:** P0.5  

**Where (review baseline):**

```c
/* port_handle.c */
if (type == GE_FRAME_RUN) {
  ...
  if (is_remote_op(req)) {
    /* Host-mediated remotes: never pass to ge_run dial refuse — use C orch. */
    if (ge_remote_orchestrate(e, req, &resp) != 0 || !resp)
      ...
  } else {
    resp = ge_run_json(e, req);
  }
}
```

Product docs (`git_engine.ex`, K16): remotes are BEAM HTTPS + Port apply; type-5 is legacy/test-only. But type-1 still intercepted remotes into fixture-only `ge_http_*` (no origin policy, no credentials, incomplete vs TS/BEAM).

**Why it matters:** Three orchestrators (TS / BEAM / C) with different security and apply semantics. Direct `ge_run_json` still dial-refuses; Port `run` did not. Integrity hazard if anyone sends remote JSON on type-1.

**Fix:** Type-1 always `ge_run_json` only. Quarantine C orch to type-5 / test builds.

**Post-review:** Type-1 always `ge_run_json`; type-5 still C orch, documented test-only. C orch remains linked in product Port binary (further quarantine optional).

---

### C5 — Dual serial queues break single-writer

**Severity:** Critical  
**Layer:** TS SDK  
**Tracker:** P0.8  

**Where (review baseline):**

- `GitEngine` serialized `run` / `importPack` on its own promise chain (`engine.ts`).
- `createGitFsDriver` had a **separate** chain and called `bridge.run` / MEMFS without `GitEngine.serial` (`gitfs.ts`).
- `asMountDriver()` handed the bare bridge to the driver.

Concurrent product paths:

1. guest VFS write / `/.git/mc/ctl` (driver queue)  
2. host_call `"git"` / orchestrator → `engine.run` + `importPack` (engine queue)  
3. SDK `eng.run` while mount is live  

can interleave `_ge_run_json` / `_ge_import_pack` / MEMFS mutations. GIT.md and the C engine assume multi-writer is a non-goal. **Correctness bug, not polish.**

Additionally: `stat` / `readdir` were often **outside** the driver’s serial chain while `open`/`write` were inside → torn views.

**Fix:** One shared mutex on `GitBridge` (or `GitEngine`); every FS + Run + pack path takes the same lock.

**Post-review:** `GitBridge.serial` is the single queue; engine + gitfs both use it. Nested bodies call sync `bridge.run` to avoid deadlock.

---

### C6 — Thin CLI clone discovery order

**Severity:** Critical (guest remotes product path)  
**Layer:** `programs/git`  
**Tracker:** P0.6  

**Where (review baseline):**

```rust
// main.rs — find_git_root BEFORE remote detection
let root_len = match find_git_root(&mut root) {
    Ok(n) => n,
    Err(_) => {
        eprint(b"git: not a git repository ...\n");
        return 128;
    }
};
// only later:
Err(REMOTE_VIA_HOST_CALL) => return remote_host_call(...)
```

**Why it matters:** `git clone <url>` on a fresh worktree without an existing `/.git/mc/ctl` ancestor **never** reaches CAP_NET `host_call`. Primary guest remote use case broken.

**Fix:** After version/help, remote cmds (`clone`/`fetch`/`pull`/`push`) go straight to `remote_host_call`; local porcelain still requires root.

**Post-review:** Early remote dispatch implemented; help text updated.

---

### C7 — `ge_free` on static OOM buffer (UB)

**Severity:** Critical  
**Layer:** C engine + JS bridge  
**Tracker:** P0.7  

**Where (review baseline):**

```c
/* git_engine.h claimed */
/* Never returns NULL — on OOM returns a static error JSON that must
 * not be freed (check ge_response_is_static). Prefer ge_free always safe. */

void ge_free(void *p) { free(p); }  /* always free */

static char static_oom[] =
  "{\"ok\":false,\"code\":1,\"stdout\":\"\",\"stderr\":\"out of memory\"}";
/* returned when jmin_response fails */
```

JS always frees every response:

```ts
// bridge.ts
const text = this.mod.UTF8ToString(outPtr);
this.mod._ge_free(outPtr);
```

**Why it matters:** Free of static/rodata on OOM → heap corruption in wasm or native. Documented API (`ge_response_is_static`) was phantom.

**Fix:** `ge_free` no-ops for static; implement `ge_response_is_static`; or never return static memory.

**Post-review:** `ge_static_oom` + safe `ge_free` + `ge_response_is_static` implemented and exported for wasm.

---

### C8 — K28 violated: invented commit identity

**Severity:** Critical (policy / honesty)  
**Layer:** C engine; no host inject on SDK/server  
**Tracker:** P0.9  

**Where (review baseline):**

```c
/* engine.c op_commit */
char name[256] = "Agent";
char email[256] = "agent@example.com";
(void)jmin_get_string(args, "name", name, sizeof(name));
(void)jmin_get_string(args, "email", email, sizeof(email));
```

Design K28: **commit identity: host policy inject when request omits name/email — never invent guest-side identity.**

**Why it matters:** Every commit without identity becomes a silent fake author. Agents/tests look green while product identity story is a lie.

**Fix:** Require name+email (fail closed) and/or inject from host policy only.

**Post-review:** Commit requires name+email with K28 error text. **Host-policy inject** (automatic from session config) still not implemented — fail-closed is the interim honesty fix.

---

## 4. High findings

### H1 — `ge_engine` struct redefined in two TUs (layout drift bomb)

**Evidence:** `engine.c` and `engine_ops_extra.c` each define `struct ge_engine` by hand (same field order by luck). Opaque type intentionally hidden from public header but **copied**.

**Why:** One field reorder/add → silent memory corruption across translation units. Develop Zig/Rust modules use a single type definition.

**Fix:** Private `ge_engine_internal.h` shared by all engine sources.

---

### H2 — Apply path has zero C tests with real pack bytes

**Evidence:** No `ge_import_pack` / type-2/3 frame tests under `*test*` in git-engine at review. `abi_fixture_test`, `abi_dual_test`, `port_smoke_test` cover local porcelain + dial refuse + mount ctl only. JS pack-cache tests mock the engine.

**Why:** Remotes and server product path are “binary import + apply”. C CI can green while indexer / refs.import / clone.apply are broken.

**Fix:** Fixture with known pack (now staged under `testdata/pack/minimal.pack`); stream frames; assert object reachable + checkout.

---

### H3 — Pack indexer poisoned on error; no engine-side 64 MiB total

**Evidence:** `ge_import_pack` on append/commit failure leaves `e->indexer` alive; subsequent chunks append to a failed stream. Per-frame max in `port_frame.c` is 64 MiB, but multi-chunk totals can exceed interactive cap. TS enforces 64 MiB; C Port did not at review.

**Fix:** On any error free indexer; track `bytes_seen`; refuse over max.

---

### H4 — Product buffer / JSON gates from GIT.md still spike-grade

**GIT.md PR1 hard gate:** product-grade JSON/args buffers (no spike jmin fixed caps).

**Evidence still present at review:**

- `op_write` content `char content[65536]`
- status/log/diff stacks 16–64 KiB with silent `snprintf` truncate (no `result.truncated`)
- `jmin_*` is shallow `strstr` key search (“spike” comments in `json_min.c`)

**Why:** Explicit monorepo product gate failed. Large diffs/logs silently truncated; fragile key matching mis-parses nested/escaped JSON.

**Fix:** Heap-grow builder/parser or vendor tiny known parser; truncation metadata per GIT.md.

**Tracker:** P1.1

---

### H5 — Synchronous HTTPS + pack import on the VM GenServer

**Evidence:** `try_answer_git_host_call` is a `GenServer.call` into `Vm`; `answer_git_event` runs full orch (blocking `:httpc` + multi `GitEngine` calls) **inside that call**.

Sidecar host_calls correctly use **async** tasks:

```elixir
# sidecars/egress.ex pattern
Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fn -> ... end)
```

**Why:** Freezes the VM actor for the whole remote (no exec, ticks, other egress). Default VM call timeout 60s; SmartHttp 60s request + 30s connect — multi-step clone can exceed timeout while still dialing.

**Tracker:** P1.6

---

### H6 — Smart-HTTP quality far below TS twin (review baseline)

| Behavior | TS `FetchSmartHttp` | BEAM `SmartHttp` (baseline) |
|----------|---------------------|------------------------------|
| HTTP status | fail | ignored |
| Origin / public URL | enforced (connections) | none |
| Max pack | 64 MiB | none |
| Auth splice | connections | manual `:auth` only |
| extract_pack miss | error-ish | returns **entire** body |

`parse_info_refs` line-oriented weak hex strip — not a full pkt-line decoder; fragile vs real GitHub/GitLab ads.

**Post-review:** status, max pack, no-pack-magic, origin gate improved; real pkt-line parity and connection splice still open.

---

### H7 — Port demux fragility under load / partial failures

**Evidence (`git_engine.ex` recv path):**

- Timeout leaves polluted `buffer` for the next op → desync / `bad_frame`.
- Intermediate pack chunk status ignored (`_status` on non-final import).
- `request_response` accepts any response type (no expect-type on Run/mount).
- `alive?` uses bare `rescue` swallowing all exits.
- Port owner is unsupervised ad-hoc `GenServer.start` (OK per GIT.md MVP vs Firecracker helper, but no restart budget).

Compared to Firecracker helper: simple `Port.open` for launch logs — not bidirectional length-framed RPC. New high-risk pattern with thin tests.

---

### H8 — `durable.ts` is product-shaped dead code

Full OPFS/disk/memory API exported from package index; **never** used by `GitEngine.load`, `memcontainer` create, or orchestrator. Design still fantasizes `GitEngine.load(..., { durable: … })`.

`git_remote.test.ts` only round-trips `MemoryDurable` in isolation — proves nothing about worktree persistence after reload. **False readiness.**

**Tracker:** P1.2

---

### H9 — Public `@mc/core` surface dumps internals

`index.ts` re-exports ~25 git symbols (`GitBridge`, `FixtureSmartHttp`, `MemoryDurable`, `spliceCredential*`, `normalizeRel`, pack caches, etc.) plus `nodeSolvePlatform*` from `solve-node.ts`.

`docs/api-surface.json` does not fully curate this surface; develop keeps `nodeSolvePlatform` off the package root (dynamic import from solve). Exporting Emscripten bridge + test doubles freezes implementation details and invites embedders to bypass `GitEngine` (worsens single-writer).

**Tracker:** P1.3

---

### H10 — Unbound remotes: any public `https://` URL dials (JS)

`resolveGitRemote` without `connection` only checks “http(s), no userinfo” then binds auth `{ kind: "none" }` and `origins: [origin]` from the **URL itself**. Legacy `allowOrigins` is a no-op when empty.

Guest `host_call git` with `{op:"clone", args:{url:"https://attacker..."}}` is allowed at orch layer; only kernel CAP_NET / host net allowlist remains. Product docs emphasize connection-bound remotes; interactive default does **not** require a connection ref.

---

### H11 — Push incomplete on both hosts

- TS: product path errors if `buildPushPack` missing (except delete-only); fixture uses `"pushResult" in this.http` type sniffing.
- BEAM: hard stub `"push via BEAM packbuilder not yet configured on server"`.

**Not a push product.** Tracker: P2.1

---

### H12 — Doc integrity broken (K16 / K20 / Open Q #10)

| Statement | Location | Conflict |
|-----------|----------|----------|
| K16 revised: BEAM HTTPS on server | GIT.md K table, docs/git.md | Correct product intent |
| K20: “**C impl on server**” for orch | GIT.md K20 | Stale vs K16 |
| Open Q #10: “Server smart-HTTP = **C from PR9**” | GIT.md Open Questions “none remaining” | Stale; claims none remaining while text contradicts |
| Milestone text “Elixir remote e2e in PR10c (**C** orch)” | GIT.md milestones | Stale |
| `doc.md` under git-engine | package doc | Still mentioned C orch on server in places |

**Tracker:** P3.1

---

### H13 — Wasm `size_limit` may not gate optimized artifact

```python
# BUILD.bazel (review)
size_limit(
    name = "git_engine_wasm_size_limit",
    file = "git_engine.wasm",  # bare name — not clearly :git_engine_wasm_file
    max_bytes = 2 * 1024 * 1024,
)
```

Guest CLI size gate looks correct; engine wasm gate may not depend on optimized genrule output.

**Tracker:** P1.5

---

### H14 — License L4–L6 incomplete

- L1–L3: NOTICE + COPYING + corresponding_source pin — present.
- L5: notices as data/filegroup — **no test that fails if release omits them**.
- L6: “HTTPS/SSH off” documented — **no build assert** on product targets.

**Tracker:** P1.5

---

### H15 — Second build dialect (emsdk / hermetic_cc)

Develop host wasm precedent is **Rust freestanding + `release_wasm` + monorepo `wasm_opt`**. cgit adds hermetic_cc, emsdk, BCR libgit2, `force_opt.bzl`, `pick_file.bzl`. Justified by substrate; still a long-term second dialect next to the existing wasm pipeline.

---

## 5. Medium findings — naming, organization, maintainability

### 5.1 Naming inconsistency

| Surface | Pattern | Issue |
|---------|---------|--------|
| Public C API | `ge_open`, `ge_run_json` | Consistent |
| Headers | `git_engine.h`, `ge_port.h`, `ge_http.h` | Mixed prefix |
| Sources | `engine.c`, `engine_ops_extra.c`, `orch.c`, `smart_http.c`, `port_*.c` | No `ge_` module map |
| Internals | `jmin_*`, `MOUNT_OP_*`, `op_*` free functions | Unprefixed, collision risk |
| Build | `git_engine_lib`, `git-engine`, `libgit_engine` | Three product names |
| Elixir | `AgentOS.GitEngine` (flat) vs `AgentOS.Git.Orchestrator` (nested) | Inconsistent vs `Sidecars.*` |
| Elixir internal | `Jason_like` | Temp-grade name |
| JS files | kebab under `git/` | Fine; better than some develop snake leftovers |

### 5.2 Module boundaries / god files

- `ge_run_json` is a ~220-line op switch — `engine.c`.
- Mount protocol + synthetic gitfs + ctl session globals in one file — `port_mount.c` (`g_last_response[65536]`, `g_generation`).
- HTTP fixtures and “product never dials” live in the same Port library link unit as production binary.
- Triple remote orchestrator (TS / C / BEAM) already diverging on policy and push.

**Fix direction:** Split Run ops table; mount synthetic vs FS backend; compile `smart_http`/`orch` only into test targets; one algorithm SSoT with executable goldens (not step-name prose).

### 5.3 Path safety

```c
int ge_safe_relpath(const char *path) {
  if (strstr(path, "..") != NULL)
    return 0;
```

- Blocks legitimate names containing `..` as substring.
- No symlink/`realpath` confinement under worktree root.
- Mount OPEN loads entire files into memory with no size cap (`port_mount.c`).

TS `normalizeRel` has the same `includes("..")` weakness; develop `hostDir` jailing is stronger.

### 5.4 Synthetic `.git/HEAD` hard-coded to `master`

Port mount path returns `ref: refs/heads/master\n` regardless of real HEAD after checkout/branch. Guest tools reading `.git/HEAD` see lies. JS gitfs may diverge.

### 5.5 Golden `testdata/**` dead weight

`BUILD.bazel` attaches `data = glob(["testdata/..."])` but no `.c` test opens those JSON files. Algorithm “goldens” are prose step lists, not executed dual-host conformance.

### 5.6 JSON honesty hacks (Elixir)

```elixir
# soft ok on decode failure / raw contains
is_binary(raw) and String.contains?(raw, "\"ok\":true")
```

Malformed JSON can become “ok”.

### 5.7 Engine temp roots not cleaned

Server engine root under `System.tmp_dir!()` not clearly cleaned on terminate → disk leak per attach.

### 5.8 Thin CLI JSON escape incomplete

`push_escaped` only handles `\`, `"`, `\n` — not other controls; remote URL injection into request JSON is guest-local risk.

### 5.9 Feature-flag / docs lag

- `experimentalGitEngine` + `gitEngineBaseUrl` exist in types/memcontainer but **absent** from `docs/create-options.md`.
- `docs/git.md` **not linked** from `docs/index.md`.
- Root `GIT.md` (~1.5k lines, Status **Draft**) duplicates product doc; design said PR16 consolidates.
- PR markers (`PR9`, `PR10c`…) litter production comments and BUILD files.

### 5.10 Error model inconsistency

Git returns soft `GitResponse { ok, code, stderr }` (ABI-correct for ctl/host_call). Other core APIs throw typed errors (`SidecarError`). Fine at host_call boundary; awkward for SDK callers of `GitEngine.run` with no typed hierarchy.

### 5.11 Duplicated helpers

`sha256hex` triplicated in `pack-cache.ts`, `llb-git.ts`, `solve-node.ts`.  
`originAllowed` duplicated in core/git instead of importing `@mc/host`.

### 5.12 Pack cache corners (TS)

- Key index uses 32-bit FNV → collisions map different keys to one file.
- Disk `put` not atomic (no tmp+rename).
- Clone caches by key before import succeeds; failed import still leaves key→digest.
- Fetch path does not use `getByKey` (asymmetric vs clone).

### 5.13 Smart-HTTP protocol “happy path only” (TS)

`listRefs` sends `git-protocol: version=2` then falls back; body builder is classic v1 upload-pack. `parseInfoRefs` strips 4 hex digits naively. No tests against recorded real GitHub/Gitea bodies.

---

## 6. Layer deep-dives (agent reports)

### 6.1 C / native / Port — grade **D+**

**Severity counts (review):** Critical 2 · High 6 · Medium 7 · Low 5

**Solid**

- Clear public face: `ge_open` / `ge_run_json` / `ge_import_pack` / dial refuse at Run.
- Frame codec small and readable.
- Bazel packaging (native + emcc + size gate intent) thoughtful.
- Separation of `git_engine_lib` vs port lib (wasm without Port) is good.

**Blocks a higher grade**

- Lifetime/API lies (`static_oom` + free) — C7.
- Struct duplication — H1.
- Apply path untested — H2; `fetch.apply` noop — C3.
- Product gates (buffers, 64 MiB, single remote authority) not met.
- Spike comments and three orch implementations.
- Port type-1 remote intercept — C4.

**TODOs / deferrals found in C tree (review)**

| Location | Note |
|----------|------|
| `engine.c` | `add: all=true` not supported (explicit paths only) |
| `engine.c` | Full refs array import deferred |
| `engine.c` | `fetch.apply` empty success (fixed Wave 1) |
| `orch.c` | C push deferred to packbuilder |
| `json_min.c` | Spike-only shallow JSON |
| `git_engine.h` | Phantom `ge_response_is_static` (fixed Wave 1) |
| `smart_http.c` | Fixture-only; product = BEAM HTTPS |
| `engine_ops_extra.c` | `config list` only common keys; sparse “PR14” |
| `BUILD.bazel` / docs | PR0–PR10c framing throughout |

**Suggested C priority (review)**

1. Fix `ge_free`/static response (C7).  
2. Port type-1 pure `ge_run_json` (C4).  
3. Single internal engine header; indexer reset + pack size (H1/H3).  
4. Real pack+apply C tests; implement or fail-closed `fetch.apply` (H2/C3).  
5. Replace jmin / fixed caps (H4).  
6. Naming/org cleanup and dead testdata wiring.

---

### 6.2 TS / SDK — grade **C+**

**Severity counts (review):** Critical 2 · High 6 · Medium 8 · Low 5

**Solid**

- Engine purity: `REMOTE_OPS` refused in `GitEngine.run` and gitfs ctl.
- Credential splice model; secret non-echo tested for bearer headers.
- Empty connection origins fail closed when connection-bound.
- Content-addressed pack digests + 64 MiB soft gate right shape.
- `solve-node` engine-first flip correct vs develop.
- gitfs synthetic `.git/mc/ctl` + generation + dial refuse matches faces.

**Blocks a higher grade**

- Dual queue single-writer fiction (C5).  
- BEAM policy hole vs docs (C1/C2 cross-host).  
- Durable unwired (H8).  
- Soft / empty-pack tests (C2).  
- Over-exported public API (H9).  
- Unbound bare URL remotes (H10).

**Divergence from develop conventions**

| Dimension | develop norm | cgit git layer |
|-----------|--------------|----------------|
| Package layout | Flat `src/*.ts` (+ few kebab) | Nested `src/git/*` — **good** for size |
| Export style | Product API first; internals private | Wide re-export of bridges/fixtures |
| Errors | Typed `*Error` for product features | Soft `GitResponse` + plain `Error` for load |
| Orch/clients | Single host path | **Second** `originAllowed` / credential splice in core/git |
| Drivers | Shared `driverError` in `drivers.ts` | Local `fsErr` in `gitfs.ts` |
| Tests | `vm.test.ts` boots real kernel | Hand-rolled `main()` + loose assertions; env boilerplate ×5 |
| Solve | System git always | Engine-first — **improvement** if proven |

**Recommended TS merge bar (review)**

1. One lock for bridge/engine/gitfs (C5).  
2. Port connection policy to BEAM or stop claiming it (C1).  
3. Rewrite tests with real PACK fixtures.  
4. Wire or delete durable.  
5. Narrow public exports; import `originAllowed` from `@mc/host`.  
6. LLB Bazel e2e with engine runfiles.

---

### 6.3 Elixir / server — grade **D+** (security **F**, false-green **F** at review)

**Inventory vs develop**

| Area | develop | cgit |
|------|---------|------|
| Server git modules | none | `git_engine.ex`, `git/orchestrator.ex`, `git/smart_http.ex` |
| Vm git attach/demux | none | `attach_git`, monitor/detach, host_call answer |
| CP demux | sidecar only | sidecar then git |
| Tests | no git | unit Port + orch only — **no CP/Vm demux e2e** at review |

**What is actually good**

- Right ownership cut: engine dial-free; remotes in BEAM; Port types 1–4 documented; type-5 marked legacy.
- Vm lifecycle: unlinked engine + monitor + detach on DOWN/terminate; fail closed with `relay_host_call_fail` on `:eio`.
- Control plane order: sidecar claim before git.
- Bazel wiring: git-engine in `priv` + `AGENTOS_GIT_ENGINE` for tests.
- Local Port smoke (init/write/add/commit/mount/stop) is a real PR7a-shaped test.

These did **not** offset C1–C2 / H5–H7 for multi-tenant control plane at review.

**Incomplete product surface treated as “done enough”**

| Item | Status at review |
|------|------------------|
| Push | Hard stub |
| K28 host identity inject | Absent |
| Durability (PR8) | No BEAM durable store / rebind |
| K20 golden traces | No shared fixtures for Elixir orch |
| PR7d c-shared | Deferred (doc only) |
| Pack cache (K29) | JS only |
| Connection ref + splice | JS only |

**Fix order (review)**

1. Security gate before any real network.  
2. Kill empty-pack success; real pack fixtures.  
3. Async demux off the Vm process.  
4. Wire connections/auth from boot opts.  
5. Tighten Port framing + cleanup + JSON.  
6. Push / K28 inject / durability as separate PRs.

---

### 6.4 Develop norms divergence — severity-ranked

| Severity | Divergence |
|----------|------------|
| **Critical** | Public `@mc/core` export flood without api-surface hygiene; `nodeSolvePlatform*` on package root |
| **High** | Root draft `GIT.md` + orphan `docs/git.md` (not in index); create-options undocumented; emsdk/hermetic_cc second dialect; triple orch |
| **Medium** | C tests at package root not `test/`; `doc.md` / `SOURCE_PIN.md` invent names; no guest `skills/`; size target naming; five near-duplicate js_tests; experimental flag docs lag |
| **Low** | kebab vs snake mix; PR noise in BUILD |

**What matches develop well**

1. Host placement: `lib/`, `programs/`, SDK under core, server Port owner.  
2. Guest program: `mc_rust_program(tier="full")` + optional layer.  
3. Hermetic third_party: BCR pin + patch + NOTICE.  
4. Size gates use monorepo `size_limit`.  
5. Post-link wasm_opt reuses Binaryen policy.  
6. Experimental opt-in lazy load.  
7. Capability story consistent with connections thesis.  
8. Server packaging stages binary like NIF/browser-ctl.

**Highest-value re-align fixes**

1. Shrink public exports; leave fixtures/credentials unexported.  
2. Update `docs/api-surface.json` + index + create-options.  
3. One remote algorithm SSoT + executable vectors.  
4. Rename third_party narrative to `SYSTEM.md`; move C tests under `test/`.  
5. Keep root `GIT.md` only as systems annex linked from `SYSTEMS.md`, or fold into `docs/git.md`.

---

## 7. Remaining work from `GIT.md` (full inventory)

Primary sources: workspace/worktree `GIT.md`, `docs/git.md`, code comments (TODO/future/deferred).

### A. Explicitly deferred / out of surface (still correct non-goals)

| Item | Status |
|------|--------|
| Full git-core parity | Non-goal |
| wasmi multi‑MiB VCS | Rejected |
| gojs / Go NIF / go-git product | Rejected |
| Ambient `~/.git-credentials` | Non-goal |
| **`.git/objects` façade v1** | Synthetic HEAD/refs/ctl only — matches |
| Freestanding zig/wasmtime engine | Rejected K25 |
| Composite Rust intercept for `/repo` and `git` | Deferred |
| Submodules | Phase C later |
| Rebase, bisect, LFS, worktrees-as-feature, `git gui`, guest receive-pack | Out of surface |
| Multi-mount multi-Port demux | post-v1; v1 one mount K21 |
| Cap bits on mount for remotes | Explicitly not required (ctl remotes refuse) |
| Browser OPFS/IndexedDB full ODB | Later PR language |
| c-shared in-process | Deferred in alts table; **K15 says immediately after MVP** — artifact exists, not operationalized |
| Full patch `diff` | status-style first; full later |
| Catalog tool `git run` (optional Face B) | Optional / unclear shipped |

### B. Documented as done / shipped shape — incomplete or wrong at review

| Claim | Reality at `020cc8b` |
|-------|----------------------|
| PR0–PR6 local JS plane | Mostly present; buffer/`add -A`/CLI surface debt |
| PR7a/b Port + type-4 | Present skeleton; kill→EIO guest e2e thin |
| K16 BEAM HTTPS orch | Skeleton only — no allowlist; empty-pack success; no push |
| PR10a/b JS remotes | API present; tests under-assert; CLI clone order broken |
| PR11 connections | **JS yes / server no** |
| PR12 push | JS partial (no real packbuilder) / server no |
| PR8 durability | APIs only; not wired as ODB rebind |
| PR13 pack cache | Helpers; not universal LLB+interactive wiring |
| PR14 sparse | Engine ops only |
| PR15 LLB | Engine path exists; `MC_GIT_USE_SYSTEM=1` remains; no hard CI e2e |
| PR1 product buffers | **Failed** (spike caps remain) |
| K28 identity | **Violated** (Agent@example.com defaults) |
| K20 dual-host orch | Stale vs K16; goldens not executable |
| L4–L6 license gates | Partial; no hard L5 fail-if-omitted |
| `experimentalGitEngine` | Still experimental (PR16 graduation) |
| Dual design docs | Root + worktree `GIT.md` both live; Status Draft |
| `fetch.apply` complete before remotes GA | Pure no-op |
| `add all=true` productized | Still spike-deferred |
| Wasm size gate | Likely miswired to bare filename |
| Thin CLI phase A | Missing rm/diff/show/reset/tag/config/remote/switch/sparse |

### C. Documented next work (PR16+ and incomplete PR tails)

| Item | Doc intent | Code reality |
|------|------------|--------------|
| **PR16** | Docs, metrics, budgets, flag graduation | Not started as product polish |
| **PR7d** | c-shared after Port MVP | Artifact only |
| **PR12 server** | push.prepare / receive-pack / push.complete | Server push stub |
| **PR11 server** | connection-ref + splice + approval | JS only |
| **PR8 real durability** | OPFS/disk rebind across refresh/snapshot | APIs only |
| **PR13 production cache** | shared CA pack cache LLB+interactive | Partial helpers |
| **PR14 sparse** | monorepo materialization | Engine ops only |
| **PR15 LLB** | shared stack end state | Engine when env set; system escape remains |
| Multi-repo / multi-Port | post-v1 | Not started |
| Observability | engine/orch/mount metrics | Not productized |

There is **no PR17+** table; remaining work is unfinished tails of PR7d–PR16 plus honesty gaps.

### D. Silent gaps (production-critical; weak/absent in docs progress)

| Gap | Why it matters |
|-----|----------------|
| No real public-HTTPS e2e (JS or BEAM) asserting worktree files | All orch tests use empty/fake packs |
| No guest CAP_NET e2e thin `/bin/git` → kernel → host_call → orch | Host-level unit tests only |
| No kill-Port → guest EIO Elixir e2e as PR7a acceptance | Unit-ish Port tests only |
| No MountFs drain/ctl race full guest e2e (`client_token`) | Driver unit only |
| Server auth/SSRF | BEAM dialed any URL if CAP_NET present |
| `handle_host_call` without VM connection catalog | Attach git without secrets/policy |
| Pack size 64 MiB | TS yes; BEAM unclear at review |
| Stdout truncation / `result.truncated` / 1 MiB limits | Not in engine responses |
| Default image layer | `git_layer` optional; `/bin/git` not default guest image |
| K21 one-mount enforcement | Not clearly fail-closed on second gitfs mount |
| Hermetic_cc scoped only? | Present for git; monorepo risk if default toolchain drifts |

### E. False confidence / false-green test areas (review)

| Test / path | Why false-green |
|-------------|-----------------|
| `git_remote.test.ts` | Empty pack; accepts success **or** post-list-refs failure |
| `AgentOS.Git.OrchestratorTest` | Empty pack; skip apply; assert `ok:true` / `"cloned"` |
| `fetch.apply` unit path | Always ok — cannot fail meaningfully |
| `git_push.test.ts` | Injects builder + fixture; not real receive-pack |
| C `smart_http.c` / `orch.c` | Fixture table; linked into Port — looks like server remotes work without BEAM HTTPS |
| Golden orch JSON | Step names only — not executed dual-host |
| `abi_dual_test` / PR7c | Not true emcc↔native byte-identical dual runner in one test |
| LLB `vm.test.ts` git cases | May still be system-git / local fixtures depending on env |
| `size_limit` on `git_engine.wasm` string | May not gate optimized product artifact |
| L5 NOTICE in package | `data = notices` does not fail if ship path forgets them |

### F. Priority-ordered recommended next work (review)

#### P0 — Correctness & security (block remotes GA)

1. Real `fetch.apply` (or fail closed).  
2. Fix server clone success on empty pack.  
3. Server origin allowlist + connections (port PR11 semantics to BEAM).  
4. Remove/quarantine C remote orch from product Port type-1.  
5. Real HTTPS / real pack integration tests.  
6. Thin CLI remote discovery order.  
7. `ge_free` / static OOM.  
8. One shared serial lock.  
9. K28 identity honesty.

#### P1 — Product honesty / engine debt

10. Growable buffers; drop spike `add all` or document.  
11. Wire or delete durable.  
12. Narrow `@mc/core` exports; docs index/create-options/api-surface.  
13. Wasm size_limit + L5 NOTICE CI.  
14. Async BEAM demux.  
15. Guest CAP_NET / demux e2e.  
16. Import `originAllowed` from `@mc/host`.

#### P2 — Completeness of designed PRs

17. Push packbuilder or server read-only remotes documented.  
18. Thin CLI phase-A or document reduced CLI.  
19. PR7d decide load path or demote K15.  
20. LLB CI requires engine.  
21. Sparse + pack cache production wiring.  
22. Server PR11 connection splice.  
23. Executable golden orch vectors TS ↔ BEAM.

#### P3 — PR16 polish

24. Single design-of-record `GIT.md`; fix K16/K20/Open-Q#10/doc.md.  
25. Graduate experimental flag; metrics.  
26. Product agent docs (one-mount, no objects façade, ctl flush).  
27. Status Draft → accurate progress table.

### Cross-check: “PR0–PR15 / K16 BEAM HTTPS done?”

| Claim | Verdict at review |
|-------|-------------------|
| PR0–PR6 local JS | **Mostly present**; buffer/CLI/`add -all` debt |
| PR7a/b Port + type-4 mount | **Present** |
| K16 BEAM HTTPS orch | **Present skeleton**; **not production-safe** |
| PR10a/b JS remotes | **API present**; tests **under-assert** |
| PR11 connections | **JS yes / server no** |
| PR12 push | **JS partial** / **server no** |
| PR15 LLB | **Engine path exists**; system-git escape remains |
| PR16 | **Not done** |
| Design “Open questions: none” | **False** — doc drift + unfinished GA criteria |

---

## 8. Explicit “kept for future” inventory (code + design)

| Kept for future | Location / note |
|-----------------|-----------------|
| Full patch `diff` | GIT.md PR1.1 / phase A |
| `add all=true` worktree walk | `engine.c` “spike” |
| Full refs array import | `engine.c` |
| C / BEAM push packbuilder | `orch.c`, BEAM stub, TS inject |
| c-shared in-process engine | K5/K15, PR7d |
| Multi-mount / multi-Port | K9/K21, post-v1 |
| Cap bits on mount for remotes | Explicitly not required |
| Composite Rust intercept | Deferred |
| OPFS/IndexedDB pack ODB | Later PR |
| Submodules | Phase C later |
| Browser full durability rebind | PR8 incomplete |
| Metrics / flag graduation | PR16 |
| Catalog tool `git run` | Optional Face B |
| Streaming large stdout / `result.truncated` | §5.3 later |
| Multi-repo `args.mount` demux | post-v1 |

---

## 9. Bottom line

This branch is a **credible host-source-plane scaffold** with the right security *thesis* (dial-free engine, CAP_NET, host credentials). It is **not** at develop’s quality bar for:

- security parity between hosts,
- honest tests,
- single-writer correctness,
- public API hygiene,
- or design-doc integrity.

**Do not treat “PR0–PR15 landed” as remotes-ready.** Highest leverage before more features: **policy + false-greens + type-1 purity + CLI clone order + single-writer + real pack apply**.

---

## 10. Wave 1 remediation status (same day; not part of review baseline)

Tracked in [`TASKS.md`](./TASKS.md). Summary after agents + serial glue:

| ID | Finding | Status |
|----|---------|--------|
| P0.1 | C1 BEAM origin/status/size | Done (uncommitted); connection catalog still open |
| P0.2 | C2 empty-pack honesty | Done (uncommitted) |
| P0.3 | Real pack e2e | Partial — fixture bytes staged |
| P0.4 | C3 fetch.apply | Done + BEAM/TS args glue |
| P0.5 | C4 Port type-1 | Done |
| P0.6 | C6 CLI order | Done |
| P0.7 | C7 ge_free | Done |
| P0.8 | C5 single-writer | Done |
| P0.9 | C8 K28 fail-closed | Done; host inject still open |

Verification samples: C `//memcontainers/lib/git-engine` tests; JS `git_*` tests; mix `git_orchestrator_test` + `git_engine_test` (12 passed with absolute `AGENTOS_GIT_ENGINE`).

---

## 11. How this document relates to the live conversation

The user-facing review in chat on 2026-07-31 is the **same substance** as §§1–9 above, expanded with per-layer agent evidence (file paths, tables, deferred inventories, dimension scores) so the worktree holds a **trackable archival report**, not a summary of a summary.

**Do not** replace this file with a short “status” note. Update **`TASKS.md`** for checkbox progress; append Wave notes here only when findings are fully closed or the design bar changes.
