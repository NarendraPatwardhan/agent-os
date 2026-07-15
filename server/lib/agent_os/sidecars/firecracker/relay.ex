defmodule AgentOS.Sidecars.Firecracker.Relay do
  @moduledoc false
  use GenServer, restart: :transient

  alias AgentOS.Contracts.Runner

  @connect_timeout 15_000

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def invoke(id, call_ref, operation, body, timeout),
    do: GenServer.call(via(id), {:invoke, call_ref, operation, body, timeout}, timeout + 1_000)

  def cancel(id, call_ref), do: GenServer.cast(via(id), {:cancel, call_ref})
  def metadata(id), do: GenServer.call(via(id), :metadata)

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    contract = %{
      kind: Keyword.fetch!(opts, :kind),
      version: Keyword.fetch!(opts, :version),
      digest: Keyword.fetch!(opts, :contract_digest)
    }

    with {:ok, path} <- AgentOS.Sidecars.Firecracker.Daemon.socket(id),
         {:ok, socket, metadata} <- connect(path, contract, @connect_timeout) do
      {:ok,
       %{
         path: path,
         socket: socket,
         metadata: metadata,
         contract: contract,
         serial: 0,
         current: nil,
         pending: :queue.new()
       }}
    else
      {:error, reason} ->
        diagnostics = AgentOS.Sidecars.Firecracker.Daemon.diagnostics(id)
        IO.binwrite(:stderr, ["Firecracker runner failed during vsock startup:\n", diagnostics, "\n"])
        {:stop, {reason, diagnostics}}
    end
  end

  @impl true
  def handle_call(:metadata, _from, state), do: {:reply, {:ok, state.metadata}, state}

  def handle_call({:invoke, call_ref, operation, body, timeout}, from, state) do
    request_id = "rq_" <> Integer.to_string(state.serial + 1, 36)

    entry = %{
      call_ref: call_ref,
      from: from,
      request_id: request_id,
      operation: operation,
      body: body,
      timeout: timeout
    }

    next = %{state | serial: state.serial + 1}

    if state.current do
      {:noreply, %{next | pending: :queue.in(entry, state.pending)}}
    else
      {:noreply, start_entry(next, entry)}
    end
  end

  @impl true
  def handle_cast({:cancel, call_ref}, %{current: %{call_ref: call_ref} = current} = state) do
    Task.shutdown(current.task, :brutal_kill)
    GenServer.reply(current.from, {:error, :cancelled})
    :gen_tcp.close(state.socket)

    case connect(state.path, state.contract, @connect_timeout) do
      {:ok, socket, metadata} ->
        {:noreply,
         start_next(%{state | socket: socket, metadata: metadata, current: nil})}

      {:error, reason} -> {:stop, reason, %{state | current: nil}}
    end
  end

  def handle_cast({:cancel, call_ref}, state) do
    {removed, pending} = remove_pending(state.pending, call_ref)
    if removed, do: GenServer.reply(removed.from, {:error, :cancelled})
    {:noreply, %{state | pending: pending}}
  end

  @impl true
  def handle_info({ref, result}, %{current: %{task: %{ref: ref}} = current} = state)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    GenServer.reply(current.from, result)
    {:noreply, start_next(%{state | current: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current: %{task: %{ref: ref}} = current} = state) do
    GenServer.reply(current.from, {:error, {:runner_exit, reason}})
    {:noreply, start_next(%{state | current: nil})}
  end

  def handle_info({_ref, _result}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.current, do: Task.shutdown(state.current.task, :brutal_kill)
    :gen_tcp.close(state.socket)
    :ok
  end

  defp start_entry(state, entry) do
    socket = state.socket

    task =
      Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fn ->
        frame =
          Runner.encode_runner_request(%{
            request_id: entry.request_id,
            kind: state.contract.kind,
            operation: entry.operation,
            body: entry.body,
            timeout_ms: entry.timeout
          })

        with :ok <- write_frame(socket, frame),
             {:ok, response_frame} <- read_frame(socket, entry.timeout),
             {:ok, response} <- Runner.decode_runner_response(response_frame),
             true <-
               response.request_id == entry.request_id || {:error, :runner_response_mismatch} do
          if response.ok,
            do: {:ok, response.body},
            else: {:error, {:runner, response.error_code, response.error_message}}
        end
      end)

    %{state | current: Map.put(entry, :task, task)}
  end

  defp start_next(state) do
    case :queue.out(state.pending) do
      {{:value, entry}, pending} -> start_entry(%{state | pending: pending}, entry)
      {:empty, _pending} -> state
    end
  end

  defp remove_pending(queue, call_ref) do
    items = :queue.to_list(queue)
    removed = Enum.find(items, &(&1.call_ref == call_ref))
    kept = Enum.reject(items, &(&1.call_ref == call_ref))
    {removed, :queue.from_list(kept)}
  end

  defp connect(path, contract, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    connect_loop(path, contract, deadline)
  end

  defp connect_loop(path, contract, deadline) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(path)},
           0,
           [:binary, active: false, packet: :raw],
           1_000
         ) do
      {:ok, socket} ->
        result =
          with :ok <-
                 :gen_tcp.send(socket, "CONNECT #{Runner.runner_default_vsock_port()}\n"),
               {:ok, line} <- read_line(socket, <<>>, 64),
               true <- String.starts_with?(line, "OK ") || {:error, :vsock_rejected},
               {:ok, hello_frame} <- read_frame(socket, 1_000),
               {:ok, hello} <- Runner.decode_runner_hello(hello_frame),
               true <-
                 hello.protocol_version == Runner.protocol_version() ||
                   {:error, :runner_version},
               true <- hello.kind == contract.kind || {:error, :runner_capability_mismatch},
               true <- hello.version == contract.version || {:error, :runner_version_mismatch},
               true <-
                 hello.contract_digest == contract.digest ||
                   {:error, :runner_contract_mismatch} do
            {:ok, socket, hello_frame}
          end

        case result do
          {:ok, _socket, _metadata} = ok ->
            ok

          {:error, reason} ->
            :gen_tcp.close(socket)

            if System.monotonic_time(:millisecond) < deadline do
              Process.sleep(10)
              connect_loop(path, contract, deadline)
            else
              {:error, {:vsock_handshake, reason}}
            end
        end

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          connect_loop(path, contract, deadline)
        else
          {:error, {:vsock_connect, reason}}
        end
    end
  end

  defp read_line(_socket, acc, 0), do: {:error, {:invalid_vsock_handshake, acc}}

  defp read_line(socket, acc, remaining) do
    case :gen_tcp.recv(socket, 1, 1_000) do
      {:ok, "\n"} -> {:ok, acc}
      {:ok, byte} -> read_line(socket, acc <> byte, remaining - 1)
      error -> error
    end
  end

  defp write_frame(socket, frame) do
    if byte_size(frame) <= Runner.runner_max_frame_bytes(),
      do: :gen_tcp.send(socket, <<byte_size(frame)::unsigned-big-32, frame::binary>>),
      else: {:error, :runner_frame_too_large}
  end

  defp read_frame(socket, timeout) do
    with {:ok, <<length::unsigned-big-32>>} <- :gen_tcp.recv(socket, 4, timeout),
         true <-
           length in 1..Runner.runner_max_frame_bytes() ||
             {:error, :runner_frame_too_large},
         {:ok, frame} <- :gen_tcp.recv(socket, length, timeout) do
      {:ok, frame}
    end
  end

  defp via(id), do: {:via, Registry, {AgentOS.SidecarRegistry, {:firecracker_relay, id}}}
end
