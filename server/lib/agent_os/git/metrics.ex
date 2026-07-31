defmodule AgentOS.Git.Metrics do
  @moduledoc """
  In-process counters for git remotes / Port lifecycle (R85–R88).

  Not Prometheus — simple ETS counters with `snapshot/0` and `reset/0` for tests
  and ops inspection. Never stores packs, tokens, or credential material.

  Counters:
  * `clone_ok` / `clone_error`
  * `fetch_ok` / `fetch_error` (includes pull)
  * `push_ok` / `push_error`
  * `port_eio` — Port died / EIO on Run
  * `rpc_error` — other engine RPC failures
  """

  @table :agent_os_git_metrics

  @keys [
    :clone_ok,
    :clone_error,
    :fetch_ok,
    :fetch_error,
    :push_ok,
    :push_error,
    :port_eio,
    :rpc_error
  ]

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

    if key in @keys do
      :ets.update_counter(@table, key, {2, n}, {key, 0})
    end

    :ok
  end

  @doc "Current counter map (all known keys, default 0)."
  @spec snapshot() :: %{optional(atom()) => non_neg_integer()}
  def snapshot do
    ensure_table()

    Map.new(@keys, fn k ->
      case :ets.lookup(@table, k) do
        [{^k, v}] when is_integer(v) -> {k, v}
        _ -> {k, 0}
      end
    end)
  end

  @doc "Zero all counters."
  @spec reset() :: :ok
  def reset do
    ensure_table()

    Enum.each(@keys, fn k ->
      :ets.insert(@table, {k, 0})
    end)

    :ok
  end

  @doc "Known counter keys."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc false
  def record_remote_result(op, ok?) when is_binary(op) or is_atom(op) do
    op = op |> to_string() |> String.downcase()
    ok? = ok? == true

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
  end
end
