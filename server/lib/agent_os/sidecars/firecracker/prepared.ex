defmodule AgentOS.Sidecars.Firecracker.Prepared do
  @moduledoc false
  use GenServer

  @type claim :: :build | :ready

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def claim(key, available?) when is_binary(key) and is_boolean(available?) do
    GenServer.call(__MODULE__, {:claim, key, available?}, :infinity)
  end

  def ready(key), do: GenServer.call(__MODULE__, {:ready, key})
  def failed(key), do: GenServer.call(__MODULE__, {:failed, key})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:claim, _key, true}, _from, state), do: {:reply, :ready, state}

  def handle_call({:claim, key, false}, from, state) do
    case Map.get(state, key) do
      nil ->
        {pid, _tag} = from
        monitor = Process.monitor(pid)
        {:reply, :build, Map.put(state, key, %{builder: pid, monitor: monitor, waiters: []})}

      entry ->
        next = %{entry | waiters: [from | entry.waiters]}
        {:noreply, Map.put(state, key, next)}
    end
  end

  def handle_call({:ready, key}, {pid, _tag}, state) do
    complete(key, pid, :ready, state)
  end

  def handle_call({:failed, key}, {pid, _tag}, state) do
    complete(key, pid, :retry, state)
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    case Enum.find(state, fn {_key, entry} ->
           entry.monitor == monitor and entry.builder == pid
         end) do
      {key, entry} ->
        Enum.each(entry.waiters, &GenServer.reply(&1, :retry))
        {:noreply, Map.delete(state, key)}

      nil ->
        {:noreply, state}
    end
  end

  defp complete(key, pid, result, state) do
    case Map.get(state, key) do
      %{builder: ^pid} = entry ->
        Process.demonitor(entry.monitor, [:flush])
        Enum.each(entry.waiters, &GenServer.reply(&1, result))
        {:reply, :ok, Map.delete(state, key)}

      _other ->
        {:reply, {:error, :not_builder}, state}
    end
  end
end
