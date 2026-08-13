defmodule AgentOS.Git.Durable do
  @moduledoc """
  Server durable engine roots (SYSTEMS.md §11b A8 rebind).

  Primary durable form is a re-openable native Gitz worktree directory on disk.
  The Port session opens that absolute path; a second process that starts
  with the same root sees the same HEAD + files. The BEAM path does not use a
  blob envelope because the directory itself is the durable store.

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
      "." -> "default"
      ".." -> "default"
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
        explicit_root(Keyword.fetch!(opts, :root))

      is_binary(Keyword.get(opts, :durable_dir)) ->
        explicit_root(Keyword.fetch!(opts, :durable_dir))

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

  defp explicit_root(path) do
    if String.trim(path) == "" do
      {:error, :unsafe_git_root}
    else
      root = Path.expand(path)

      if Path.dirname(root) == root,
        do: {:error, :unsafe_git_root},
        else: {:ok, root, :durable}
    end
  end

  @doc """
  Ensure `root` exists as a directory (mkdir_p). Does not init a git repo.
  """
  @spec ensure_root!(String.t()) :: String.t()
  def ensure_root!(root) when is_binary(root) do
    expanded = Path.expand(root)

    case validate_root_components(expanded, true) do
      :ok ->
        expanded

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create Git root", path: expanded
    end
  end

  defp validate_root_components(root, create?) do
    case Path.split(root) do
      [filesystem_root] ->
        if Path.dirname(filesystem_root) == filesystem_root,
          do: {:error, :unsafe_git_root},
          else: {:error, :badarg}

      [filesystem_root | parts] ->
        Enum.reduce_while(parts, {:ok, filesystem_root}, fn part, {:ok, parent} ->
          current = Path.join(parent, part)

          result =
            case File.lstat(current) do
              {:ok, %{type: :directory}} ->
                :ok

              {:ok, _} ->
                {:error, :unsafe_git_root}

              {:error, :enoent} when create? ->
                with :ok <- File.mkdir(current),
                     {:ok, %{type: :directory}} <- File.lstat(current) do
                  :ok
                else
                  {:error, reason} -> {:error, reason}
                  _ -> {:error, :unsafe_git_root}
                end

              {:error, reason} ->
                {:error, reason}
            end

          case result do
            :ok -> {:cont, {:ok, current}}
            {:error, _} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, _} -> :ok
          error -> error
        end

      _ ->
        {:error, :badarg}
    end
  end
end
