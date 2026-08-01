// @generated from contracts/git.kdl by //contracts/codegen:projector — do not edit.
# Git remote orch contract

Projected from `contracts/git.kdl`. Hosts consume TS/Elixir projections.

### dual-host defaults

- `default_clone_depth` = `1`
- `default_fetch_depth` = `0`
- `default_max_pack_bytes` = `67108864`
- `max_pack_zero_means_default` = `1`
- `pack_magic_required` = `1`
- `redirect_never` = `1`

### guest body secret keys (fail closed)

| key |
|-----|
| `token` |
| `auth` |
| `authorization` |
| `password` |
| `bearer` |
| `secret` |
| `api_key` |
| `access_token` |
| `private_key` |
| `client_secret` |

### stable stderr prefixes (substring-stable)

| id | prefix |
|----|--------|
| `unknown_connection` | `git: unknown connection ref` |
| `empty_pack` | `git: empty pack` |
| `origin_not_allowlisted` | `git: origin not allowlisted` |
| `not_fast_forward` | `git: not fast-forward` |
| `guest_auth_secrets` | `git: guest body must not include auth secrets` |
| `push_read_only` | `git: push rejected (read-only mount)` |
| `redirect_not_allowed` | `git: redirect not allowed` |
| `empty_origins` | `git: empty connection origins` |

### algorithm step orders

#### `clone`

1. `resolve_remote_url`
1. `origin_allowlist`
1. `list_refs`
1. `select_head_tip`
1. `fetch_packs`
1. `import_pack`
1. `refs_import`
1. `clone_apply`

#### `fetch`

1. `resolve_remote_url`
1. `origin_allowlist`
1. `list_local_have`
1. `list_refs`
1. `fetch_packs`
1. `import_pack`
1. `refs_import`
1. `fetch_apply`

#### `push`

1. `resolve_remote_url`
1. `origin_allowlist`
1. `push_policy`
1. `push_prepare`
1. `list_refs_lease`
1. `pack_build`
1. `receive_pack`
1. `push_complete`


### GitResponse required keys

- `ok`
- `code`
- `stdout`
- `stderr`
