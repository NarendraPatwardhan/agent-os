// @generated from contracts/git.kdl by //contracts/codegen:projector — do not edit.

// dual-host defaults
export const default_clone_depth = 1;
export const default_fetch_depth = 0;
export const default_max_pack_bytes = 67108864;
export const max_pack_zero_means_default = 1;
export const pack_magic_required = 1;
export const redirect_never = 1;
export const DEFAULT_CLONE_DEPTH = default_clone_depth;
export const DEFAULT_FETCH_DEPTH = default_fetch_depth;
export const DEFAULT_MAX_PACK_BYTES = default_max_pack_bytes;
export const MAX_PACK_ZERO_MEANS_DEFAULT = true;
export const PACK_MAGIC_REQUIRED = true;
export const REDIRECT_NEVER = true;

// guest body secret keys (fail closed)
export const GUEST_SECRET_ARG_KEYS = [
  "token",
  "auth",
  "authorization",
  "password",
  "bearer",
  "secret",
  "api_key",
  "access_token",
  "private_key",
  "client_secret",
] as const;

// stable stderr prefixes (substring-stable)
export const STDERR_PREFIX = {
  unknown_connection: "git: unknown connection ref",
  empty_pack: "git: empty pack",
  origin_not_allowlisted: "git: origin not allowlisted",
  not_fast_forward: "git: not fast-forward",
  guest_auth_secrets: "git: guest body must not include auth secrets",
  push_read_only: "git: push rejected (read-only mount)",
  redirect_not_allowed: "git: redirect not allowed",
  empty_origins: "git: empty connection origins",
} as const;
export type StderrPrefixId = keyof typeof STDERR_PREFIX;
export function stderrLine(id: StderrPrefixId, detail?: string): string {
const p = STDERR_PREFIX[id];
if (detail && detail.length > 0) return `${p} ${detail}\n`;
return `${p}\n`;
}

// algorithm step orders
export const ALGORITHM_STEPS = {
  clone: [
    "resolve_remote_url",
    "origin_allowlist",
    "list_refs",
    "select_head_tip",
    "fetch_packs",
    "import_pack",
    "refs_import",
    "clone_apply",
  ],
  fetch: [
    "resolve_remote_url",
    "origin_allowlist",
    "list_local_have",
    "list_refs",
    "fetch_packs",
    "import_pack",
    "refs_import",
    "fetch_apply",
  ],
  push: [
    "resolve_remote_url",
    "origin_allowlist",
    "push_policy",
    "push_prepare",
    "list_refs_lease",
    "pack_build",
    "receive_pack",
    "push_complete",
  ],
} as const;

// GitResponse required keys
export const RESPONSE_KEYS = [
  "ok",
  "code",
  "stdout",
  "stderr",
] as const;
