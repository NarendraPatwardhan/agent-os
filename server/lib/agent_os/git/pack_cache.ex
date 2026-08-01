defmodule AgentOS.Git.PackCache do
  @moduledoc """
  Content-addressed pack cache for BEAM remotes (GIT.md PR13 / K29 / R40 / D12).

  Packs are keyed by `sha256:` hex digest of pack bytes. An optional
  **download-key index** maps `url + wants + haves + depth` → pack digest so
  repeated clone/fetch of the same public locator skips transport.

  **Credentials are never part of any key.** Callers must pass a public URL
  (no userinfo). Auth lives only in SmartHttp request headers at dial time.

  Backends:
  * **Memory** — Agent process holding two maps (`packs` and `keys`).
  * **Disk** — files under a directory (same layout as JS `DiskPackCache`):
    `{dir}/{sha256hex}.pack` and optional `{dir}/keys/{sha256hex}.key`
    (filename = SHA-256 hex of the full download-key string).
    Enable with `start_disk/1`, `pack_cache: :disk` / `{:disk, dir}`, or env
    `AGENTOS_GIT_PACK_CACHE` (mirrors JS `MC_GIT_PACK_CACHE`).

  **Product default (multi-tenant safer):** `product_default_cache/0` returns a
  **fresh per-caller Memory** Agent unless shared opt-in is set. Process-global
  / shared cache is **opt-in only**:
  * `AGENTOS_GIT_PACK_CACHE_SHARED=1` (mirrors JS `MC_GIT_PACK_CACHE_SHARED`) →
    `default_process_cache/0` (Memory, or Disk when `AGENTOS_GIT_PACK_CACHE` set)
  * `AGENTOS_GIT_PACK_CACHE=<dir>` + SHARED → single-tenant process Disk cache
    (also treated as shared opt-in for product default)

  Multi-tenant hosts must **not** set SHARED or a shared disk dir across tenants.
  """

  use Agent

  @type digest :: String.t()
  @type download_key :: String.t()
  @type t :: pid()

  @env_disk_dir "AGENTOS_GIT_PACK_CACHE"
  @env_shared "AGENTOS_GIT_PACK_CACHE_SHARED"
  # Process dictionary key for ephemeral (non-shared) Memory cache on the caller.
  @ephemeral_pdict_key :agent_os_git_pack_cache_ephemeral

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @doc "Start an empty in-memory pack cache Agent."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []

    case Keyword.get(opts, :dir) do
      dir when is_binary(dir) and dir != "" ->
        start_disk_agent(dir, start_opts)

      _ ->
        Agent.start_link(
          fn -> %{backend: :memory, packs: %{}, keys: %{}} end,
          start_opts
        )
    end
  end

  @doc """
  Start (or return existing process-scoped) disk pack cache for `dir`.

  Creates `dir` if missing. Same on-disk layout as JS `DiskPackCache`.
  """
  @spec start_disk(Path.t(), keyword()) :: Agent.on_start() | {:ok, t()}
  def start_disk(dir, opts \\ []) when is_binary(dir) and dir != "" do
    abs = Path.expand(dir)
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []

    case name && Process.whereis(name) do
      pid when is_pid(pid) ->
        {:ok, pid}

      _ ->
        start_disk_agent(abs, start_opts)
    end
  end

  defp start_disk_agent(dir, start_opts) do
    File.mkdir_p!(dir)

    Agent.start_link(
      fn -> %{backend: :disk, dir: dir} end,
      start_opts
    )
  end

  @doc "Stop a cache Agent."
  @spec stop(t()) :: :ok
  def stop(cache) when is_pid(cache), do: Agent.stop(cache)

  # Process-scoped shared caches (opt-in; mirrors JS `defaultProcessPackCache`).
  @process_name __MODULE__.ProcessDefault
  @disk_process_name __MODULE__.DiskDefault

  @doc """
  Shared process-scoped `PackCache` singleton (opt-in).

  Content-addressed packs only — never credentials.
  When `AGENTOS_GIT_PACK_CACHE` is set to a non-empty directory path, returns
  the process-scoped **disk** cache for that dir (parity with JS
  `MC_GIT_PACK_CACHE`); otherwise the in-memory process singleton.

  **Not** the multi-tenant product default — use `product_default_cache/0`
  (or orchestrator `pack_cache: :default`). Call this explicitly, or set
  `AGENTOS_GIT_PACK_CACHE_SHARED=1` so `product_default_cache/0`
  delegates here.
  """
  @spec default_process_cache() :: t()
  def default_process_cache do
    case disk_dir_from_env() do
      dir when is_binary(dir) -> env_disk_cache!(dir)
      nil -> memory_process_cache()
    end
  end

  @doc """
  Whether product paths may share a process-scoped pack cache.

  Opt-in via `AGENTOS_GIT_PACK_CACHE_SHARED=1` or `true` (mirrors JS
  `MC_GIT_PACK_CACHE_SHARED`). Multi-tenant safer default is off.
  """
  @spec shared_from_env?() :: boolean()
  def shared_from_env? do
    case System.get_env(@env_shared) do
      v when is_binary(v) ->
        t = String.trim(v)
        t == "1" or String.downcase(t) == "true"

      _ ->
        false
    end
  end

  @doc """
  Product pack-cache default (parity with JS `productDefaultPackCache`):

  * When `AGENTOS_GIT_PACK_CACHE_SHARED=1` (or `true`) → `default_process_cache/0`
    (process Memory, or Disk when `AGENTOS_GIT_PACK_CACHE` is set). **JS parity:**
    product path never treats disk env alone as shared.
  * Otherwise → **fresh** Memory Agent scoped to the calling process
    (process dictionary + linked Agent; dies with the caller Task/process).
    No cross-VM / multi-tenant pack-byte sharing.

  Credentials are never cached. Multi-tenant must not set SHARED or a shared
  disk dir across tenants. Single-tenant disk: set SHARED + `AGENTOS_GIT_PACK_CACHE`.
  """
  @spec product_default_cache() :: t()
  def product_default_cache do
    # Shared only when SHARED is set (match JS productDefaultPackCache).
    if shared_from_env?() do
      default_process_cache()
    else
      ephemeral_memory_cache()
    end
  end

  @doc """
  Disk pack cache Agent for `dir`, or for `AGENTOS_GIT_PACK_CACHE` when
  `dir` is omitted / `:env`.

  Explicit dirs start an unnamed Agent (safe for concurrent tests). The env
  product path uses a process-scoped named singleton.
  """
  @spec disk_cache(Path.t() | :env | nil) :: t() | no_return()
  def disk_cache(dir \\ :env)

  def disk_cache(:env) do
    case disk_dir_from_env() do
      dir when is_binary(dir) -> env_disk_cache!(dir)
      nil -> raise_missing_disk_env()
    end
  end

  def disk_cache(nil), do: disk_cache(:env)

  def disk_cache(dir) when is_binary(dir) and dir != "" do
    abs = Path.expand(dir)

    case start_disk(abs) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  @doc "Directory path from `AGENTOS_GIT_PACK_CACHE`, or `nil`."
  @spec disk_dir_from_env() :: String.t() | nil
  def disk_dir_from_env do
    case System.get_env(@env_disk_dir) do
      dir when is_binary(dir) ->
        trimmed = String.trim(dir)
        if trimmed != "", do: trimmed, else: nil

      _ ->
        nil
    end
  end

  # Fresh Memory for one caller process (Task / remote host_call). Linked to
  # caller so it dies with the remote Task; reused via process dictionary so
  # multiple resolve_pack steps in one op share the same Agent.
  defp ephemeral_memory_cache do
    case Process.get(@ephemeral_pdict_key) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          pid
        else
          start_ephemeral_memory_cache()
        end

      _ ->
        start_ephemeral_memory_cache()
    end
  end

  defp start_ephemeral_memory_cache do
    case start_link() do
      {:ok, pid} ->
        Process.put(@ephemeral_pdict_key, pid)
        pid

      {:error, {:already_started, pid}} ->
        Process.put(@ephemeral_pdict_key, pid)
        pid
    end
  end

  defp memory_process_cache do
    case Process.whereis(@process_name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        case start_link(name: @process_name) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp env_disk_cache!(dir) when is_binary(dir) do
    abs = Path.expand(dir)

    case Process.whereis(@disk_process_name) do
      pid when is_pid(pid) ->
        case Agent.get(pid, fn st -> Map.get(st, :dir) end) do
          ^abs ->
            pid

          _other ->
            # Env dir changed in-process — fall back to unnamed Agent for abs.
            case start_disk(abs) do
              {:ok, p} -> p
              {:error, {:already_started, p}} -> p
            end
        end

      nil ->
        case start_disk(abs, name: @disk_process_name) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  defp raise_missing_disk_env do
    raise ArgumentError,
          "pack_cache: :disk requires #{@env_disk_dir} or pack_cache: {:disk, dir}"
  end

  # ── Pack store ─────────────────────────────────────────────────────────────

  @doc "Return a copy of pack bytes for `digest`, or `nil`."
  @spec get(t(), digest()) :: binary() | nil
  def get(cache, digest) when is_pid(cache) and is_binary(digest) do
    Agent.get(cache, fn
      %{backend: :memory, packs: packs} ->
        case Map.get(packs, digest) do
          bin when is_binary(bin) -> bin
          _ -> nil
        end

      %{backend: :disk, dir: dir} ->
        disk_get_pack(dir, digest)
    end)
  end

  @doc "Store pack bytes; returns content-addressed `sha256:…` digest."
  @spec put(t(), binary()) :: digest()
  def put(cache, pack) when is_pid(cache) and is_binary(pack) do
    digest = digest_of(pack)

    Agent.update(cache, fn
      %{backend: :memory, packs: packs} = st ->
        packs =
          if Map.has_key?(packs, digest) do
            packs
          else
            Map.put(packs, digest, pack)
          end

        %{st | packs: packs}

      %{backend: :disk, dir: dir} = st ->
        disk_put_pack(dir, digest, pack)
        st
    end)

    digest
  end

  @doc "Whether the digest is present."
  @spec has?(t(), digest()) :: boolean()
  def has?(cache, digest) when is_pid(cache) and is_binary(digest) do
    Agent.get(cache, fn
      %{backend: :memory, packs: packs} ->
        Map.has_key?(packs, digest)

      %{backend: :disk, dir: dir} ->
        File.regular?(pack_path(dir, digest))
    end)
  end

  @doc "Drop all packs and download-key index entries (memory or disk dir)."
  @spec clear(t()) :: :ok
  def clear(cache) when is_pid(cache) do
    Agent.update(cache, fn
      %{backend: :memory} ->
        %{backend: :memory, packs: %{}, keys: %{}}

      %{backend: :disk, dir: dir} = st ->
        # Remove pack files and keys/ under dir; keep dir itself.
        for path <- Path.wildcard(Path.join(dir, "*.pack")) do
          File.rm(path)
        end

        File.rm_rf(Path.join(dir, "keys"))
        st
    end)

    :ok
  end

  # ── Download-key index (url+want+have+depth → digest) ───────────────────────

  @doc "Lookup pack digest for a download key, or `nil`."
  @spec get_by_key(t(), download_key()) :: digest() | nil
  def get_by_key(cache, key) when is_pid(cache) and is_binary(key) do
    Agent.get(cache, fn
      %{backend: :memory, keys: keys} ->
        Map.get(keys, key)

      %{backend: :disk, dir: dir} ->
        disk_get_key(dir, key)
    end)
  end

  @doc "Index download key → pack digest."
  @spec put_key(t(), download_key(), digest()) :: :ok
  def put_key(cache, key, digest)
      when is_pid(cache) and is_binary(key) and is_binary(digest) do
    Agent.update(cache, fn
      %{backend: :memory, keys: keys} = st ->
        %{st | keys: Map.put(keys, key, digest)}

      %{backend: :disk, dir: dir} = st ->
        disk_put_key(dir, key, digest)
        st
    end)

    :ok
  end

  @doc """
  Stable download-key for upload-pack cache (`url` + wants + haves + depth + filter).

  **Never** include credentials, Authorization headers, or userinfo. Auth is
  only applied at transport time (SmartHttp headers). Optional `filter` (R36
  partial clone) is part of the key so filtered packs never collide with full.
  """
  @spec upload_pack_cache_key(
          String.t(),
          [String.t()],
          [String.t()],
          non_neg_integer() | nil,
          String.t() | nil
        ) :: download_key()
  def upload_pack_cache_key(url, wants, haves \\ [], depth \\ nil, filter \\ nil)
      when is_binary(url) and is_list(wants) and is_list(haves) do
    wants_s =
      wants
      |> Enum.map(&String.downcase(to_string(&1)))
      |> Enum.filter(&(&1 != ""))
      |> Enum.sort()
      |> Enum.join(",")

    haves_s =
      haves
      |> Enum.map(&String.downcase(to_string(&1)))
      |> Enum.filter(&(&1 != ""))
      |> Enum.sort()
      |> Enum.join(",")

    depth_s =
      case depth do
        d when is_integer(d) and d > 0 -> Integer.to_string(d)
        _ -> ""
      end

    filter_s =
      case filter do
        f when is_binary(f) -> String.trim(f)
        _ -> ""
      end

    "upload-pack:v1:#{url}:#{wants_s}:#{haves_s}:d#{depth_s}:f#{filter_s}"
  end

  @doc "SHA-256 digest of pack bytes as `sha256:` + lowercase hex."
  @spec digest_of(binary()) :: digest()
  def digest_of(pack) when is_binary(pack) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, pack), case: :lower)
  end

  # ── Disk helpers (layout matches JS DiskPackCache) ─────────────────────────

  defp pack_path(dir, digest) do
    id = String.replace_prefix(digest, "sha256:", "")
    Path.join(dir, id <> ".pack")
  end

  defp key_path(dir, key) do
    # Layout parity with JS DiskPackCache: keys/{sha256hex(download-key)}.key
    Path.join([dir, "keys", download_key_filename(key) <> ".key"])
  end

  defp disk_get_pack(dir, digest) do
    path = pack_path(dir, digest)

    case File.read(path) do
      {:ok, bin} -> bin
      {:error, _} -> nil
    end
  end

  defp disk_put_pack(dir, digest, pack) do
    File.mkdir_p!(dir)
    path = pack_path(dir, digest)

    # Idempotent: skip rewrite if present (content-addressed).
    unless File.regular?(path) do
      tmp =
        Path.join(
          dir,
          ".tmp-" <> Integer.to_string(System.unique_integer([:positive])) <> ".pack"
        )

      File.write!(tmp, pack)
      # Atomic-ish replace; if target appears, keep existing.
      case File.rename(tmp, path) do
        :ok ->
          :ok

        {:error, _} ->
          _ = File.rm(tmp)
          :ok
      end
    end

    :ok
  end

  defp disk_get_key(dir, key) do
    path = key_path(dir, key)

    case File.read(path) do
      {:ok, body} ->
        dig = String.trim(body)
        if dig != "", do: dig, else: nil

      {:error, _} ->
        nil
    end
  end

  defp disk_put_key(dir, key, digest) do
    keys_dir = Path.join(dir, "keys")
    File.mkdir_p!(keys_dir)
    File.write!(key_path(dir, key), digest)
    :ok
  end

  # SHA-256 hex of the full download-key string (parity with JS DiskPackCache).
  # Old FNV-1a 32-bit filenames are not migrated; they simply miss.
  defp download_key_filename(key) when is_binary(key) do
    Base.encode16(:crypto.hash(:sha256, key), case: :lower)
  end
end
