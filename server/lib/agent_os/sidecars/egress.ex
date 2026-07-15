defmodule AgentOS.Sidecars.Egress do
  @moduledoc "Claims the reserved guest host binding and owns cancellable provider tasks."

  use GenServer

  require Logger

  alias AgentOS.Contracts.Sidecar
  alias AgentOS.ControlPlane

  @binding Sidecar.sidecar_host_binding()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def dispatch(vm_id, event), do: GenServer.call(__MODULE__, {:dispatch, vm_id, event})
  def cancel_vm(vm_id), do: GenServer.call(__MODULE__, {:cancel_vm, vm_id})

  @impl true
  def init(_opts),
    do: {:ok, %{tasks: %{}, refs: %{}, counts: %{}}}

  @impl true
  def handle_call(
        {:dispatch, vm_id,
         %{
           kind: :host_call,
           name: @binding,
           handle: handle,
           body: body
         }},
        _from,
        state
      ) do
    key = {vm_id, handle}

    cond do
      Map.has_key?(state.tasks, key) ->
        {:reply, :claimed, state}

      Map.get(state.counts, vm_id, 0) >= Sidecar.sidecar_max_inflight_per_vm() ->
        _ = ControlPlane.egress_host_call_respond(vm_id, handle, encode_error(:sidecar_limit))
        {:reply, :claimed, state}

      true ->
        task =
          Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fn ->
            result = dispatch_request(vm_id, body)

            {vm_id, handle, result}
          end)

        next = %{
          state
          | tasks: Map.put(state.tasks, key, task),
            refs: Map.put(state.refs, task.ref, key),
            counts: increment(state.counts, vm_id)
        }

        {:reply, :claimed, next}
    end
  end

  def handle_call(
        {:dispatch, vm_id, %{kind: :host_call_close, name: @binding, handle: handle}},
        _from,
        state
      ) do
    key = {vm_id, handle}

    case Map.pop(state.tasks, key) do
      {nil, _tasks} ->
        {:reply, :claimed, state}

      {task, tasks} ->
        Process.demonitor(task.ref, [:flush])
        Task.shutdown(task, :brutal_kill)

        {:reply, :claimed,
         %{
           state
           | tasks: tasks,
             refs: Map.delete(state.refs, task.ref),
             counts: decrement(state.counts, vm_id)
         }}
    end
  end

  def handle_call({:dispatch, _vm_id, _event}, _from, state), do: {:reply, :unclaimed, state}

  def handle_call({:cancel_vm, vm_id}, _from, state) do
    {cancel, keep} =
      Enum.split_with(state.tasks, fn {{owner, _handle}, _task} -> owner == vm_id end)

    refs =
      Enum.reduce(cancel, state.refs, fn {_key, task}, acc ->
        Process.demonitor(task.ref, [:flush])
        Task.shutdown(task, :brutal_kill)
        Map.delete(acc, task.ref)
      end)

    {:reply, :ok,
     %{state | tasks: Map.new(keep), refs: refs, counts: Map.delete(state.counts, vm_id)}}
  end

  @impl true
  def handle_info({ref, {vm_id, handle, result}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    _ = ControlPlane.egress_host_call_respond(vm_id, handle, result)
    next = drop_ref(state, ref)
    {:noreply, next}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case state.refs[ref] do
      nil ->
        {:noreply, state}

      {vm_id, handle} ->
        _ =
          ControlPlane.egress_host_call_respond(
            vm_id,
            handle,
            encode_error({:provider_exit, reason})
          )

        next = drop_ref(state, ref)
        {:noreply, next}
    end
  end

  defp drop_ref(state, ref) do
    case Map.pop(state.refs, ref) do
      {nil, _refs} ->
        state

      {{vm_id, _handle} = key, refs} ->
        %{
          state
          | refs: refs,
            tasks: Map.delete(state.tasks, key),
            counts: decrement(state.counts, vm_id)
        }
    end
  end

  defp increment(counts, vm_id), do: Map.update(counts, vm_id, 1, &(&1 + 1))

  defp decrement(counts, vm_id) do
    case Map.get(counts, vm_id, 0) do
      count when count > 1 -> Map.put(counts, vm_id, count - 1)
      _zero_or_one -> Map.delete(counts, vm_id)
    end
  end

  defp dispatch_request(vm_id, <<message_id::unsigned-little-16, _rest::binary>> = body) do
    cond do
      message_id == Sidecar.sidecar_create_msg_id() ->
        with {:ok, request} <- Sidecar.decode_sidecar_create(body),
             {:ok, instance} <- AgentOS.Sidecars.create(vm_id, request, guest: true) do
          encode_ok(Sidecar.encode_sidecar_instance(to_contract_instance(instance)))
        else
          {:error, reason} -> encode_error(reason)
        end

      message_id == Sidecar.sidecar_call_msg_id() ->
        with {:ok, request} <- Sidecar.decode_sidecar_call(body),
             {:ok, response} <- AgentOS.Sidecars.invoke(vm_id, request, guest: true) do
          encode_ok(response)
        else
          {:error, reason} -> encode_error(reason)
        end

      message_id == Sidecar.sidecar_get_msg_id() ->
        with {:ok, request} <- Sidecar.decode_sidecar_get(body),
             {:ok, instance} <- AgentOS.Sidecars.retrieve_checked(vm_id, request, guest: true) do
          encode_ok(Sidecar.encode_sidecar_instance(to_contract_instance(instance)))
        else
          {:error, reason} -> encode_error(reason)
        end

      message_id == Sidecar.sidecar_list_msg_id() ->
        with {:ok, request} <- Sidecar.decode_sidecar_list(body),
             instances when is_list(instances) <-
               AgentOS.Sidecars.list_checked(vm_id, request, guest: true) do
          encode_ok(
            Sidecar.encode_sidecar_instances(%{
              items: Enum.map(instances, &to_contract_instance/1)
            })
          )
        else
          {:error, reason} -> encode_error(reason)
        end

      message_id == Sidecar.sidecar_delete_msg_id() ->
        with {:ok, request} <- Sidecar.decode_sidecar_delete(body),
             :ok <- AgentOS.Sidecars.delete_checked(vm_id, request, guest: true) do
          encode_ok(<<>>)
        else
          {:error, reason} -> encode_error(reason)
        end

      true ->
        encode_error(:sidecar_invalid_request)
    end
  end

  defp dispatch_request(_vm_id, _body), do: encode_error(:sidecar_invalid_request)

  defp encode_ok(body),
    do: Sidecar.encode_sidecar_result(%{ok: true, body: body, error: nil})

  defp to_contract_instance(instance) do
    %{
      id: instance.id,
      grant: instance.grant,
      kind: instance.kind,
      generation: instance.generation,
      state: state_number(instance.state),
      created_at_ms: instance.created_at_ms,
      expires_at_ms: instance.expires_at_ms,
      metadata: instance.metadata
    }
  end

  defp state_number(:allocating), do: Sidecar.sidecar_state_allocating()
  defp state_number(:starting), do: Sidecar.sidecar_state_starting()
  defp state_number(:ready), do: Sidecar.sidecar_state_ready()
  defp state_number(:suspended), do: Sidecar.sidecar_state_suspended()
  defp state_number(:failed), do: Sidecar.sidecar_state_failed()
  defp state_number(:closing), do: Sidecar.sidecar_state_closing()
  defp state_number(:closed), do: Sidecar.sidecar_state_closed()
  defp state_number(:detached), do: Sidecar.sidecar_state_detached()

  defp encode_error(reason) do
    {code, message, retryable} = stable_error(reason)

    Sidecar.encode_sidecar_result(%{
      ok: false,
      body: <<>>,
      error: %{code: code, message: message, retryable: retryable, details: nil}
    })
  end

  @stable_errors %{
    sidecar_closing: {:sidecar_error_closing, false},
    sidecar_contract_mismatch: {:sidecar_error_contract_mismatch, false},
    sidecar_detached: {:sidecar_error_detached, false},
    sidecar_grant_exists: {:sidecar_error_grant_exists, false},
    sidecar_grant_missing: {:sidecar_error_grant_missing, false},
    sidecar_idempotency_conflict: {:sidecar_error_idempotency_conflict, false},
    sidecar_in_use: {:sidecar_error_in_use, false},
    sidecar_invalid_request: {:sidecar_error_invalid_request, false},
    sidecar_limit: {:sidecar_error_limit, false},
    sidecar_not_found: {:sidecar_error_not_found, false},
    sidecar_not_ready: {:sidecar_error_not_ready, false},
    sidecar_permission_denied: {:sidecar_error_permission_denied, false},
    sidecar_provider_failed: {:sidecar_error_provider_failed, true},
    sidecar_scope_missing: {:sidecar_error_scope_missing, false},
    sidecar_stale_generation: {:sidecar_error_stale_generation, false},
    sidecar_unavailable: {:sidecar_error_unavailable, true},
    sidecar_unsupported_fork_policy: {:sidecar_error_unsupported_fork_policy, false},
    cancelled: {:sidecar_error_cancelled, false},
    timeout: {:sidecar_error_timeout, true}
  }

  defp stable_error(reason) when is_map_key(@stable_errors, reason) do
    {contract_function, retryable} = Map.fetch!(@stable_errors, reason)
    {apply(Sidecar, contract_function, []), humanize(reason), retryable}
  end

  defp stable_error(reason) do
    Logger.warning("sidecar operation failed",
      reason: inspect(reason, limit: 20, printable_limit: 256)
    )

    {Sidecar.sidecar_error_provider_failed(), "sidecar provider failed", false}
  end

  defp humanize(reason), do: reason |> Atom.to_string() |> String.replace("_", " ")
end
