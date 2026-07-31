defmodule AgentOS.Git.PackCache do
  @moduledoc """
  Content-addressed pack cache for BEAM remotes (GIT.md PR13 / K29 / R40).

  Packs are keyed by `sha256:` hex digest of pack bytes. An optional
  **download-key index** maps `url + wants + haves + depth` → pack digest so
  repeated clone/fetch of the same public locator skips transport.

  **Credentials are never part of any key.** Callers must pass a public URL
  (no userinfo). Auth lives only in SmartHttp request headers at dial time.

  Implementation: Agent process holding two maps (`digests` and `keys`).
  Suitable as a process-scoped default or per-test cache.
  """

  use Agent

  @type digest :: String.t()
  @type download_key :: String.t()
  @type t :: pid()

  # ── Lifecycle ──────────────────────────────────────────────────────────────

  @doc "Start an empty in-memory pack cache Agent."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    start_opts = if name, do: [name: name], else: []

    Agent.start_link(
      fn -> %{packs: %{}, keys: %{}} end,
      start_opts
    )
  end

  @doc "Stop a cache Agent."
  @spec stop(t()) :: :ok
  def stop(cache) when is_pid(cache), do: Agent.stop(cache)

  # Process-scoped product default (mirrors JS `defaultProcessPackCache`).
  @process_name __MODULE__.ProcessDefault

  @doc """
  Shared process-scoped `PackCache` for repeated in-process remotes/solves.

  Content-addressed packs only — never credentials.
  """
  @spec default_process_cache() :: t()
  def default_process_cache do
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

  # ── Pack store ─────────────────────────────────────────────────────────────

  @doc "Return a copy of pack bytes for `digest`, or `nil`."
  @spec get(t(), digest()) :: binary() | nil
  def get(cache, digest) when is_pid(cache) and is_binary(digest) do
    Agent.get(cache, fn st ->
      case Map.get(st.packs, digest) do
        bin when is_binary(bin) -> bin
        _ -> nil
      end
    end)
  end

  @doc "Store pack bytes; returns content-addressed `sha256:…` digest."
  @spec put(t(), binary()) :: digest()
  def put(cache, pack) when is_pid(cache) and is_binary(pack) do
    digest = digest_of(pack)

    Agent.update(cache, fn st ->
      packs =
        if Map.has_key?(st.packs, digest) do
          st.packs
        else
          Map.put(st.packs, digest, pack)
        end

      %{st | packs: packs}
    end)

    digest
  end

  @doc "Whether the digest is present."
  @spec has?(t(), digest()) :: boolean()
  def has?(cache, digest) when is_pid(cache) and is_binary(digest) do
    Agent.get(cache, fn st -> Map.has_key?(st.packs, digest) end)
  end

  @doc "Drop all packs and download-key index entries."
  @spec clear(t()) :: :ok
  def clear(cache) when is_pid(cache) do
    Agent.update(cache, fn _ -> %{packs: %{}, keys: %{}} end)
  end

  # ── Download-key index (url+want+have+depth → digest) ───────────────────────

  @doc "Lookup pack digest for a download key, or `nil`."
  @spec get_by_key(t(), download_key()) :: digest() | nil
  def get_by_key(cache, key) when is_pid(cache) and is_binary(key) do
    Agent.get(cache, fn st -> Map.get(st.keys, key) end)
  end

  @doc "Index download key → pack digest."
  @spec put_key(t(), download_key(), digest()) :: :ok
  def put_key(cache, key, digest)
      when is_pid(cache) and is_binary(key) and is_binary(digest) do
    Agent.update(cache, fn st ->
      %{st | keys: Map.put(st.keys, key, digest)}
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
end
