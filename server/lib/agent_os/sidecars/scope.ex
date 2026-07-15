defmodule AgentOS.Sidecars.Scope do
  @moduledoc "VM-scoped grants, logical identities, admission, and fork barrier."

  use GenServer, restart: :transient

  alias AgentOS.Contracts.Sidecar
  alias AgentOS.Sidecars.Instance

  @cleanup_timeout 35_000
  @placement_timeout 5_000

  def start_link(opts) do
    vm_id = Keyword.fetch!(opts, :vm_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {AgentOS.SidecarRegistry, {:scope, vm_id}}}
    )
  end

  def enable(server, name, grant), do: GenServer.call(server, {:enable, name, grant})

  def disable(server, name, destroy),
    do: GenServer.call(server, {:disable, name, destroy}, 65_000)

  def create(server, request, guest \\ false),
    do: GenServer.call(server, {:create, request, guest}, request.timeout_ms + 5_000)

  def retrieve(server, id), do: GenServer.call(server, {:retrieve, id})

  def retrieve_checked(server, request, guest),
    do: GenServer.call(server, {:retrieve_checked, request, guest})

  def list(server, kind), do: GenServer.call(server, {:list, kind})

  def list_checked(server, request, guest),
    do: GenServer.call(server, {:list_checked, request, guest})

  def grants(server), do: GenServer.call(server, :grants)
  def owner(server), do: GenServer.call(server, :owner)
  def checkout(server, request, guest), do: GenServer.call(server, {:checkout, request, guest})
  def checkin(server, ticket), do: GenServer.cast(server, {:checkin, ticket})
  def delete(server, id), do: GenServer.call(server, {:delete, id}, 65_000)

  def delete_checked(server, request, guest),
    do: GenServer.call(server, {:delete_checked, request, guest}, 65_000)

  def begin_fork(server),
    do: GenServer.call(server, :begin_fork, :infinity)
  def end_fork(server), do: GenServer.call(server, :end_fork)
  def close(server), do: GenServer.call(server, :close, 65_000)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    vm_id = Keyword.fetch!(opts, :vm_id)
    {default_placement, default_placement_opts} =
      AgentOS.Sidecars.ProviderRegistry.placement()

    placement = Keyword.get(opts, :placement, default_placement)
    placement_opts = Keyword.get(opts, :placement_opts, default_placement_opts)
    lease_ttl_ms = Keyword.get(opts, :lease_ttl_ms, Sidecar.sidecar_default_lease_ttl_ms())
    renew_ms = Keyword.get(opts, :renew_ms, Sidecar.sidecar_default_renew_ms())

    with true <-
           (is_integer(lease_ttl_ms) and
              lease_ttl_ms in Sidecar.sidecar_min_lease_ttl_ms()..Sidecar.sidecar_max_lease_ttl_ms() and
              is_integer(renew_ms) and
              renew_ms in Sidecar.sidecar_min_renew_ms()..Sidecar.sidecar_max_renew_ms() and
              renew_ms * 2 <= lease_ttl_ms) || {:error, :sidecar_invalid_request},
         true <- valid_placement?(placement, placement_opts) || {:error, :sidecar_invalid_request},
         {:ok, grants} <- validate_grants(Keyword.get(opts, :grants, [])) do
      schedule_renewal(renew_ms)
      {:ok,
       %{
         vm_id: vm_id,
         owner: owner,
         owner_ref: Process.monitor(owner),
         placement: placement,
         placement_opts: placement_opts,
         grants: grants,
         instances: %{},
         instance_refs: %{},
         idempotency: %{},
         tickets: %{},
         accepting: true,
         fork_waiter: nil,
         fork_owner: nil,
         fork_owner_ref: nil,
         renewal: nil,
         lease_ttl_ms: lease_ttl_ms,
         renew_ms: renew_ms
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:enable, name, raw}, _from, state) do
    with true <- state.accepting || {:error, :sidecar_closing},
         {:ok, grant} <- validate_grant(name, raw),
         true <- not Map.has_key?(state.grants, name) || {:error, :sidecar_grant_exists} do
      {:reply, :ok, %{state | grants: Map.put(state.grants, name, grant)}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:disable, name, destroy}, _from, state) do
    active = Enum.filter(state.instances, fn {_id, item} -> item.grant == name end)

    cond do
      not state.accepting ->
        {:reply, {:error, :sidecar_closing}, state}

      not Map.has_key?(state.grants, name) ->
        {:reply, {:error, :sidecar_grant_missing}, state}

      active != [] and not destroy ->
        {:reply, {:error, :sidecar_in_use}, state}

      true ->
        next = close_instances(state, active)
        {:reply, :ok, %{next | grants: Map.delete(next.grants, name)}}
    end
  end

  def handle_call({:create, request, guest}, _from, state) do
    with true <- state.accepting || {:error, :sidecar_closing},
         {:ok, grant} <- grant_for(state, request),
         true <- (not guest or grant.guest) || {:error, :sidecar_permission_denied},
         :ok <- instance_limit(state, request.grant, grant),
         {:new, digest} <- idempotency(state, request),
         {:ok, {provider, provider_opts}} <- select_provider(state, request),
         id <- new_id(),
         context <- %{
           vm_id: state.vm_id,
           grant: request.grant,
           kind: request.kind,
           version: grant.version,
           contract_digest: grant.contract_digest
         },
         child <-
           {Instance,
            vm_id: state.vm_id,
            id: id,
            owner: self(),
            provider: provider,
            provider_opts: provider_opts,
            context: context,
            request: request,
            lease_ttl_ms: state.lease_ttl_ms},
         {:ok, pid} <- start_instance(child) do
      ref = Process.monitor(pid)
      item = %{pid: pid, ref: ref, grant: request.grant, kind: request.kind}

      next = %{
        state
        | instances: Map.put(state.instances, id, item),
          instance_refs: Map.put(state.instance_refs, ref, id),
          idempotency: Map.put(state.idempotency, request.idempotency_key, {digest, id})
      }

      case instance_info(pid) do
        {:ok, info} ->
          {:reply, {:ok, info}, next}

        {:error, reason} ->
          Process.demonitor(ref, [:flush])
          {:reply, {:error, reason}, drop_instance(next, id, ref)}
      end
    else
      {:existing, id} -> {:reply, retrieve_from_state(state, id), state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:retrieve, id}, _from, state) do
    reply = if state.accepting, do: retrieve_from_state(state, id), else: {:error, :sidecar_closing}
    {:reply, reply, state}
  end

  def handle_call({:retrieve_checked, request, guest}, _from, state) do
    reply =
      with true <- state.accepting || {:error, :sidecar_closing},
           {:ok, grant} <- grant_for(state, request),
           true <- (not guest or grant.guest) || {:error, :sidecar_permission_denied},
           {:ok, item} <- instance_for(state, request.id),
           {:ok, info} <- checked_instance_info(item, request) do
        {:ok, info}
      end

    {:reply, reply, state}
  end

  def handle_call({:list, kind}, _from, state) do
    if state.accepting do
      items =
        state.instances
        |> Enum.filter(fn {_id, item} -> is_nil(kind) or item.kind == kind end)
        |> Enum.flat_map(fn {_id, item} ->
          case instance_info(item.pid) do
            {:ok, info} -> [info]
            {:error, _reason} -> []
          end
        end)
        |> Enum.sort_by(& &1.id)

      {:reply, items, state}
    else
      {:reply, {:error, :sidecar_closing}, state}
    end
  end

  def handle_call({:list_checked, request, guest}, _from, state) do
    reply =
      with true <- state.accepting || {:error, :sidecar_closing},
           {:ok, grant} <- grant_for(state, request),
           true <- (not guest or grant.guest) || {:error, :sidecar_permission_denied} do
        state.instances
        |> Enum.filter(fn {_id, item} ->
          item.grant == request.grant and item.kind == request.kind
        end)
        |> Enum.flat_map(fn {_id, item} ->
          case instance_info(item.pid) do
            {:ok, info} -> [info]
            {:error, _reason} -> []
          end
        end)
        |> Enum.sort_by(& &1.id)
      end

    {:reply, reply, state}
  end

  def handle_call(:grants, _from, state), do: {:reply, state.grants, state}
  def handle_call(:owner, _from, state), do: {:reply, state.owner, state}

  def handle_call({:checkout, request, guest}, {caller, _tag}, state) do
    with true <- state.accepting || {:error, :sidecar_closing},
         true <-
           map_size(state.tickets) < Sidecar.sidecar_max_inflight_per_vm() ||
             {:error, :sidecar_limit},
         {:ok, grant} <- grant_for(state, request),
         true <- (not guest or grant.guest) || {:error, :sidecar_permission_denied},
         {:ok, item} <- instance_for(state, request.id),
         true <-
           (item.grant == request.grant and item.kind == request.kind) ||
             {:error, :sidecar_invalid_request} do
      ticket = make_ref()
      monitor = Process.monitor(caller)
      next = put_in(state.tickets[ticket], %{monitor: monitor, pid: item.pid})
      {:reply, {:ok, {ticket, item.pid}}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    if state.accepting do
      case Map.get(state.instances, id) do
        nil -> {:reply, :ok, state}
        item -> {:reply, :ok, close_instance(state, id, item)}
      end
    else
      {:reply, {:error, :sidecar_closing}, state}
    end
  end

  def handle_call({:delete_checked, request, guest}, _from, state) do
    with true <- state.accepting || {:error, :sidecar_closing},
         {:ok, grant} <- grant_for(state, request),
         true <- (not guest or grant.guest) || {:error, :sidecar_permission_denied} do
      case Map.get(state.instances, request.id) do
        nil ->
          {:reply, :ok, state}

        item ->
          case matches_instance(item, request) do
            :ok -> {:reply, :ok, close_instance(state, request.id, item)}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:begin_fork, {caller, _tag} = from, state) do
    cond do
      not state.accepting ->
        {:reply, {:error, :sidecar_closing}, state}

      map_size(state.tickets) == 0 ->
        {warnings, next} = quiesce(state)
        {:reply, {:ok, warnings},
         %{next | fork_owner: caller, fork_owner_ref: Process.monitor(caller)}}

      true ->
        {:noreply,
         %{
           state
           | accepting: false,
             fork_waiter: from,
             fork_owner: caller,
             fork_owner_ref: Process.monitor(caller)
         }}
    end
  end

  def handle_call(:close, _from, state) do
    next = close_all(%{state | accepting: false})
    {:stop, :normal, :ok, next}
  end

  def handle_call(:end_fork, {caller, _tag}, state) do
    cond do
      state.fork_owner == nil -> {:reply, :ok, state}
      state.fork_owner != caller -> {:reply, {:error, :sidecar_permission_denied}, state}
      true -> {:reply, :ok, resume_fork(state)}
    end
  end

  @impl true
  def handle_cast({:checkin, ticket}, state), do: {:noreply, release_ticket(state, ticket)}

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    cond do
      ref == state.owner_ref -> {:stop, :normal, close_all(%{state | accepting: false})}
      ref == state.fork_owner_ref -> {:noreply, resume_fork(state)}
      id = state.instance_refs[ref] -> {:noreply, drop_instance(state, id, ref)}
      ticket = ticket_for_monitor(state.tickets, ref) -> {:noreply, release_ticket(state, ticket)}
      true -> {:noreply, state}
    end
  end

  def handle_info(:renew_leases, %{renewal: nil} = state) do
    expires_at_ms = System.system_time(:millisecond) + state.lease_ttl_ms
    owner = self()
    token = make_ref()
    instances = Enum.map(state.instances, fn {_id, item} -> item.pid end)

    case Task.Supervisor.start_child(AgentOS.SidecarTaskSupervisor, fn ->
           try do
             Task.Supervisor.async_stream_nolink(
               AgentOS.SidecarTaskSupervisor,
               instances,
               fn instance -> Instance.renew(instance, expires_at_ms) end,
               max_concurrency: 8,
               on_timeout: :kill_task,
               ordered: false,
               timeout: 3_000
             )
             |> Stream.run()
           after
             send(owner, {:renewal_complete, token})
           end
         end) do
      {:ok, _pid} ->
        {:noreply, %{state | renewal: token}}

      {:error, _reason} ->
        schedule_renewal(state.renew_ms)
        {:noreply, state}
    end
  end

  def handle_info(:renew_leases, state), do: {:noreply, state}

  def handle_info({:renewal_complete, token}, %{renewal: token} = state) do
    schedule_renewal(state.renew_ms)
    {:noreply, %{state | renewal: nil}}
  end

  def handle_info({:renewal_complete, _stale}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = close_all(state)
    :ok
  end

  defp validate_grants(raw) when is_map(raw), do: validate_grants(Map.to_list(raw))

  defp validate_grants(raw) when is_list(raw) do
    if length(raw) > Sidecar.sidecar_max_grants() do
      {:error, :sidecar_limit}
    else
      Enum.reduce_while(raw, {:ok, %{}}, fn
        {name, grant}, {:ok, acc} ->
          case validate_grant(to_string(name), grant) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, to_string(name), normalized)}}
            error -> {:halt, error}
          end

        grant, {:ok, acc} when is_map(grant) ->
          name = field(grant, :name)

          case validate_grant(name, grant) do
            {:ok, normalized} -> {:cont, {:ok, Map.put(acc, name, normalized)}}
            error -> {:halt, error}
          end

        _other, _acc ->
          {:halt, {:error, :sidecar_invalid_request}}
      end)
    end
  end

  defp validate_grants(_raw), do: {:error, :sidecar_limit}

  defp validate_grant(name, raw) when is_binary(name) and is_map(raw) do
    grant = %{
      name: name,
      kind: field(raw, :kind),
      version: field(raw, :version),
      contract_digest: field(raw, :contract_digest, field(raw, :contractDigest)),
      guest: field(raw, :guest, false),
      max_instances: field(raw, :max_instances, field(raw, :maxInstances, 1)),
      fork: field(raw, :fork, Sidecar.sidecar_fork_omit()),
      config: field(raw, :config, <<>>)
    }

    with true <-
           identifier?(name, Sidecar.sidecar_max_name_bytes()) ||
             {:error, :sidecar_invalid_request},
         true <-
           identifier?(grant.kind, Sidecar.sidecar_max_kind_bytes(), true) ||
             {:error, :sidecar_invalid_request},
         true <-
           (is_integer(grant.version) and grant.version > 0) || {:error, :sidecar_invalid_request},
         true <- is_binary(grant.contract_digest) || {:error, :sidecar_invalid_request},
         true <-
           byte_size(grant.contract_digest) in 1..Sidecar.sidecar_max_digest_bytes() ||
             {:error, :sidecar_invalid_request},
         true <- is_boolean(grant.guest) || {:error, :sidecar_invalid_request},
         true <-
           grant.max_instances in 1..Sidecar.sidecar_max_instances_per_grant() ||
             {:error, :sidecar_limit},
         true <-
           grant.fork == Sidecar.sidecar_fork_omit() ||
             {:error, :sidecar_unsupported_fork_policy},
         true <-
           (is_binary(grant.config) and
              byte_size(grant.config) <= Sidecar.sidecar_max_request_bytes()) ||
             {:error, :sidecar_limit},
         {:ok, {_provider, _opts}} <- AgentOS.Sidecars.ProviderRegistry.lookup(grant.kind),
         true <- capability_matches?(grant) || {:error, :sidecar_contract_mismatch} do
      {:ok, grant}
    end
  end

  defp validate_grant(_name, _raw), do: {:error, :sidecar_invalid_request}

  defp capability_matches?(grant) do
    AgentOS.Sidecars.ProviderRegistry.capabilities()
    |> Enum.any?(fn capability ->
      capability.kind == grant.kind and capability.version == grant.version and
        capability.contract_digest == grant.contract_digest and capability.fork == :omit and
        grant.max_instances <= capability.max_instances_per_vm
    end)
  end

  defp grant_for(state, request) do
    case state.grants[request.grant] do
      %{kind: kind} = grant when kind == request.kind -> {:ok, grant}
      _ -> {:error, :sidecar_grant_missing}
    end
  end

  defp instance_for(state, id) do
    case state.instances[id] do
      nil -> {:error, :sidecar_detached}
      item -> {:ok, item}
    end
  end

  defp checked_instance_info(item, request) do
    with {:ok, info} <- instance_info(item.pid) do
      cond do
        item.grant != request.grant or item.kind != request.kind ->
          {:error, :sidecar_invalid_request}

        info.generation != request.generation ->
          {:error, :sidecar_stale_generation}

        true ->
          {:ok, info}
      end
    end
  end

  defp matches_instance(item, request) do
    case checked_instance_info(item, request) do
      {:ok, _info} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp instance_limit(state, grant_name, grant) do
    per_grant = Enum.count(state.instances, fn {_id, item} -> item.grant == grant_name end)
    per_kind = Enum.count(state.instances, fn {_id, item} -> item.kind == grant.kind end)
    kind_limit = capability_limit(grant.kind)

    if map_size(state.instances) < Sidecar.sidecar_max_instances_per_vm() and
         per_grant < grant.max_instances and per_kind < kind_limit,
       do: :ok,
       else: {:error, :sidecar_limit}
  end

  defp capability_limit(kind) do
    AgentOS.Sidecars.ProviderRegistry.capabilities()
    |> Enum.find_value(0, fn capability ->
      if capability.kind == kind, do: capability.max_instances_per_vm
    end)
  end

  defp idempotency(state, request) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(Map.drop(request, [:timeout_ms])))

    case state.idempotency[request.idempotency_key] do
      nil -> {:new, digest}
      {^digest, id} -> {:existing, id}
      {_other, _id} -> {:error, :sidecar_idempotency_conflict}
    end
  end

  defp retrieve_from_state(state, id) do
    case state.instances[id] do
      nil -> {:error, :sidecar_not_found}
      item -> instance_info(item.pid)
    end
  end

  defp close_instance(state, id, item) do
    _ = instance_call(fn -> Instance.close(item.pid) end)
    Process.demonitor(item.ref, [:flush])
    drop_instance(state, id, item.ref)
  end

  defp close_instances(state, instances) do
    Task.Supervisor.async_stream_nolink(
      AgentOS.SidecarTaskSupervisor,
      instances,
      fn {_id, item} -> instance_call(fn -> Instance.close(item.pid) end) end,
      max_concurrency: 8,
      ordered: false,
      on_timeout: :kill_task,
      timeout: @cleanup_timeout
    )
    |> Stream.run()

    Enum.reduce(instances, state, fn {id, item}, acc ->
      Process.demonitor(item.ref, [:flush])
      drop_instance(acc, id, item.ref)
    end)
  end

  defp drop_instance(state, id, ref) do
    %{
      state
      | instances: Map.delete(state.instances, id),
        instance_refs: Map.delete(state.instance_refs, ref),
        idempotency: Map.reject(state.idempotency, fn {_key, {_digest, value}} -> value == id end)
    }
  end

  defp close_all(state) do
    Task.Supervisor.async_stream_nolink(
      AgentOS.SidecarTaskSupervisor,
      Map.values(state.instances),
      fn item -> Instance.close(item.pid) end,
      max_concurrency: 8,
      ordered: false,
      on_timeout: :kill_task,
      timeout: @cleanup_timeout
    )
    |> Stream.run()

    Enum.each(state.instances, fn {_id, item} -> Process.demonitor(item.ref, [:flush]) end)
    %{state | instances: %{}, instance_refs: %{}, idempotency: %{}}
  end

  defp release_ticket(state, ticket) do
    case Map.pop(state.tickets, ticket) do
      {nil, _tickets} ->
        state

      {%{monitor: monitor}, tickets} ->
        Process.demonitor(monitor, [:flush])
        maybe_finish_fork(%{state | tickets: tickets})
    end
  end

  defp maybe_finish_fork(%{fork_waiter: nil} = state), do: state
  defp maybe_finish_fork(%{tickets: tickets} = state) when map_size(tickets) != 0, do: state

  defp maybe_finish_fork(state) do
    {warnings, next} = quiesce(state)
    GenServer.reply(state.fork_waiter, {:ok, warnings})
    %{next | fork_waiter: nil}
  end

  defp resume_fork(state) do
    if state.fork_waiter == nil and state.fork_owner_ref != nil do
      Enum.each(state.instances, fn {_id, item} ->
        instance_call(fn -> Instance.end_fork(item.pid) end)
      end)
    end

    if state.fork_owner_ref != nil do
      Process.demonitor(state.fork_owner_ref, [:flush])
    end

    %{state | accepting: true, fork_waiter: nil, fork_owner: nil, fork_owner_ref: nil}
  end

  defp quiesce(state) do
    warnings =
      Enum.flat_map(state.instances, fn {id, item} ->
        case instance_call(fn -> Instance.begin_fork(item.pid) end) do
          :ok ->
            [
              %{
                code: Sidecar.sidecar_warning_fork_omitted(),
                message:
                  "sidecar '#{id}' was omitted because its provider does not support independent cloning",
                kind: item.kind,
                grant: item.grant,
                id: id
              }
            ]

          {:error, _reason} ->
            []
        end
      end)

    {warnings, %{state | accepting: false}}
  end

  defp ticket_for_monitor(tickets, monitor),
    do: Enum.find_value(tickets, fn {ticket, item} -> if item.monitor == monitor, do: ticket end)

  defp new_id, do: "sc_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp start_instance(child) do
    case DynamicSupervisor.start_child(AgentOS.SidecarInstanceSupervisor, child) do
      {:error, :max_children} -> {:error, :sidecar_limit}
      result -> result
    end
  end

  defp identifier?(value, max, dotted \\ false)

  defp identifier?(value, max, dotted) when is_binary(value) do
    byte_size(value) in 1..max and
      Regex.match?(
        if(dotted,
          do: ~r/^[a-z][a-z0-9_-]*(?:\.[a-z0-9][a-z0-9_-]*)*$/,
          else: ~r/^[a-z][a-z0-9_-]*$/
        ),
        value
      )
  end

  defp identifier?(_value, _max, _dotted), do: false

  defp field(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp schedule_renewal(interval), do: Process.send_after(self(), :renew_leases, interval)

  defp valid_placement?(placement, opts) do
    is_atom(placement) and is_list(opts) and Code.ensure_loaded?(placement) and
      function_exported?(placement, :select, 3)
  end

  defp select_provider(state, request) do
    task =
      Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fn ->
        state.placement.select(
          request.kind,
          %{vm_id: state.vm_id, grant: request.grant},
          state.placement_opts
        )
      end)

    result =
      case Task.yield(task, @placement_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, value} -> value
        _timeout_or_exit -> {:error, :sidecar_unavailable}
      end

    case result do
      {:ok, {provider, opts}} when is_atom(provider) and is_list(opts) ->
        if valid_provider?(provider),
          do: {:ok, {provider, opts}},
          else: {:error, :sidecar_unavailable}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :sidecar_unavailable}
    end
  rescue
    _error -> {:error, :sidecar_unavailable}
  catch
    _kind, _reason -> {:error, :sidecar_unavailable}
  end

  defp valid_provider?(provider) do
    Code.ensure_loaded?(provider) and
      Enum.all?([create: 3, inspect: 3, renew: 4, invoke: 5, delete: 3], fn {name, arity} ->
        function_exported?(provider, name, arity)
      end)
  end

  defp instance_info(pid) do
    case instance_call(fn -> Instance.info(pid) end) do
      {:error, _reason} -> {:error, :sidecar_detached}
      info -> {:ok, info}
    end
  end

  defp instance_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :sidecar_detached}
  end
end
