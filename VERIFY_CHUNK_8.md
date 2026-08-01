# VERIFY_CHUNK_8

Verdict: **PASS**

Hostile verifier for `feature/cgit` Chunk 8 (D25–D31 guest acceptance; D27–D28 real HTTP not Fixture-only; D32 may remain OPEN). Tree: `feature/cgit` @ `a5c23de` + dirty working tree. No product code changed by this verifier.

---

## Acceptance matrix

| # | Requirement | Result | Evidence |
|---|-------------|--------|----------|
| 1 | **D25** server guest CAP_NET allow full path | **PASS** | See A1 |
| 2 | **D26** server CAP_NET deny fails closed, no dial | **PASS** | See A1 |
| 3 | **D27** real HTTP clone (product SmartHttp) | **PASS** | See A2 |
| 4 | **D28** real HTTP push (product receive-pack) | **PASS** | See A2 |
| 5 | **D29** Port kill → guest EIO / fail closed | **PASS** | See A1 |
| 6 | **D30** gitfs mount+ctl on booted guest | **PASS** | See A1 |
| 7 | **D31** client_token + generation race | **PASS** | See A1 |
| 8 | **D32** full golden set | **OPEN (allowed)** | See A3 |
| 9 | Tests green | **PASS** | See A4 |

Chunk 8 acceptance (D25–D31 + real HTTP) holds. D32 remaining OPEN is explicitly allowed. Verdict **PASS**.

---

## A1 — D25–D26, D29–D31 server guest / Port acceptance — PASS

Source: `/mnt/workspace/agent-os/agent-os-cgit/server/test/agent_os/git_guest_acceptance_test.exs`  
Product glue: `Vm.drain_git_relay/2` on tick (`server/lib/agent_os/vm.ex`) so guest host_call `"git"` is answered without a separate egress pump.

| ID | Proof path | Hard asserts (not theater) |
|----|------------|----------------------------|
| **D25** | loom + `host_call: :relay` + `attach_git` fixture transport + `ControlPlane.run("git", ["clone", url])` | exit 0; transport dials **≥2**; worktree `README` = `hello\n` |
| **D26** | boot `contract: {tier_read_write, …}` (no CAP_NET) | deny marker (`CAP_NET`/`host_call`/`EPERM`/…); dials **== 0** |
| **D29** | booted guest `git init` OK → `Port.close` engine Port → next `git status` fails | guest-visible failure; engine Run → `{:error, …}` |
| **D30** | booted guest `/bin/git` init/status/add under mount; host commit; ctl fetch refuse remotes | type-4 ctl round-trip; remote refuse on ctl |
| **D31** | Port `mount_op` ctl write with `args.client_token` | token echoed; `/.git/mc/generation` +1 per write; second token wins; type-1 Run echoes |

**mix_test log evidence (this run):** engine roots `agentos-d25-*`, `agentos-d26-*`, `agentos-d29-*`, `agentos-d30-*` started; suite green.

**Not false DONE:**

- D25 uses **fixture** transport (list_refs/fetch_packs inject), not live public HTTPS. That is correct for CAP_NET/host_call path; live smart-HTTP is D27/D28.
- D31 is Port/gitfs mount_op level (not full guest boot). Still acceptance for the race surface claimed; C `attach_client_token` + `port_mount` generation match.

**Soft residuals (not FAIL):**

- D25 string match on stdout is loose (`or result.exit_code == 0`); real proof is dials + README.
- D29 engine assert accepts any `{:error, _}` after preferring `:eio`.

---

## A2 — D27–D28 real HTTP (not Fixture only) — PASS

| Host | Target | Transport | Proof |
|------|--------|-----------|-------|
| **JS** | `//memcontainers/sdk-js/core:git_real_http_test` | **`FetchSmartHttp`** (not `FixtureSmartHttp`) + local `git-http-backend` CGI | clone/fetch/push against real smart-HTTP |
| **BEAM** | `server/test/agent_os/git_real_http_test.exs` | **`AgentOS.Git.SmartHttp`** + `Orchestrator` (no `:transport` fixture) | list-refs + pack fetch + orch clone/fetch; push advances bare tip; second clone sees file |
| Helper | `server/test/support/git_http_backend.exs` | system git + `/usr/lib/git-core/git-http-backend` | shared real server |

Product also advertises `report-status` on receive-pack (`smart_http.ex` / `smart-http.ts`) for real git-receive-pack.

**mix_test log:** `real-http-clone-*`, `real-http-push-*`, `real-http-push-verify-*` roots; objects enumerated via real git.  
**JS:** `git_real_http_test` **PASSED**.

---

## A3 — D32 goldens — OPEN (allowed)

| Present (orch testdata) | Still missing (TASKS honesty) |
|-------------------------|-------------------------------|
| `clone_success_steps`, `clone_empty_pack_fail`, `clone_algorithm`, `fetch_success_steps`, `fetch_algorithm`, `origin_denied`, `pull_ff_steps`, `push_readonly`, `push_success_steps` | shallow / auth deny / non-FF vectors |

D32 correctly remains **OPEN**. Dual-host golden runners green for the set that exists (`git_orch_golden_test` JS + BEAM via mix_test). Incomplete set ≠ Chunk 8 FAIL under the stated rule.

---

## A4 — Tests green — PASS

```
//memcontainers/sdk-js/core:git_real_http_test    PASSED
//memcontainers/sdk-js/core:git_orch_golden_test  PASSED
//server:mix_test                                 PASSED  (117 tests, 0 failures, 2 excluded kvm)
```

Includes guest acceptance + real HTTP + orch/metrics cases.

---

## Hostile residual (not FAIL)

| Item | Severity | Note |
|------|----------|------|
| `docs/git.md` still claims server CAP_NET **Open** (D25/D26) and lists D25–D31 as remaining OPEN | Tracker/docs lag (D5) | Code + mix_test prove DONE; do not re-open inventory as OPEN |
| D31 not full guest boot | Soft | Port mount_op is the ctl surface under test |
| Bazel cannot build `git_real_http_test` + `git_orch_golden_test` in one invocation (conflicting `package.json` CopyFile) | Tooling | Each alone green; package hygiene debt |
| D32 incomplete goldens | By design OPEN | Not a Chunk 8 FAIL |

---

## False-DONE traps checked

| Trap | Outcome |
|------|---------|
| CAP_NET “e2e” only on JS fixture | **Rejected** — server D25/D26 with loom + relay + dial counters ran green |
| Real HTTP = FixtureSmartHttp with a URL | **Rejected** — product FetchSmartHttp / SmartHttp + system git-http-backend |
| D32 marked DONE with incomplete vectors | **Rejected** — still OPEN in TASKS |
| Port kill theater without guest failure | **Rejected** — guest exec fails after Port.close |
