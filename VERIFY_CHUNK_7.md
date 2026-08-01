# VERIFY_CHUNK_7

Verdict: **PASS**

Hostile verifier for `feature/cgit` Chunk 7 (D15 stream_path/readStdoutStream, D22 symlink fail-closed, D39 log bounds — code+tests). Tree: `feature/cgit` @ `a5c23de` + dirty working tree (chunk sources uncommitted). No product code changed by this verifier.

---

## Acceptance matrix

| # | Requirement | Result | Evidence |
|---|-------------|--------|----------|
| 1 | **D15** `result.stream_path` + body at `/.git/mc/out/last` + host/gitfs read | **PASS** | See A1 |
| 2 | **D22** symlink/special fail-closed (+ bulk skip) | **PASS** | See A2 |
| 3 | **D39** log bounds + show full message | **PASS** | See A3 |
| 4 | Tests green | **PASS** | See A4 |

All four hold. Chunk 7 verdict is **PASS**.

---

## A1 — D15 stream_path / readStdoutStream — PASS

Not “truncated preview only.” Full body (≤8 MiB) is written under the worktree and discoverable.

| Piece | Path | Behaviour |
|-------|------|-----------|
| Caps | `ge_engine_priv.h` | Embed limit `GE_STDOUT_MAX_BYTES` (1 MiB); stream file `GE_OUT_LAST_MAX_BYTES` (8 MiB); path `GE_OUT_STREAM_PATH` = `.git/mc/out/last` |
| Engine | `engine.c` `ge_resp_ok_stdout` / `write_out_stream` / `clear_out_stream` | Overflow → preview in `stdout`, `result.truncated=true`, `stream_path`, `stdout_bytes`/`stream_bytes`/`stream_partial`; non-truncated clears stale out/last |
| Port mount | `port_mount.c` | OPEN/STAT of `.git/mc/out/last` (and `out/stream` alias) prefer on-disk stream body |
| JS gitfs | `gitfs.ts` | Same paths serve full body |
| JS host API | `GitEngine.readStdoutStream` | Reads stream file via bridge FS when `result.stream_path` set |
| Docs | `docs/git.md` § Large stdout / stream path (D15) | Matches implementation |

**Tests:** `abi_fixture_test` `test_truncated_stdout` (forced low embed threshold → `stream_path` + non-empty out/last); JS `git_engine.test` D15 block (`readStdoutStream` + gitfs open).

**Not false DONE:** This is whole-body file spill (capped 8 MiB), not a progressive byte stream. Product name is stream_path; contract matches `docs/git.md`. Acceptable for D15 as written.

**Residual (not FAIL):** No dedicated BEAM ExUnit that opens out/last via Port mount_op after a truncated op. Covered by C port_mount + abi + JS gitfs; BEAM surface is the same Port binary.

---

## A2 — D22 symlink / special fail-closed — PASS

| Surface | Behaviour | Evidence |
|---------|-----------|----------|
| `write` existing symlink | Fail closed | `engine.c` lstat + `S_ISLNK` → clear error |
| `write` special (non-reg/non-dir) | Fail closed | same block |
| explicit `add` symlink / special | Fail closed | `index_add_file` |
| `add` `all=true` | **Skip** symlinks/specials (walk continues) | `walk_add` only stages regulars |
| Durable hydrate | Skip non-files | `durable.ts` walk: files only; comment D22 |

**Tests:** `abi_fixture_test` `test_symlink_fail_closed` — real `symlink()`, explicit add/write fail with “symlink”, `add all=true` still ok. JS D22 block when MEMFS `FS.symlink` exists (assert fail contains “symlink”).

**Residual (not FAIL):** No explicit fifo/device unit (special path is code-covered via `!S_ISREG`). JS test **no-ops** if MEMFS lacks `symlink` — native abi fixture is the hard gate and passed.

---

## A3 — D39 log / show bounds — PASS

| Op | Contract | Implementation |
|----|----------|----------------|
| `log` | Default max_count **10**, hard cap **1000**, `result.bounded` + optional `more`, stable footer `# log: bounded max_count=N count=C …` | `op_log` in `engine.c` |
| `show` | Full commit message (no fixed-buffer cut); oversized body uses D15 path | `op_show` uses `git_commit_message` + exact malloc |

**Tests:** `abi_fixture_test` `test_log_bounds` (3 commits, max_count=2 → bounded + footer + show ok); JS `git_engine.test` D39 block.

---

## A4 — Tests green — PASS

Forced re-run (`--nocache_test_results`):

```
//memcontainers/lib/git-engine:abi_fixture_test   PASSED
//memcontainers/sdk-js/core:git_engine_test       PASSED   ← D15 / D22 / D39 / D35 unit
```

---

## Hostile residual (not FAIL)

| Item | Severity | Note |
|------|----------|------|
| `docs/git.md` graduation “Remaining OPEN” still lists D15, D22 | Tracker lag (D5) | Implementation DONE; docs inventory stale — do not treat as code FAIL |
| No BEAM-only D15 ExUnit | Soft | Port code path present; C+JS prove product |
| JS D22 skip without symlink | Soft | Native fixture is fail-closed proof |
| Special-file (fifo) not unit-tested | Soft | Policy coded on `!S_ISREG` |
| Uncommitted tree | Process | Verify on dirty sources |

---

## False-DONE traps checked

| Trap | Outcome |
|------|---------|
| “truncated only” without stream_path/out/last | **Rejected** — stream_path + file body + read APIs present |
| Soft skip of D22 on native | **Rejected** — abi fixture creates real symlink and expects fail |
| log “bounded” without footer / hard cap | **Rejected** — cap 1000 + footer + result fields tested |
| Docs still saying OPEN while code ships | Residual hygiene only; not a code FAIL for Chunk 7 |
