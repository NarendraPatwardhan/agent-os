defmodule AgentOS.Sidecars.Firecracker.Daemon do
  @moduledoc false
  use GenServer, restart: :transient

  alias AgentOS.Sidecars.Firecracker.{Client, Helper}

  @boot_timeout 15_000

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def status(id), do: GenServer.call(via(id), :status)
  def socket(id), do: GenServer.call(via(id), :socket)
  def diagnostics(id), do: GenServer.call(via(id), :diagnostics)
  def cgroup(id), do: GenServer.call(via(id), :cgroup)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :id)
    provider_opts = Keyword.fetch!(opts, :provider_opts)

    with {:ok, paths} <- prepare_paths(id, provider_opts) do
      case launch(id, paths, provider_opts) do
        {:ok, port} ->
          case boot(paths, provider_opts) do
            :ok ->
              {:ok,
               %{
                 id: id,
                 paths: paths,
                 port: port,
                 state: :ready,
                 provider_opts: provider_opts,
                 console: <<>>
               }}

            {:error, reason} ->
              close_port(port)
              Helper.cleanup(id, paths, %{paths: paths, provider_opts: provider_opts})
              {:stop, reason}
          end

        {:error, reason} ->
          Helper.cleanup(id, paths, %{paths: paths, provider_opts: provider_opts})
          {:stop, reason}
      end
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, {:ok, %{state: state.state}}, state}
  def handle_call(:socket, _from, state), do: {:reply, {:ok, state.paths.vsock}, state}
  def handle_call(:diagnostics, _from, state), do: {:reply, state.console, state}
  def handle_call(:cgroup, _from, state), do: {:reply, Map.get(state.paths, :cgroup), state}

  @impl true
  def handle_info({_port, {:data, data}}, state) do
    console = state.console <> data
    keep = min(byte_size(console), 64 * 1024)
    {:noreply, %{state | console: binary_part(console, byte_size(console) - keep, keep)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: {:stop, {:firecracker_exit, status}, %{state | state: :failed}}

  @impl true
  def terminate(_reason, state) do
    if Map.get(state, :port), do: close_port(state.port)
    if Map.get(state, :paths), do: Helper.cleanup(state.id, state.paths, state)
    :ok
  end

  defp prepare_paths(id, opts) do
    case Keyword.get(opts, :launch, :jailed) do
      :jailed ->
        Helper.layout(id, opts)

      :direct ->
        root = Keyword.fetch!(opts, :work_root)

        if valid_id?(id) and Path.type(root) == :absolute do
          firecracker = absolute_regular!(opts, :firecracker)
          kernel = absolute_regular!(opts, :kernel)
          initramfs = absolute_regular!(opts, :initramfs)
          directory = Path.join(root, id)

          with :ok <- File.mkdir_p(directory) do
            vsock = Path.join(directory, "vsock.sock")

            {:ok,
             %{
               root: directory,
               api: Path.join(directory, "api.sock"),
               vsock: vsock,
               vsock_api: vsock,
               firecracker: firecracker,
               kernel: kernel,
               initramfs: initramfs,
               cgroup: Keyword.get(opts, :cgroup)
             }}
          end
        else
          {:error, :invalid_firecracker_path}
        end
    end
  rescue
    KeyError -> {:error, :missing_firecracker_path}
    ArgumentError -> {:error, :invalid_firecracker_path}
  end

  defp absolute_regular!(opts, key) do
    path = Keyword.fetch!(opts, key)

    if Path.type(path) == :absolute and File.regular?(path),
      do: path,
      else: raise(ArgumentError, "invalid #{key} path")
  end

  defp launch(id, paths, opts) do
    case Keyword.get(opts, :launch, :jailed) do
      :direct ->
        port =
          Port.open({:spawn_executable, String.to_charlist(paths.firecracker)}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, ["--api-sock", paths.api]},
            {:cd, paths.root}
          ])

        {:ok, port}

      :jailed ->
        Helper.launch(id, paths, opts)
    end
  rescue
    error -> {:error, {:firecracker_launch_failed, error}}
  end

  defp configure(paths, opts) do
    memory = Keyword.get(opts, :memory_mib, 128)
    vcpus = Keyword.get(opts, :vcpus, 1)
    cid = Keyword.get(opts, :guest_cid, 3)

    with :ok <-
           Client.put(paths.api, "/boot-source", %{
             kernel_image_path: paths.kernel,
             initrd_path: paths.initramfs,
             boot_args:
               "console=ttyS0 reboot=k panic=1 pci=off nomodules random.trust_cpu=on init=/init"
           }),
         :ok <-
           Client.put(paths.api, "/machine-config", %{
             vcpu_count: vcpus,
             mem_size_mib: memory,
             smt: false
           }),
         :ok <-
           Client.put(paths.api, "/vsock", %{
             guest_cid: cid,
             uds_path: paths.vsock_api
           }),
         :ok <- Client.put(paths.api, "/actions", %{action_type: "InstanceStart"}) do
      :ok
    end
  end

  defp boot(paths, opts) do
    with :ok <- wait_for_socket(paths.api, @boot_timeout),
         :ok <- configure(paths, opts) do
      :ok
    end
  end

  defp wait_for_socket(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(path, deadline)
  end

  defp wait_loop(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :firecracker_api_timeout}

      true ->
        Process.sleep(10)
        wait_loop(path, deadline)
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
  end

  defp valid_id?(id),
    do:
      is_binary(id) and byte_size(id) in 15..64 and
        Regex.match?(~r/^sc_[A-Za-z0-9_-]+$/, id)

  defp via(id), do: {:via, Registry, {AgentOS.SidecarRegistry, {:firecracker_daemon, id}}}
end
