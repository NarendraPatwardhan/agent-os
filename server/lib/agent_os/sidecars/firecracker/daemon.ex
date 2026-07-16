defmodule AgentOS.Sidecars.Firecracker.Daemon do
  @moduledoc false
  use GenServer, restart: :transient

  require Logger

  alias AgentOS.Sidecars.Firecracker.{Client, Helper, Snapshot}

  @boot_timeout 15_000
  @snapshot_api_timeout 60_000
  @snapshot_timeout 120_000

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def status(id), do: GenServer.call(via(id), :status)
  def socket(id), do: GenServer.call(via(id), :socket)
  def diagnostics(id), do: GenServer.call(via(id), :diagnostics)
  def cgroup(id), do: GenServer.call(via(id), :cgroup)
  def measurements(id), do: GenServer.call(via(id), :measurements)
  def capture(id, key), do: GenServer.call(via(id), {:capture, key}, @snapshot_timeout)

  @impl true
  def init(opts) do
    started_at = monotonic_us()
    Process.flag(:trap_exit, true)
    id = Keyword.fetch!(opts, :id)
    provider_opts = Keyword.fetch!(opts, :provider_opts)

    with {:ok, paths} <- prepare_paths(id, provider_opts) do
      paths_ready_at = monotonic_us()

      case launch(id, paths, provider_opts) do
        {:ok, port} ->
          launched_at = monotonic_us()

          case boot(paths, provider_opts) do
            {:ok, boot_measurements} ->
              ready_at = monotonic_us()

              {:ok,
               %{
                 id: id,
                 paths: paths,
                 port: port,
                 state: :ready,
                 provider_opts: provider_opts,
                 console: <<>>,
                 measurements:
                   Map.merge(boot_measurements, %{
                     layout_us: paths_ready_at - started_at,
                     spawn_us: launched_at - paths_ready_at,
                     daemon_us: ready_at - started_at
                   })
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
  def handle_call(:measurements, _from, state), do: {:reply, {:ok, state.measurements}, state}

  def handle_call({:capture, key}, _from, %{state: :ready} = state) do
    started_at = monotonic_us()
    api_paths = Snapshot.api_paths(Keyword.get(state.provider_opts, :launch, :jailed))

    result =
      with :ok <- Client.patch(state.paths.api, "/vm", %{state: "Paused"}),
           paused_at = monotonic_us(),
           :ok <-
             Client.put(
               state.paths.api,
               "/snapshot/create",
               %{
                 snapshot_type: "Full",
                 snapshot_path: api_paths.state,
                 mem_file_path: api_paths.memory
               },
               @snapshot_api_timeout
             ),
           captured_at = monotonic_us(),
           :ok <-
             Snapshot.publish(state.id, key, state.paths.snapshot_output, state.provider_opts),
           published_at = monotonic_us() do
        {:ok,
         %{
           pause_us: paused_at - started_at,
           capture_us: captured_at - paused_at,
           publish_us: published_at - captured_at
         }}
      end

    case result do
      {:ok, measurements} ->
        {:reply, {:ok, measurements},
         %{
           state
           | state: :paused,
             measurements: Map.merge(state.measurements, measurements)
         }}

      {:error, reason} ->
        _ = Client.patch(state.paths.api, "/vm", %{state: "Resumed"})
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({_port, {:data, data}}, state) do
    console = state.console <> data
    keep = min(byte_size(console), 64 * 1024)
    {:noreply, %{state | console: binary_part(console, byte_size(console) - keep, keep)}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.error([
      "Firecracker exited with status ",
      Integer.to_string(status),
      ":\n",
      state.console
    ])

    {:stop, {:firecracker_exit, status}, %{state | state: :failed}}
  end

  @impl true
  def terminate(_reason, state) do
    if Map.get(state, :port), do: close_port(state.port)
    if Map.get(state, :paths), do: Helper.cleanup(state.id, state.paths, state)
    :ok
  end

  defp prepare_paths(id, opts) do
    case Keyword.get(opts, :launch, :jailed) do
      :jailed ->
        with {:ok, paths} <- Helper.layout(id, opts) do
          {:ok,
           Map.merge(paths, %{
             snapshot_output: Snapshot.host_output_paths(paths.root)
           })}
        end

      :direct ->
        root = Keyword.fetch!(opts, :work_root)

        if valid_id?(id) and Path.type(root) == :absolute do
          firecracker = absolute_regular!(opts, :firecracker)
          kernel = absolute_regular!(opts, :kernel)
          initramfs = absolute_regular!(opts, :initramfs)
          directory = Path.join(root, id)

          with :ok <- File.mkdir_p(directory) do
            vsock = Path.join(directory, "vsock.sock")
            snapshot_key = Keyword.get(opts, :snapshot_key)

            with :ok <- maybe_stage_snapshot(snapshot_key, directory, opts) do
              {:ok,
               %{
                 root: directory,
                 api: Path.join(directory, "api.sock"),
                 vsock: vsock,
                 vsock_api: "vsock.sock",
                 firecracker: firecracker,
                 kernel: kernel,
                 initramfs: initramfs,
                 cgroup: Keyword.get(opts, :cgroup),
                 snapshot_output: Snapshot.direct_output_paths(directory)
               }}
            end
          end
        else
          {:error, :invalid_firecracker_path}
        end
    end
  rescue
    KeyError -> {:error, :missing_firecracker_path}
    ArgumentError -> {:error, :invalid_firecracker_path}
  end

  defp maybe_stage_snapshot(nil, _root, _opts), do: :ok
  defp maybe_stage_snapshot(key, root, opts), do: Snapshot.stage(key, root, opts)

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
         :ok <- configure_network(paths, opts),
         :ok <- Client.put(paths.api, "/actions", %{action_type: "InstanceStart"}) do
      :ok
    end
  end

  defp configure_network(paths, opts) do
    if Keyword.get(opts, :network, false) do
      Client.put(paths.api, "/network-interfaces/eth0", %{
        iface_id: "eth0",
        guest_mac: "06:00:ac:1e:00:02",
        host_dev_name: "tap0"
      })
    else
      :ok
    end
  end

  defp boot(paths, opts) do
    started_at = monotonic_us()

    with :ok <- wait_for_socket(paths.api, @boot_timeout),
         api_ready_at = monotonic_us(),
         :ok <- configure_or_restore(paths, opts) do
      booted_at = monotonic_us()
      phase = if Keyword.has_key?(opts, :snapshot_key), do: :restore_us, else: :configure_us

      {:ok, %{phase => booted_at - api_ready_at, api_ready_us: api_ready_at - started_at}}
    end
  end

  defp configure_or_restore(paths, opts) do
    case Keyword.get(opts, :snapshot_key) do
      nil -> configure(paths, opts)
      _key -> restore(paths, opts)
    end
  end

  defp restore(paths, opts) do
    snapshot = Snapshot.restore_api_paths(Keyword.get(opts, :launch, :jailed))

    body = %{
      snapshot_path: snapshot.state,
      mem_backend: %{backend_type: "File", backend_path: snapshot.memory},
      track_dirty_pages: false,
      resume_vm: true,
      clock_realtime: true
    }

    Client.put(paths.api, "/snapshot/load", body)
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

  defp monotonic_us, do: System.monotonic_time(:microsecond)

  defp via(id), do: {:via, Registry, {AgentOS.SidecarRegistry, {:firecracker_daemon, id}}}
end
