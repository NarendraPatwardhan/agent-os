# @generated from contracts/git.kdl by //contracts/codegen:projector — do not edit.
defmodule AgentOS.Contracts.Git do

  # dual-host defaults
  def default_clone_depth, do: 1
  def default_fetch_depth, do: 0
  def default_max_pack_bytes, do: 67108864
  def max_pack_zero_means_default, do: 1
  def pack_magic_required, do: 1
  def redirect_never, do: 1

  # guest body secret keys (fail closed)
  def guest_secret_arg_keys do
    [
      "token",
      "auth",
      "authorization",
      "password",
      "pass",
      "bearer",
      "secret",
      "secrets",
      "credentials",
      "credential",
      "apikey",
      "api_key",
      "accesstoken",
      "access_token",
      "privatekey",
      "private_key",
      "client_secret",
      "clientsecret",
    ]
  end

  # stable stderr prefixes (substring-stable)
  def stderr_prefix do
    %{
      unknown_connection: "git: unknown connection ref",
      empty_pack: "git: empty pack",
      origin_not_allowlisted: "git: origin not allowlisted",
      not_fast_forward: "git: not fast-forward",
      guest_auth_secrets: "git: guest body must not include auth secrets",
      push_read_only: "git: push rejected (read-only mount)",
      redirect_not_allowed: "git: redirect not allowed",
      empty_origins: "git: empty connection origins",
      query_auth_unsupported: "git: query auth not supported for remotes",
      invalid_auth: "git: invalid connection auth",
    }
  end
  def stderr_line(id, detail \\ nil) do
p = Map.fetch!(stderr_prefix(), id)
if is_binary(detail) and detail != "" do
p <> " " <> detail <> "\n"
else
p <> "\n"
end
end

  # algorithm step orders
  def algorithm_steps do
    %{
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
    }
  end

  # GitResponse required keys
  def response_keys do
    [
      "ok",
      "code",
      "stdout",
      "stderr",
    ]
  end
end
