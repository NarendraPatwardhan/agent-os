defmodule AgentOS.Sidecars.Reconciler do
  @moduledoc "Bounded periodic reconciliation for provider resources left by interrupted transactions."

  use GenServer

  @default_interval 30_000
  @provider_timeout 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    case Keyword.get(opts, :reconcile_interval, @default_interval) do
      interval when is_integer(interval) and interval > 0 ->
        schedule(interval)
        {:ok, %{interval: interval}}

      _invalid ->
        {:stop, :sidecar_invalid_reconcile_interval}
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    Task.Supervisor.async_stream_nolink(
      AgentOS.SidecarTaskSupervisor,
      AgentOS.Sidecars.ProviderRegistry.providers(),
      fn {provider, opts} ->
        if function_exported?(provider, :reconcile, 1), do: provider.reconcile(opts), else: :ok
      end,
      max_concurrency: 4,
      on_timeout: :kill_task,
      ordered: false,
      timeout: @provider_timeout
    )
    |> Stream.run()

    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :reconcile, interval)
end
