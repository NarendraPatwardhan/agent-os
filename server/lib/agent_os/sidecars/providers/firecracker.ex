defmodule AgentOS.Sidecars.Providers.Firecracker do
  @moduledoc """
  Same-node Firecracker provider for sidecar runner bundles.

  Production configuration uses the root-owned AgentOS sidecar helper and jailer. `:direct` launch is
  accepted only when `development: true`; it exists for single-user KVM conformance and fails closed in
  every other configuration.
  """

  @behaviour AgentOS.Sidecars.Provider
  require Logger

  alias AgentOS.Contracts.{Browser, Runner}
  alias AgentOS.Sidecars.{Firecracker, Journal}
  alias AgentOS.Sidecars.Firecracker.{Prepared, Snapshot}

  @impl true
  def capabilities(opts) do
    health =
      if Keyword.get(opts, :health_runner, false) do
        [
          %{
            kind: Runner.runner_health_kind(),
            version: 1,
            contract_digest: Runner.runner_health_contract_digest(),
            placements: [:local],
            fork: :omit,
            max_instances_per_vm: Keyword.get(opts, :max_instances_per_vm, 8)
          }
        ]
      else
        []
      end

    browser =
      if Keyword.get(opts, :browser_runner, false) do
        [
          %{
            kind: Browser.browser_kind(),
            version: Browser.browser_version(),
            contract_digest: Browser.browser_contract_digest(),
            placements: [:local],
            fork: :omit,
            max_instances_per_vm: Keyword.get(opts, :max_instances_per_vm, 8)
          }
        ]
      else
        []
      end

    custom =
      case Keyword.fetch(opts, :capability) do
        {:ok, capability} -> [capability]
        :error -> Keyword.get(opts, :capabilities, [])
      end

    health ++ browser ++ custom
  end

  @impl true
  def create(context, request, opts) do
    started_at = monotonic_us()

    with :ok <- validate_grant(context),
         :ok <- validate_launch_mode(opts),
         {:ok, runner_opts} <- runner_opts(context.kind, opts),
         :ok <- validate_machine(runner_opts),
         {:ok, provider_ref, value} <- create_runner(context, request, runner_opts) do
      log_startup(context, started_at)
      {:ok, provider_ref, value}
    end
  end

  defp create_runner(context, request, opts) do
    if Snapshot.enabled?(opts) and context.kind == Browser.browser_kind() do
      create_prepared(context, request, opts)
    else
      start_ready_runner(context, request, opts)
    end
  end

  defp create_prepared(context, request, opts) do
    with {:ok, key} <- Snapshot.key(context.kind, opts),
         {:ok, available?} <- snapshot_available(key, opts) do
      case Prepared.claim(key, available?) do
        :ready ->
          case start_ready_runner(context, request, Keyword.put(opts, :snapshot_key, key)) do
            {:ok, _provider_ref, _metadata} = ready ->
              ready

            {:error, _reason} = error ->
              _ = Snapshot.invalidate(key, opts)
              error
          end

        :build ->
          build_prepared(context, request, key, opts)

        :retry ->
          create_prepared(context, request, opts)
      end
    end
  end

  defp build_prepared(context, request, key, opts) do
    capture =
      case start_ready_runner(context, request, opts) do
        {:ok, provider_ref, _metadata} ->
          result = capture_base(context.id, key)
          _ = terminate_runner(provider_ref.supervisor)
          result

        {:error, _reason} = error ->
          error
      end

    case capture do
      :ok ->
        case start_ready_runner(context, request, Keyword.put(opts, :snapshot_key, key)) do
          {:ok, _provider_ref, _metadata} = ready ->
            :ok = Prepared.ready(key)
            ready

          {:error, _reason} = error ->
            _ = Snapshot.invalidate(key, opts)
            :ok = Prepared.failed(key)
            error
        end

      {:error, _reason} = error ->
        :ok = Prepared.failed(key)
        error
    end
  end

  defp capture_base(id, key) do
    with :ok <- Firecracker.Relay.prepare_snapshot(id),
         {:ok, _measurements} <- Firecracker.Daemon.capture(id, key) do
      :ok
    end
  end

  defp start_ready_runner(context, request, opts) do
    with {:ok, supervisor} <- start_runner(context, request, opts) do
      case metadata(context.id) do
        {:ok, value} ->
          {:ok, %{id: context.id, supervisor: supervisor}, value}

        {:error, reason} ->
          _ = terminate_runner(supervisor)
          {:error, reason}
      end
    end
  end

  defp snapshot_available(key, opts) do
    case Snapshot.available?(key, opts) do
      value when is_boolean(value) -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp runner_opts(kind, opts) do
    profiles = Keyword.get(opts, :profiles, %{})

    defaults =
      if kind == Browser.browser_kind() do
        [profile: Browser.browser_runner_profile(), memory_mib: 1536, network: true]
      else
        []
      end

    case profiles do
      profiles when is_map(profiles) ->
        case Map.get(profiles, kind, []) do
          profile when is_list(profile) ->
            {:ok, opts |> Keyword.merge(defaults) |> Keyword.merge(profile)}

          _invalid ->
            {:error, :invalid_firecracker_profile}
        end

      _invalid ->
        {:error, :invalid_firecracker_profile}
    end
  end

  @impl true
  def inspect(_context, %{id: id}, _opts), do: Firecracker.Daemon.status(id)

  @impl true
  def renew(_context, %{id: id}, _expires_at_ms, opts), do: Firecracker.Helper.renew(id, opts)

  @impl true
  def invoke(_context, %{id: id}, operation, body, opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    call_ref = Keyword.fetch!(opts, :call_ref)
    Firecracker.Relay.invoke(id, call_ref, operation, body, timeout)
  end

  @impl true
  def cancel(_context, %{id: id}, call_ref, _opts), do: Firecracker.Relay.cancel(id, call_ref)

  @impl true
  def delete(_context, %{id: id, supervisor: supervisor}, opts) do
    with :ok <- terminate_runner(supervisor),
         :ok <- Firecracker.Helper.cleanup_checked(id, opts) do
      :ok
    end
  end

  defp terminate_runner(supervisor) do
    case DynamicSupervisor.terminate_child(AgentOS.SidecarFirecrackerSupervisor, supervisor) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def reconcile(opts) do
    kinds = capabilities(opts) |> MapSet.new(& &1.kind)

    with :ok <- Firecracker.Helper.reconcile(opts) do
      Journal.pending()
      |> Enum.filter(&MapSet.member?(kinds, Map.get(&1, :kind)))
      |> Enum.reduce_while(:ok, fn entry, :ok ->
        with :ok <- Firecracker.Helper.cleanup_checked(entry.id, opts),
             :ok <- Journal.complete(entry.journal_id, %{reconciled: true}) do
          {:cont, :ok}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp validate_launch_mode(opts) do
    case Keyword.get(opts, :launch, :jailed) do
      :jailed ->
        Firecracker.Helper.preflight(opts)

      :direct ->
        if Keyword.get(opts, :development, false),
          do: :ok,
          else: {:error, :direct_firecracker_forbidden}

      _other ->
        {:error, :invalid_firecracker_launch_mode}
    end
  end

  defp validate_grant(%{kind: kind, grant_config: config}) do
    if kind == Browser.browser_kind() do
      if config == <<>>, do: :ok, else: {:error, :sidecar_invalid_request}
    else
      :ok
    end
  end

  defp validate_grant(_context), do: :ok

  defp validate_machine(opts) do
    memory = Keyword.get(opts, :memory_mib, 128)
    vcpus = Keyword.get(opts, :vcpus, 1)
    cid = Keyword.get(opts, :guest_cid, 3)

    if is_integer(memory) and memory in 64..32_768 and is_integer(vcpus) and vcpus in 1..32 and
         is_integer(cid) and cid in 3..4_294_967_295,
       do: :ok,
       else: {:error, :invalid_firecracker_machine_config}
  end

  defp start_runner(context, request, opts) do
    case DynamicSupervisor.start_child(
           AgentOS.SidecarFirecrackerSupervisor,
           {Firecracker.Supervisor,
            id: context.id, context: context, request: request, provider_opts: opts}
         ) do
      {:error, :max_children} -> {:error, :sidecar_limit}
      result -> result
    end
  end

  defp metadata(id) do
    Firecracker.Relay.metadata(id)
  catch
    :exit, reason -> {:error, {:firecracker_runner_exit, reason}}
  end

  defp log_startup(context, started_at) do
    with {:ok, daemon} <- Firecracker.Daemon.measurements(context.id),
         {:ok, relay} <- Firecracker.Relay.measurements(context.id) do
      measurements =
        daemon
        |> Map.merge(relay)
        |> Map.put(:provider_us, monotonic_us() - started_at)

      Logger.info("Firecracker sidecar ready",
        sidecar_id: context.id,
        sidecar_kind: context.kind,
        startup_us: measurements
      )
    end
  catch
    :exit, _reason -> :ok
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)
end
