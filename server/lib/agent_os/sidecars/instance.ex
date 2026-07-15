defmodule AgentOS.Sidecars.Instance do
  @moduledoc "Single owner for one logical sidecar binding and its private provider reference."

  # A provider reference is process-private and cannot be reconstructed after an abnormal exit.
  # Reconciliation owns any leaked external allocation; restarting here would create a second
  # resource under the same logical identity.
  use GenServer, restart: :temporary

  alias AgentOS.Contracts.Sidecar
  alias AgentOS.Sidecars.Journal

  @cleanup_timeout 30_000
  @inspect_timeout 2_000
  @states [:allocating, :starting, :ready, :suspended, :failed, :closing, :closed, :detached]

  def start_link(opts) do
    vm_id = Keyword.fetch!(opts, :vm_id)
    id = Keyword.fetch!(opts, :id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {AgentOS.SidecarRegistry, {:instance, vm_id, id}}}
    )
  end

  def info(server), do: GenServer.call(server, :info)

  def invoke(server, request, timeout \\ 65_000),
    do: GenServer.call(server, {:invoke, request}, timeout)

  def begin_fork(server), do: GenServer.call(server, :begin_fork)
  def end_fork(server), do: GenServer.call(server, :end_fork)
  def renew(server, expires_at_ms), do: GenServer.call(server, {:renew, expires_at_ms})
  def close(server), do: GenServer.call(server, :close, 65_000)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    provider = Keyword.fetch!(opts, :provider)
    provider_opts = Keyword.fetch!(opts, :provider_opts)
    context = Keyword.fetch!(opts, :context)
    request = Keyword.fetch!(opts, :request)
    id = Keyword.fetch!(opts, :id)
    generation = Keyword.get(opts, :generation, 1)
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, Sidecar.sidecar_default_lease_ttl_ms())
    owner_ref = Process.monitor(owner)

    context = Map.put(context, :id, id)

    with {:ok, journal_id} <-
           Journal.append(%{op: :create, vm_id: context.vm_id, id: id, kind: context.kind}) do
      case provider_create(provider, context, request, provider_opts) do
        {:ok, provider_ref, metadata} ->
          result =
            cond do
              not is_binary(metadata) -> {:error, :invalid_provider_result}
              byte_size(metadata) > Sidecar.sidecar_max_result_bytes() -> {:error, :sidecar_limit}
              true -> Journal.complete(journal_id, %{})
            end

          case result do
            :ok ->
              now = System.system_time(:millisecond)
              expires_at_ms = now + lease_ttl_ms
              lease_timer = schedule_expiry(expires_at_ms)

              {:ok,
               %{
                 id: id,
                 generation: generation,
                 context: context,
                 provider: provider,
                 provider_opts: provider_opts,
                 provider_ref: provider_ref,
                 metadata: metadata,
                 state: :ready,
                 created_at_ms: now,
                 expires_at_ms: expires_at_ms,
                 lease_timer: lease_timer,
                 accepting: true,
                 calls: %{},
                 owner_ref: owner_ref,
                 fork_waiters: [],
                 deleted: false,
                 delete_attempted: false
               }}

            {:error, reason} ->
              rollback_create(provider, context, provider_ref, provider_opts, journal_id)
              {:stop, reason}
          end

        {:error, reason} ->
          {:stop, reason}

        _other ->
          {:stop, :invalid_provider_result}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, public_info(state), state}

  def handle_call({:invoke, request}, from, state) do
    with :ok <- admit(state, request),
         timeout <- bounded_timeout(request),
         operation_ref <- make_ref(),
         task <-
           Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fn ->
             state.provider.invoke(
               state.context,
               state.provider_ref,
               request.operation,
               request.body,
               Keyword.merge(state.provider_opts, call_ref: operation_ref, timeout: timeout)
             )
           end) do
      caller_ref = Process.monitor(elem(from, 0))
      timer = Process.send_after(self(), {:call_timeout, task.ref}, timeout)

      call = %{
        from: from,
        task: task,
        caller_ref: caller_ref,
        timer: timer,
        operation_ref: operation_ref
      }

      {:noreply, %{state | calls: Map.put(state.calls, task.ref, call)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:begin_fork, from, state) do
    next = %{state | accepting: false}

    if map_size(state.calls) == 0 do
      {:reply, :ok, next}
    else
      {:noreply, %{next | fork_waiters: [from | state.fork_waiters]}}
    end
  end

  def handle_call(:end_fork, _from, state) do
    next = if state.state == :ready, do: %{state | accepting: true}, else: state
    {:reply, :ok, next}
  end

  def handle_call({:renew, expires_at_ms}, _from, state)
      when is_integer(expires_at_ms) and expires_at_ms > 0 do
    case provider_inspect(state) do
      {:ok, %{state: provider_state}} when provider_state in @states ->
        case provider_renew(state, expires_at_ms) do
          :ok ->
            Process.cancel_timer(state.lease_timer)

            {:reply, :ok,
             %{
               state
               | state: provider_state,
                 expires_at_ms: expires_at_ms,
                 lease_timer: schedule_expiry(expires_at_ms)
             }}

          {:error, _reason} = error ->
            {:reply, error, %{state | state: :failed}}
        end

      _unavailable ->
        {:reply, {:error, :sidecar_unavailable}, %{state | state: :failed}}
    end
  end

  def handle_call({:renew, _expires_at_ms}, _from, state),
    do: {:reply, {:error, :sidecar_invalid_request}, state}

  def handle_call(:close, _from, state) do
    next = cancel_all(%{state | accepting: false, state: :closing})
    {reply, next} = delete_provider(next)
    {:stop, :normal, reply, next}
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.calls, ref) do
      {nil, _calls} ->
        {:noreply, state}

      {call, calls} ->
        Process.demonitor(ref, [:flush])
        Process.demonitor(call.caller_ref, [:flush])
        Process.cancel_timer(call.timer)
        GenServer.reply(call.from, normalize_result(result))
        {:noreply, release_waiters(%{state | calls: calls})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      ref == state.owner_ref ->
        next = cancel_all(%{state | accepting: false, state: :closing})
        {_reply, next} = delete_provider(next)
        {:stop, :normal, next}

      call = find_call_by_caller(state.calls, ref) ->
        {:noreply, cancel_call(state, call.task.ref, :caller_closed)}

      Map.has_key?(state.calls, ref) ->
        call = Map.fetch!(state.calls, ref)
        Process.demonitor(call.caller_ref, [:flush])
        Process.cancel_timer(call.timer)
        GenServer.reply(call.from, {:error, {:provider_exit, reason}})
        {:noreply, release_waiters(%{state | calls: Map.delete(state.calls, ref)})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:call_timeout, ref}, state), do: {:noreply, cancel_call(state, ref, :timeout)}

  def handle_info({:lease_expired, expires_at_ms}, %{expires_at_ms: expires_at_ms} = state) do
    if System.system_time(:millisecond) >= expires_at_ms do
      next = cancel_all(%{state | accepting: false, state: :closing})
      {_reply, next} = delete_provider(next)
      {:stop, :normal, next}
    else
      {:noreply, %{state | lease_timer: schedule_expiry(state.expires_at_ms)}}
    end
  end

  def handle_info({:lease_expired, _stale}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{deleted: false} = state) do
    _ = delete_provider(cancel_all(state))
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp admit(%{accepting: false}, _request), do: {:error, :sidecar_closing}
  defp admit(%{state: state}, _request) when state != :ready, do: {:error, :sidecar_not_ready}

  defp admit(state, request) do
    cond do
      request.generation != state.generation ->
        {:error, :sidecar_stale_generation}

      request.grant != state.context.grant or request.kind != state.context.kind ->
        {:error, :sidecar_invalid_request}

      byte_size(request.body) > Sidecar.sidecar_max_request_bytes() ->
        {:error, :sidecar_limit}

      map_size(state.calls) >= Sidecar.sidecar_max_inflight_per_instance() ->
        {:error, :sidecar_limit}

      true ->
        :ok
    end
  end

  defp bounded_timeout(request) do
    request
    |> Map.get(:timeout_ms, Sidecar.sidecar_default_operation_timeout_ms())
    |> max(1)
    |> min(Sidecar.sidecar_max_operation_timeout_ms())
  end

  defp normalize_result({:ok, body}) when is_binary(body) do
    if byte_size(body) <= Sidecar.sidecar_max_result_bytes(),
      do: {:ok, body},
      else: {:error, :sidecar_limit}
  end

  defp normalize_result({:ok, _body}), do: {:error, :invalid_provider_result}
  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result(other), do: {:error, {:invalid_provider_result, other}}

  defp cancel_call(state, ref, reason) do
    case Map.pop(state.calls, ref) do
      {nil, _calls} ->
        state

      {call, calls} ->
        Process.demonitor(call.caller_ref, [:flush])
        Process.cancel_timer(call.timer)
        cancel_provider(state, call.operation_ref)
        Task.shutdown(call.task, :brutal_kill)
        GenServer.reply(call.from, {:error, reason})
        release_waiters(%{state | calls: calls})
    end
  end

  defp cancel_all(state),
    do: Enum.reduce(Map.keys(state.calls), state, &cancel_call(&2, &1, :sidecar_closing))

  defp cancel_provider(state, ref) do
    if function_exported?(state.provider, :cancel, 4) do
      _ =
        Task.Supervisor.start_child(AgentOS.SidecarTaskSupervisor, fn ->
          provider_call(@inspect_timeout, fn ->
            state.provider.cancel(state.context, state.provider_ref, ref, state.provider_opts)
          end)
        end)
    end
  end

  defp find_call_by_caller(calls, caller_ref),
    do: calls |> Map.values() |> Enum.find(&(&1.caller_ref == caller_ref))

  defp release_waiters(%{calls: calls, fork_waiters: waiters} = state)
       when map_size(calls) == 0 and waiters != [] do
    Enum.each(waiters, &GenServer.reply(&1, :ok))
    %{state | fork_waiters: []}
  end

  defp release_waiters(state), do: state

  defp delete_provider(%{deleted: true} = state), do: {:ok, state}
  defp delete_provider(%{delete_attempted: true} = state),
    do: {{:error, :sidecar_delete_pending}, state}

  defp delete_provider(state) do
    state = %{state | delete_attempted: true}

    with {:ok, journal_id} <-
           Journal.append(%{
             op: :delete,
             vm_id: state.context.vm_id,
             id: state.id,
             kind: state.context.kind
           }),
         :ok <- provider_delete(state),
         :ok <- Journal.complete(journal_id, %{}) do
      {:ok, %{state | deleted: true, state: :closed}}
    else
      {:error, reason} -> {{:error, reason}, %{state | state: :failed}}
    end
  end


  defp provider_create(provider, context, request, provider_opts) do
    provider_call(request.timeout_ms, fn -> provider.create(context, request, provider_opts) end)
  end

  defp provider_delete(state) do
    provider_delete(state.provider, state.context, state.provider_ref, state.provider_opts)
  end

  defp provider_delete(provider, context, provider_ref, provider_opts) do
    provider_call(@cleanup_timeout, fn ->
      provider.delete(context, provider_ref, provider_opts)
    end)
  end

  defp rollback_create(provider, context, provider_ref, provider_opts, journal_id) do
    if provider_delete(provider, context, provider_ref, provider_opts) == :ok do
      _ = Journal.complete(journal_id, %{rolled_back: true})
    end

    :ok
  end

  defp provider_inspect(state) do
    provider_call(@inspect_timeout, fn ->
      state.provider.inspect(state.context, state.provider_ref, state.provider_opts)
    end)
  end

  defp provider_renew(state, expires_at_ms) do
    provider_call(@inspect_timeout, fn ->
      state.provider.renew(
        state.context,
        state.provider_ref,
        expires_at_ms,
        state.provider_opts
      )
    end)
  end

  defp provider_call(timeout, fun) do
    task =
      Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fun)

    case Task.yield(task, timeout) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:provider_exit, reason}}
      nil ->
        _ = Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp public_info(state) do
    %{
      id: state.id,
      grant: state.context.grant,
      kind: state.context.kind,
      generation: state.generation,
      state: state.state,
      created_at_ms: state.created_at_ms,
      expires_at_ms: state.expires_at_ms,
      metadata: state.metadata
    }
  end

  defp schedule_expiry(expires_at_ms) do
    delay = max(expires_at_ms - System.system_time(:millisecond), 1)
    Process.send_after(self(), {:lease_expired, expires_at_ms}, delay)
  end
end
