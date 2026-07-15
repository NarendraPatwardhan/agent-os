defmodule AgentOS.Sidecars do
  @moduledoc """
  Transport-neutral sidecar lifecycle facade.

  Every lookup is scoped by the owning AgentOS VM id. Provider references and placement details remain
  behind the per-VM scope and never enter the guest or consuming HTTP transport.
  """

  alias AgentOS.Contracts.Sidecar
  alias AgentOS.Sidecars.{Instance, Scope}

  def capabilities, do: AgentOS.Sidecars.ProviderRegistry.capabilities()

  def attach_vm(vm_id, owner, grants \\ [], opts \\ []) do
    child = {Scope, Keyword.merge(opts, vm_id: vm_id, owner: owner, grants: grants)}

    case start_scope(child) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        case safe_scope_call(fn -> Scope.owner(pid) end) do
          ^owner -> {:ok, pid}
          {:error, _reason} -> replace_scope(pid, child)
          _other_owner -> replace_scope(pid, child)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def whereis(vm_id) do
    case Registry.lookup(AgentOS.SidecarRegistry, {:scope, vm_id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  def enable(vm_id, name, grant), do: with_scope(vm_id, &Scope.enable(&1, name, grant))

  def disable(vm_id, name, destroy \\ false),
    do: with_scope(vm_id, &Scope.disable(&1, name, destroy))

  def create(vm_id, request, opts \\ []) do
    with {:ok, request} <- normalize_create(request) do
      with_scope(vm_id, &Scope.create(&1, request, Keyword.get(opts, :guest, false)))
    end
  end

  def retrieve(vm_id, id), do: with_scope(vm_id, &Scope.retrieve(&1, id))

  def retrieve_checked(vm_id, request, opts \\ []) do
    with {:ok, request} <- normalize_identity(request) do
      with_scope(
        vm_id,
        &Scope.retrieve_checked(&1, request, Keyword.get(opts, :guest, false))
      )
    end
  end

  def list(vm_id, kind \\ nil), do: with_scope(vm_id, &Scope.list(&1, kind))

  def list_checked(vm_id, request, opts \\ []) do
    with {:ok, request} <- normalize_list(request) do
      with_scope(vm_id, &Scope.list_checked(&1, request, Keyword.get(opts, :guest, false)))
    end
  end

  def grants(vm_id), do: with_scope(vm_id, &Scope.grants/1)

  def invoke(vm_id, request, opts \\ []) do
    guest = Keyword.get(opts, :guest, false)

    with {:ok, request} <- normalize_call(request),
         scope when is_pid(scope) <- whereis(vm_id),
         {:ok, {ticket, instance}} <-
           safe_scope_call(fn -> Scope.checkout(scope, request, guest) end) do
      try do
        Instance.invoke(instance, request, request.timeout_ms + 5_000)
      after
        Scope.checkin(scope, ticket)
      end
    else
      nil -> {:error, :sidecar_scope_missing}
      {:error, _reason} = error -> error
    end
  end

  def delete(vm_id, id), do: with_scope(vm_id, &Scope.delete(&1, id))

  def delete_checked(vm_id, request, opts \\ []) do
    with {:ok, request} <- normalize_identity(request) do
      with_scope(vm_id, &Scope.delete_checked(&1, request, Keyword.get(opts, :guest, false)))
    end
  end

  def begin_fork(vm_id), do: with_scope(vm_id, &Scope.begin_fork/1)

  def end_fork(vm_id), do: with_scope(vm_id, &Scope.end_fork/1)

  def close_vm(vm_id) do
    AgentOS.Sidecars.Egress.cancel_vm(vm_id)

    case whereis(vm_id) do
      nil ->
        :ok

      scope ->
        case safe_scope_call(fn -> Scope.close(scope) end) do
          {:error, :sidecar_scope_missing} -> :ok
          result -> result
        end
    end
  end

  def dispatch_egress(vm_id, event), do: AgentOS.Sidecars.Egress.dispatch(vm_id, event)

  defp normalize_create(raw) when is_map(raw) do
    request = %{
      grant: field(raw, :grant),
      kind: field(raw, :kind),
      body: field(raw, :body, <<>>),
      idempotency_key: field(raw, :idempotency_key, field(raw, :idempotencyKey)),
      timeout_ms:
        field(
          raw,
          :timeout_ms,
          field(raw, :timeoutMs, Sidecar.sidecar_default_operation_timeout_ms())
        )
    }

    cond do
      not identifier?(request.grant, Sidecar.sidecar_max_name_bytes()) or
          not identifier?(request.kind, Sidecar.sidecar_max_kind_bytes(), true) ->
        {:error, :sidecar_invalid_request}

      not is_binary(request.body) or byte_size(request.body) > Sidecar.sidecar_max_request_bytes() ->
        {:error, :sidecar_limit}

      not is_binary(request.idempotency_key) or
          byte_size(request.idempotency_key) not in 1..Sidecar.sidecar_max_idempotency_bytes() ->
        {:error, :sidecar_invalid_request}

      not valid_timeout?(request.timeout_ms) ->
        {:error, :sidecar_invalid_request}

      true ->
        {:ok, request}
    end
  end

  defp normalize_create(_raw), do: {:error, :sidecar_invalid_request}

  defp normalize_call(raw) when is_map(raw) do
    request = %{
      id: field(raw, :id),
      generation: field(raw, :generation),
      grant: field(raw, :grant),
      kind: field(raw, :kind),
      operation: field(raw, :operation),
      body: field(raw, :body, <<>>),
      idempotency_key: field(raw, :idempotency_key, field(raw, :idempotencyKey)),
      timeout_ms:
        field(
          raw,
          :timeout_ms,
          field(raw, :timeoutMs, Sidecar.sidecar_default_operation_timeout_ms())
        )
    }

    cond do
      not opaque_id?(request.id) or
        not identifier?(request.grant, Sidecar.sidecar_max_name_bytes()) or
        not identifier?(request.kind, Sidecar.sidecar_max_kind_bytes(), true) or
          not identifier?(request.operation, Sidecar.sidecar_max_operation_bytes(), true) ->
        {:error, :sidecar_invalid_request}

      not is_integer(request.generation) or request.generation < 1 ->
        {:error, :sidecar_invalid_request}

      not is_binary(request.body) or byte_size(request.body) > Sidecar.sidecar_max_request_bytes() ->
        {:error, :sidecar_limit}

      not is_nil(request.idempotency_key) and
          (not is_binary(request.idempotency_key) or
             byte_size(request.idempotency_key) == 0 or
             byte_size(request.idempotency_key) > Sidecar.sidecar_max_idempotency_bytes()) ->
        {:error, :sidecar_invalid_request}

      not valid_timeout?(request.timeout_ms) ->
        {:error, :sidecar_invalid_request}

      true ->
        {:ok, request}
    end
  end

  defp normalize_call(_raw), do: {:error, :sidecar_invalid_request}

  defp normalize_identity(raw) when is_map(raw) do
    request = %{
      id: field(raw, :id),
      generation: field(raw, :generation),
      grant: field(raw, :grant),
      kind: field(raw, :kind)
    }

    if opaque_id?(request.id) and
         identifier?(request.grant, Sidecar.sidecar_max_name_bytes()) and
         identifier?(request.kind, Sidecar.sidecar_max_kind_bytes(), true) and
         is_integer(request.generation) and request.generation >= 1,
       do: {:ok, request},
       else: {:error, :sidecar_invalid_request}
  end

  defp normalize_identity(_raw), do: {:error, :sidecar_invalid_request}

  defp normalize_list(raw) when is_map(raw) do
    request = %{grant: field(raw, :grant), kind: field(raw, :kind)}

    if identifier?(request.grant, Sidecar.sidecar_max_name_bytes()) and
         identifier?(request.kind, Sidecar.sidecar_max_kind_bytes(), true),
       do: {:ok, request},
       else: {:error, :sidecar_invalid_request}
  end

  defp normalize_list(_raw), do: {:error, :sidecar_invalid_request}

  defp valid_timeout?(value),
    do: is_integer(value) and value in 1..Sidecar.sidecar_max_operation_timeout_ms()

  defp field(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp with_scope(vm_id, fun) do
    case whereis(vm_id) do
      nil -> {:error, :sidecar_scope_missing}
      scope -> safe_scope_call(fn -> fun.(scope) end)
    end
  end

  defp replace_scope(pid, child) do
    ref = Process.monitor(pid)
    _ = safe_scope_call(fn -> Scope.close(pid) end)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        start_scope(child)
    after
      5_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :sidecar_scope_replace_timeout}
    end
  end

  defp opaque_id?(value) when is_binary(value),
    do:
      byte_size(value) in 1..Sidecar.sidecar_max_name_bytes() and
        Regex.match?(~r/^[A-Za-z0-9_-]+$/, value)

  defp opaque_id?(_value), do: false

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

  defp start_scope(child) do
    case DynamicSupervisor.start_child(AgentOS.SidecarScopeSupervisor, child) do
      {:error, :max_children} -> {:error, :sidecar_limit}
      result -> result
    end
  end

  defp safe_scope_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :sidecar_scope_missing}
  end
end
