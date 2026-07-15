defmodule AgentOS.Sidecars.Firecracker.Meter do
  @moduledoc false
  use GenServer, restart: :transient

  @interval 5_000

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def sample(id), do: GenServer.call(via(id), :sample)

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    cgroup = Keyword.get(opts, :cgroup) || AgentOS.Sidecars.Firecracker.Daemon.cgroup(id)
    state = %{cgroup: cgroup, sample: %{}}
    schedule()
    {:ok, state}
  end

  @impl true
  def handle_call(:sample, _from, state), do: {:reply, state.sample, state}

  @impl true
  def handle_info(:sample, state) do
    schedule()
    {:noreply, %{state | sample: read_sample(state.cgroup)}}
  end

  defp read_sample(nil), do: %{}

  defp read_sample(root) do
    %{
      cpu_stat: read_bounded(Path.join(root, "cpu.stat")),
      memory_current: read_bounded(Path.join(root, "memory.current")),
      memory_peak: read_bounded(Path.join(root, "memory.peak"))
    }
  end

  defp read_bounded(path) do
    case File.read(path) do
      {:ok, bytes} -> binary_part(bytes, 0, min(byte_size(bytes), 4_096))
      {:error, _reason} -> nil
    end
  end

  defp schedule, do: Process.send_after(self(), :sample, @interval)
  defp via(id), do: {:via, Registry, {AgentOS.SidecarRegistry, {:firecracker_meter, id}}}
end
