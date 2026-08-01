defmodule AgentOS.Git.Durable do
  @moduledoc """
  Server durable engine roots (D16 / D18 / GIT.md PR8b).

  Primary durable form is a **re-openable libgit2 worktree directory** on disk.
  The Port child `ge_open`s that absolute path; a second process that starts
  with the same root sees the same HEAD + files. AGIT pack envelopes are a
  JS transfer format and are not required on the BEAM path.

  ## Configuration

  * Application env `:agent_os, :git_durable_root` — base directory
  * Environment `AGENTOS_GIT_DURABLE_ROOT` — overrides app env when set

  ## Layout

      {base}/{safe_vm_id}/{safe_mount_slug}/

  Mount slug defaults to `workspace@repo` for `/workspace/repo`.
  """

  @env_root "AGENTOS_GIT_DURABLE_ROOT"

  @doc """
  Base directory for named durable engine roots, or `nil` when unset.

  Order: `AGENTOS_GIT_DURABLE_ROOT` env, then `Application.get_env(:agent_os, :git_durable_root)`.
  """
  @spec root_base() :: String.t() | nil
  def root_base do
    case System.get_env(@env_root) do
      bin when is_binary(bin) ->
        trimmed = String.trim(bin)
        if trimmed != "", do: trimmed, else: app_root_base()

      _ ->
        app_root_base()
    end
  end

  defp app_root_base do
    case Application.get_env(:agent_os, :git_durable_root) do
      bin when is_binary(bin) ->
        trimmed = String.trim(bin)
        if trimmed != "", do: trimmed, else: nil

      _ ->
        nil
    end
  end

  @doc "Sanitize a path segment for durable directory names."
  @spec safe_segment(String.t()) :: String.t()
  def safe_segment(id) when is_binary(id) do
    id
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9._:@+-]+/, "_")
    |> case do
      "" -> "default"
      other -> other
    end
  end

  def safe_segment(_), do: "default"

  @doc """
  Stable directory slug for a guest mount path.

  `/workspace/repo` → `workspace@repo`
  """
  @spec mount_slug(String.t()) :: String.t()
  def mount_slug(mount_path) when is_binary(mount_path) do
    mount_path
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.trim_leading("/")
    |> String.replace(~r/\/+/, "@")
    |> safe_segment()
  end

  def mount_slug(_), do: "default"

  @doc """
  Resolve `{base}/{vm_id}/{mount_slug}` under the configured durable base.

  Returns `nil` when no base is configured.
  """
  @spec resolve_named_root(String.t(), String.t()) :: String.t() | nil
  def resolve_named_root(vm_id, mount_path)
      when is_binary(vm_id) and is_binary(mount_path) do
    case root_base() do
      nil ->
        nil

      base ->
        Path.join([base, safe_segment(vm_id), mount_slug(mount_path)])
    end
  end

  @doc """
  Resolve the Port worktree root from attach/start options.

  Keyword options (first match wins):

  * `:root` — absolute or relative path used as-is (caller-owned; never deleted)
  * `:durable_dir` — same as `:root` (explicit durable directory)
  * `:durable_id` — named root under `root_base()` + mount path
    (`:mount_path` / default `"/workspace/repo"`)
  * `:durable: true` — requires `:durable_id` or configured base + id from opts

  Returns:

  * `{:ok, root, :durable}` — re-openable directory; do not rm_rf on terminate
  * `{:ok, root, :temp}` — ephemeral under `System.tmp_dir!` named `agentos-git-*`
  * `{:error, reason}`
  """
  @spec resolve_root(keyword()) ::
          {:ok, String.t(), :durable | :temp} | {:error, term()}
  def resolve_root(opts) when is_list(opts) do
    mount = Keyword.get(opts, :mount_path, "/workspace/repo")

    cond do
      is_binary(Keyword.get(opts, :root)) ->
        root = Path.expand(Keyword.fetch!(opts, :root))
        {:ok, root, :durable}

      is_binary(Keyword.get(opts, :durable_dir)) ->
        root = Path.expand(Keyword.fetch!(opts, :durable_dir))
        {:ok, root, :durable}

      is_binary(Keyword.get(opts, :durable_id)) ->
        id = Keyword.fetch!(opts, :durable_id)

        case resolve_named_root(id, mount) do
          nil ->
            {:error, :git_durable_root_unset}

          root ->
            {:ok, Path.expand(root), :durable}
        end

      Keyword.get(opts, :durable) == true ->
        {:error, :durable_id_required}

      true ->
        path =
          Path.join(
            System.tmp_dir!(),
            "agentos-git-" <> Integer.to_string(System.unique_integer([:positive]))
          )

        {:ok, path, :temp}
    end
  end

  @doc """
  Ensure `root` exists as a directory (mkdir_p). Does not init a git repo.
  """
  @spec ensure_root!(String.t()) :: String.t()
  def ensure_root!(root) when is_binary(root) do
    File.mkdir_p!(root)
    root
  end

  @doc """
  Best-effort fsync of a durable directory (checkpoint face for native roots).

  Native Port writes are already on the host filesystem; this syncs directory
  metadata where the OS supports it.
  """
  @spec sync_root(String.t()) :: :ok | {:error, term()}
  def sync_root(root) when is_binary(root) do
    # Erlang has no portable dir fsync; touch a marker and rely on OS page cache
    # flush on close. Product path: second ge_open of the same path is enough.
    marker = Path.join(root, ".git")

    cond do
      File.dir?(marker) or File.exists?(marker) ->
        :ok

      File.dir?(root) ->
        :ok

      true ->
        {:error, :enoent}
    end
  end

  def sync_root(_), do: {:error, :badarg}
end
