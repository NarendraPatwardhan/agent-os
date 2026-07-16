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
  def measurements(id), do: GenServer.call(via(id), :measurements)
  def prepare_snapshot(id), do: GenServer.call(via(id), :prepare_snapshot, @connect_timeout)

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)

    contract = %{
      kind: Keyword.fetch!(opts, :kind),
      version: Keyword.fetch!(opts, :version),
      digest: Keyword.fetch!(opts, :contract_digest)
    }

    init_body = Keyword.fetch!(opts, :init_body)

    with {:ok, path} <- AgentOS.Sidecars.Firecracker.Daemon.socket(id),
         {:ok, socket, metadata, measurements} <-
           connect(path, contract, init_body, @connect_timeout) do
      {:ok,
       %{
         path: path,
         socket: socket,
         metadata: metadata,
         measurements: measurements,
         init_body: init_body,
         contract: contract,
         serial: 0,
         current: nil,
         pending: :queue.new()
       }}
    else
      {:error, reason} ->
        diagnostics = diagnostics(id)

        IO.binwrite(:stderr, [
          "Firecracker runner failed during vsock startup:\n",
          diagnostics,
          "\n"
        ])

        {:stop, {reason, diagnostics}}
    end
  end

  @impl true
  def handle_call(:metadata, _from, state), do: {:reply, {:ok, state.metadata}, state}
  def handle_call(:measurements, _from, state), do: {:reply, {:ok, state.measurements}, state}

  def handle_call(:prepare_snapshot, _from, %{current: nil} = state) do
    result = prepare_snapshot(state.socket, state.contract, @connect_timeout)
    close_socket(state.socket)
    {:reply, result, %{state | socket: nil}}
  end

  def handle_call(:prepare_snapshot, _from, state), do: {:reply, {:error, :sidecar_in_use}, state}

  def handle_call({:invoke, call_ref, operation, body, timeout}, from, state) do
    request_id = "rq_" <> Integer.to_string(state.serial + 1, 36)

    entry = %{
      call_ref: call_ref,
      from: from,
      request_id: request_id,
      operation: operation,
      body: body,
      deadline: System.monotonic_time(:millisecond) + timeout
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
    reconnect_after_call(%{state | current: nil})
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
    next = %{state | current: nil}

    case result do
      {:reply, reply} ->
        GenServer.reply(current.from, reply)
        {:noreply, start_next(next)}

      {:disconnect, reply} ->
        GenServer.reply(current.from, reply)
        reconnect_after_call(next)
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current: %{task: %{ref: ref}} = current} = state
      ) do
    GenServer.reply(current.from, {:error, {:runner_exit, reason}})
    reconnect_after_call(%{state | current: nil})
  end

  def handle_info({_ref, _result}, state), do: {:noreply, state}
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.current, do: Task.shutdown(state.current.task, :brutal_kill)
    close_socket(state.socket)
    :ok
  end

  defp start_entry(state, entry) do
    timeout = entry.deadline - System.monotonic_time(:millisecond)

    if timeout <= 0 do
      GenServer.reply(entry.from, {:error, :timeout})
      start_next(state)
    else
      socket = state.socket

      task =
        Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fn ->
          frame =
            Runner.encode_runner_request(%{
              request_id: entry.request_id,
              kind: state.contract.kind,
              operation: entry.operation,
              body: entry.body,
              timeout_ms: timeout
            })

          result =
            with :ok <- write_frame(socket, frame),
                 {:ok, response_frame} <- read_frame(socket, timeout),
                 {:ok, response} <- Runner.decode_runner_response(response_frame),
                 true <-
                   response.request_id == entry.request_id || {:error, :runner_response_mismatch} do
              if response.ok,
                do: {:ok, response.body},
                else: {:error, {:runner, response.error_code, response.error_message}}
            end

          case result do
            {:ok, _body} = reply -> {:reply, reply}
            {:error, {:runner, _code, _message}} = reply -> {:reply, reply}
            {:error, _reason} = reply -> {:disconnect, reply}
          end
        end)

      %{state | current: Map.put(entry, :task, task)}
    end
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

  defp reconnect_after_call(state) do
    close_socket(state.socket)

    case connect(state.path, state.contract, state.init_body, @connect_timeout) do
      {:ok, socket, metadata, measurements} ->
        {:noreply,
         start_next(%{state | socket: socket, metadata: metadata, measurements: measurements})}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  defp close_socket(nil), do: :ok
  defp close_socket(socket), do: :gen_tcp.close(socket)

  defp connect(path, contract, init_body, timeout) do
    started_at = monotonic_us()
    deadline = System.monotonic_time(:millisecond) + timeout
    connect_loop(path, contract, init_body, started_at, deadline)
  end

  defp connect_loop(path, contract, init_body, started_at, deadline) do
    connect_timeout = min(1_000, remaining_timeout(deadline))

    case :gen_tcp.connect(
           {:local, String.to_charlist(path)},
           0,
           [:binary, active: false, packet: :raw],
           connect_timeout
         ) do
      {:ok, socket} ->
        result =
          with :ok <-
                 :gen_tcp.send(socket, "CONNECT #{Runner.runner_default_vsock_port()}\n"),
               {:ok, line} <- read_line(socket, <<>>, 64, deadline),
               true <- String.starts_with?(line, "OK ") || {:error, :vsock_rejected},
               connected_at = monotonic_us(),
               {:ok, hello_frame} <- read_frame(socket, remaining_timeout(deadline)),
               {:ok, hello} <- Runner.decode_runner_hello(hello_frame),
               true <-
                 hello.protocol_version == Runner.protocol_version() ||
                   {:error, :runner_version},
               true <- hello.kind == contract.kind || {:error, :runner_capability_mismatch},
               true <- hello.version == contract.version || {:error, :runner_version_mismatch},
               true <-
                 hello.contract_digest == contract.digest ||
                   {:error, :runner_contract_mismatch},
               hello_at = monotonic_us(),
               {:ok, metadata} <- initialize(socket, contract, init_body, hello_frame, deadline) do
            initialized_at = monotonic_us()

            {:ok, socket, metadata,
             %{
               vsock_connect_us: connected_at - started_at,
               hello_us: hello_at - connected_at,
               initialize_us: initialized_at - hello_at,
               relay_us: initialized_at - started_at
             }}
          end

        case result do
          {:ok, _socket, _metadata, _measurements} = ok ->
            ok

          {:error, reason} ->
            :gen_tcp.close(socket)

            if retryable_handshake?(reason) and
                 System.monotonic_time(:millisecond) < deadline do
              Process.sleep(10)
              connect_loop(path, contract, init_body, started_at, deadline)
            else
              {:error, {:vsock_handshake, reason}}
            end
        end

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          connect_loop(path, contract, init_body, started_at, deadline)
        else
          {:error, {:vsock_connect, reason}}
        end
    end
  end

  defp retryable_handshake?(reason),
    do: reason in [:vsock_rejected, :timeout, :closed, :econnrefused]

  defp diagnostics(id) do
    AgentOS.Sidecars.Firecracker.Daemon.diagnostics(id)
  catch
    :exit, _reason -> <<>>
  end

  defp initialize(_socket, _contract, <<>>, hello_frame, _deadline), do: {:ok, hello_frame}

  defp initialize(socket, contract, body, _hello_frame, deadline) do
    request_id = "init"
    timeout = remaining_timeout(deadline)

    frame =
      Runner.encode_runner_request(%{
        request_id: request_id,
        kind: contract.kind,
        operation: Runner.runner_init_operation(),
        body: body,
        timeout_ms: timeout
      })

    with :ok <- write_frame(socket, frame),
         {:ok, response_frame} <- read_frame(socket, remaining_timeout(deadline)),
         {:ok, response} <- Runner.decode_runner_response(response_frame),
         true <- response.request_id == request_id || {:error, :runner_response_mismatch},
         true <- response.ok || {:error, {:runner, response.error_code, response.error_message}} do
      {:ok, response.body}
    end
  end

  defp prepare_snapshot(socket, contract, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    request_id = "snapshot"

    frame =
      Runner.encode_runner_request(%{
        request_id: request_id,
        kind: contract.kind,
        operation: Runner.runner_prepare_snapshot_operation(),
        body: <<>>,
        timeout_ms: timeout
      })

    with :ok <- write_frame(socket, frame),
         {:ok, response_frame} <- read_frame(socket, remaining_timeout(deadline)),
         {:ok, response} <- Runner.decode_runner_response(response_frame),
         true <- response.request_id == request_id || {:error, :runner_response_mismatch},
         true <- response.ok || {:error, {:runner, response.error_code, response.error_message}},
         <<>> <- response.body,
         {:error, :closed} <- :gen_tcp.recv(socket, 0, remaining_timeout(deadline)) do
      :ok
    else
      _other -> {:error, :firecracker_snapshot_quiesce_failed}
    end
  end

  defp read_line(_socket, acc, 0, _deadline), do: {:error, {:invalid_vsock_handshake, acc}}

  defp read_line(socket, acc, remaining, deadline) do
    case :gen_tcp.recv(socket, 1, remaining_timeout(deadline)) do
      {:ok, "\n"} -> {:ok, acc}
      {:ok, byte} -> read_line(socket, acc <> byte, remaining - 1, deadline)
      error -> error
    end
  end

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 1)
  end

  defp write_frame(socket, frame) do
    if byte_size(frame) <= Runner.runner_max_frame_bytes(),
      do: :gen_tcp.send(socket, <<byte_size(frame)::unsigned-big-32, frame::binary>>),
      else: {:error, :runner_frame_too_large}
  end

  defp read_frame(socket, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, <<length::unsigned-big-32>>} <-
           :gen_tcp.recv(socket, 4, remaining_timeout(deadline)),
         true <-
           length in 1..Runner.runner_max_frame_bytes() ||
             {:error, :runner_frame_too_large},
         {:ok, frame} <- :gen_tcp.recv(socket, length, remaining_timeout(deadline)) do
      {:ok, frame}
    end
  end

  defp monotonic_us, do: System.monotonic_time(:microsecond)

  defp via(id), do: {:via, Registry, {AgentOS.SidecarRegistry, {:firecracker_relay, id}}}
end
