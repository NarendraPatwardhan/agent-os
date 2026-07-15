defmodule AgentOS.Sidecars.ProviderRegistry do
  @moduledoc "Validated provider configuration and capability discovery."

  use GenServer

  alias AgentOS.Contracts.Sidecar

  @capability_timeout 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec lookup(String.t()) :: {:ok, {module(), keyword()}} | {:error, :sidecar_unavailable}
  def lookup(kind), do: GenServer.call(__MODULE__, {:lookup, kind})

  @spec lookup(String.t(), :local | :remote) ::
          {:ok, {module(), keyword()}} | {:error, :sidecar_unavailable}
  def lookup(kind, placement), do: GenServer.call(__MODULE__, {:lookup, kind, placement})

  @spec capabilities() :: [map()]
  def capabilities, do: GenServer.call(__MODULE__, :capabilities)

  @spec providers() :: [{module(), keyword()}]
  def providers, do: GenServer.call(__MODULE__, :providers)

  @spec placement() :: {module(), keyword()}
  def placement, do: GenServer.call(__MODULE__, :placement)

  @impl true
  def init(opts) do
    placement = normalize_placement!(Keyword.get(opts, :placement), Keyword.get(opts, :placement_opts, []))

    providers =
      opts
      |> Keyword.get(:providers, [])
      |> Enum.map(&normalize_provider!/1)

    by_kind =
      Enum.reduce(providers, %{}, fn {provider, provider_opts, capabilities}, acc ->
        Enum.reduce(capabilities, acc, fn capability, inner ->
          kind = Map.fetch!(capability, :kind)

          if Map.has_key?(inner, kind) do
            raise ArgumentError,
                  "more than one sidecar provider is configured for #{inspect(kind)}"
          end

          Map.put(inner, kind, {provider, provider_opts, capability})
        end)
      end)

    configured =
      providers
      |> Enum.map(fn {provider, opts, _} -> {provider, opts} end)
      |> Enum.uniq()

    {:ok, %{by_kind: by_kind, providers: configured, placement: placement}}
  end

  @impl true
  def handle_call({:lookup, kind}, _from, state) do
    reply =
      case Map.get(state.by_kind, kind) do
        {provider, opts, _capability} -> {:ok, {provider, opts}}
        nil -> {:error, :sidecar_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call({:lookup, kind, placement}, _from, state) do
    reply =
      case Map.get(state.by_kind, kind) do
        {provider, opts, %{placements: placements}} ->
          if placement in placements,
            do: {:ok, {provider, opts}},
            else: {:error, :sidecar_unavailable}

        nil ->
          {:error, :sidecar_unavailable}
      end

    {:reply, reply, state}
  end

  def handle_call(:capabilities, _from, state) do
    capabilities = state.by_kind |> Map.values() |> Enum.map(&elem(&1, 2)) |> Enum.sort_by(& &1.kind)
    {:reply, capabilities, state}
  end

  def handle_call(:providers, _from, state), do: {:reply, state.providers, state}
  def handle_call(:placement, _from, state), do: {:reply, state.placement, state}

  defp normalize_placement!(placement, opts) when is_atom(placement) and is_list(opts) do
    unless Code.ensure_loaded?(placement) and function_exported?(placement, :select, 3) do
      raise ArgumentError, "invalid sidecar placement #{inspect(placement)}"
    end

    {placement, opts}
  end

  defp normalize_placement!(placement, opts),
    do: raise(ArgumentError, "invalid sidecar placement #{inspect({placement, opts})}")

  defp normalize_provider!({provider, provider_opts})
       when is_atom(provider) and is_list(provider_opts) do
    required = [capabilities: 1, create: 3, inspect: 3, renew: 4, invoke: 5, delete: 3]

    unless Code.ensure_loaded?(provider) and
             Enum.all?(required, fn {name, arity} -> function_exported?(provider, name, arity) end) do
      raise ArgumentError, "invalid sidecar provider #{inspect(provider)}"
    end

    task =
      Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fn ->
        provider.capabilities(provider_opts)
      end)

    capabilities =
      case Task.yield(task, @capability_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _timeout_or_exit -> raise ArgumentError, "#{inspect(provider)} capability discovery failed"
      end

    unless is_list(capabilities) and capabilities != [] and
             Enum.all?(capabilities, &valid_capability?/1) do
      raise ArgumentError, "#{inspect(provider)} returned invalid sidecar capabilities"
    end

    {provider, provider_opts, capabilities}
  end

  defp normalize_provider!(provider) when is_atom(provider),
    do: normalize_provider!({provider, []})

  defp normalize_provider!(other),
    do: raise(ArgumentError, "invalid sidecar provider entry #{inspect(other)}")

  defp valid_capability?(capability) when is_map(capability) do
    kind = Map.get(capability, :kind)
    version = Map.get(capability, :version)
    digest = Map.get(capability, :contract_digest)
    placements = Map.get(capability, :placements)
    fork = Map.get(capability, :fork)
    maximum = Map.get(capability, :max_instances_per_vm)

    identifier?(kind, Sidecar.sidecar_max_kind_bytes(), true) and
      is_integer(version) and version > 0 and
      is_binary(digest) and byte_size(digest) in 1..Sidecar.sidecar_max_digest_bytes() and
      is_list(placements) and placements != [] and
      Enum.all?(placements, &(&1 in [:local, :remote])) and
      length(placements) == length(Enum.uniq(placements)) and
      fork in [:omit, :clone] and
      is_integer(maximum) and maximum in 1..Sidecar.sidecar_max_instances_per_vm()
  end

  defp valid_capability?(_capability), do: false

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
end
