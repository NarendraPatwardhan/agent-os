defmodule AgentOS.Git.Metrics do
  @moduledoc """
  In-process counters and last-op labels for git remotes / Port lifecycle (R85–R88 / D35–D36).

  Not Prometheus — simple ETS counters with `snapshot/0` and `reset/0` for tests
  and ops inspection. Never stores packs, tokens, or credential material.

  Counters:
  * `clone_ok` / `clone_error`
  * `fetch_ok` / `fetch_error` (includes pull)
  * `push_ok` / `push_error`
  * `port_eio` — Port died / EIO on Run
  * `rpc_error` — other engine RPC failures
  * `allowlist_deny` — origin policy rejections (also alerts)
  * `queue_depth_warn` — times mount remote queue exceeded 32

  Last-op labels (overwritten each remote op; never secrets):
  * `last_duration_ms`, `last_pack_bytes`, `last_origin_redacted`
  * running totals: `duration_ms_sum`, `pack_bytes_sum`
  * gauge: `queue_depth` (highest per-mount queue length observed since reset)
  """

  require Logger

  @table :agent_os_git_metrics

  # Queue depth that triggers a server alert (GIT.md observability).
  @queue_depth_alert 32

  @counter_keys [
    :clone_ok,
    :clone_error,
    :fetch_ok,
    :fetch_error,
    :push_ok,
    :push_error,
    :port_eio,
    :rpc_error,
    :allowlist_deny,
    :queue_depth_warn
  ]

  @label_keys [
    :last_duration_ms,
    :last_pack_bytes,
    :last_origin_redacted,
    :duration_ms_sum,
    :pack_bytes_sum,
    :queue_depth
  ]

  @keys @counter_keys ++ @label_keys

  @doc "Ensure the metrics table exists (idempotent)."
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        reset()
        :ok

      _tid ->
        :ok
    end
  rescue
    ArgumentError ->
      # Race: another process created the table.
      :ok
  end

  @doc "Increment a named counter by `n` (default 1)."
  @spec inc(atom(), pos_integer()) :: :ok
  def inc(key, n \\ 1) when is_atom(key) and is_integer(n) and n > 0 do
    ensure_table()

    if key in @counter_keys do
      :ets.update_counter(@table, key, {2, n}, {key, 0})
    end

    :ok
  end

  @doc "Current counter + label map (all known keys, defaults)."
  @spec snapshot() :: %{optional(atom()) => term()}
  def snapshot do
    ensure_table()

    Map.new(@keys, fn k ->
      case :ets.lookup(@table, k) do
        [{^k, v}] -> {k, v}
        _ -> {k, default_for(k)}
      end
    end)
  end

  @doc "Zero all counters and clear last-op labels."
  @spec reset() :: :ok
  def reset do
    ensure_table()

    Enum.each(@keys, fn k ->
      :ets.insert(@table, {k, default_for(k)})
    end)

    :ok
  end

  @doc "Known counter keys (ok/error only)."
  @spec keys() :: [atom()]
  def keys, do: @counter_keys

  @doc "Alert threshold for per-mount remote queue depth."
  @spec queue_depth_alert_threshold() :: pos_integer()
  def queue_depth_alert_threshold, do: @queue_depth_alert

  @doc """
  Record a remote op outcome with duration / pack size / redacted origin (D35).

  `meta` keys (all optional):
  * `:duration_ms` — wall time for the op
  * `:pack_bytes` — upload-pack payload size (0 when N/A)
  * `:origin_redacted` — scheme://host[:port] only (no path secrets, no userinfo)
  * `:allowlist_deny?` — true when origin policy rejected before dial
  """
  @spec record_remote_result(binary() | atom(), boolean(), map()) :: :ok
  def record_remote_result(op, ok?, meta \\ %{})
      when (is_binary(op) or is_atom(op)) and is_boolean(ok?) and is_map(meta) do
    ensure_table()
    op = op |> to_string() |> String.downcase()

    case {op, ok?} do
      {"clone", true} -> inc(:clone_ok)
      {"clone", false} -> inc(:clone_error)
      {"fetch", true} -> inc(:fetch_ok)
      {"fetch", false} -> inc(:fetch_error)
      {"pull", true} -> inc(:fetch_ok)
      {"pull", false} -> inc(:fetch_error)
      {"push", true} -> inc(:push_ok)
      {"push", false} -> inc(:push_error)
      _ -> :ok
    end

    duration = non_neg(Map.get(meta, :duration_ms) || Map.get(meta, "duration_ms") || 0)
    pack_bytes = non_neg(Map.get(meta, :pack_bytes) || Map.get(meta, "pack_bytes") || 0)

    origin =
      case Map.get(meta, :origin_redacted) || Map.get(meta, "origin_redacted") do
        o when is_binary(o) and o != "" -> o
        _ -> ""
      end

    put_label(:last_duration_ms, duration)
    put_label(:last_pack_bytes, pack_bytes)
    put_label(:last_origin_redacted, origin)
    add_label(:duration_ms_sum, duration)
    add_label(:pack_bytes_sum, pack_bytes)

    if Map.get(meta, :allowlist_deny?) == true or Map.get(meta, "allowlist_deny?") == true do
      alert_allowlist_deny(origin)
    end

    :ok
  end

  @doc """
  Log + count an origin allowlist denial (D36).

  `origin_redacted` must already be redacted (scheme://host only). Never pass
  tokens, Authorization, or full URLs with userinfo.
  """
  @spec alert_allowlist_deny(String.t()) :: :ok
  def alert_allowlist_deny(origin_redacted \\ "") when is_binary(origin_redacted) do
    inc(:allowlist_deny)
    origin = if origin_redacted == "", do: "(unknown)", else: origin_redacted

    Logger.warning("git: allowlist deny origin=#{origin}")
    :ok
  end

  @doc """
  Observe per-mount remote queue depth; alert when depth exceeds 32 (D36).

  Call after enqueue. Updates the `queue_depth` high-water mark.
  """
  @spec observe_queue_depth(String.t(), non_neg_integer()) :: :ok
  def observe_queue_depth(mount, depth)
      when is_binary(mount) and is_integer(depth) and depth >= 0 do
    ensure_table()
    prev = get_label(:queue_depth, 0)

    if depth > prev do
      put_label(:queue_depth, depth)
    end

    if depth > @queue_depth_alert do
      inc(:queue_depth_warn)

      Logger.warning(
        "git: mount queue depth #{depth} > #{@queue_depth_alert} mount=#{mount}"
      )
    end

    :ok
  end

  @doc false
  def redact_origin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h, port: p} when is_binary(h) and is_binary(s) ->
        default_port =
          case s do
            "https" -> 443
            "http" -> 80
            _ -> nil
          end

        if is_integer(p) and p != default_port do
          "#{s}://#{h}:#{p}"
        else
          "#{s}://#{h}"
        end

      _ ->
        "remote"
    end
  end

  def redact_origin(_), do: "remote"

  # ── private ────────────────────────────────────────────────────────────────

  defp default_for(:last_origin_redacted), do: ""
  defp default_for(_), do: 0

  defp put_label(key, value) when key in @label_keys do
    :ets.insert(@table, {key, value})
  end

  defp add_label(key, n) when key in @label_keys and is_integer(n) and n >= 0 do
    :ets.update_counter(@table, key, {2, n}, {key, 0})
  end

  defp get_label(key, default) do
    case :ets.lookup(@table, key) do
      [{^key, v}] -> v
      _ -> default
    end
  end

  defp non_neg(n) when is_integer(n) and n >= 0, do: n
  defp non_neg(n) when is_float(n) and n >= 0, do: trunc(n)
  defp non_neg(_), do: 0
end
