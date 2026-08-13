defmodule AgentOS.GitEngine do
  @moduledoc """
  Owns one native Gitz Port and one engine session.

  The Port carrier is deliberately trivial: a little-endian `u32` byte length
  followed by exactly one generated `AOGQ` or `AOGR` envelope. Git operations,
  repository state, mounts, packs, and remote state machines all remain in the
  engine. BEAM owns the child process, durable root placement, credentials, and
  HTTP effects requested by the engine.
  """

  use GenServer

  alias AgentOS.Contracts.Git
  alias AgentOS.Git.Durable

  @backend_native Git.backend_native()
  @request_timeout 120_000
  @status_ok Git.status_ok()
  @status_effect Git.status_effect()
  @max_frame_bytes Git.max_frame_bytes()

  @type response :: %{
          required(:opcode) => non_neg_integer(),
          required(:request_id) => non_neg_integer(),
          required(:status) => non_neg_integer(),
          required(:payload) => binary()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []), do: GenServer.start(__MODULE__, opts)

  @spec stop(pid()) :: :ok
  def stop(pid), do: GenServer.stop(pid, :normal, 5_000)

  @spec alive?(pid()) :: boolean()
  def alive?(pid) do
    GenServer.call(pid, :alive?, 5_000) == :ok
  catch
    :exit, _ -> false
  end

  @spec root(pid()) :: String.t() | nil
  def root(pid), do: safe_metadata_call(pid, :root)

  @spec executable(pid()) :: String.t() | nil
  def executable(pid), do: safe_metadata_call(pid, :executable)

  @doc "Execute one typed engine operation and return its decoded response envelope."
  @spec request(pid(), non_neg_integer(), binary(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(pid, opcode, payload \\ <<>>, opts \\ [])
      when is_pid(pid) and is_integer(opcode) and opcode >= 0 and is_binary(payload) and
             is_list(opts) do
    GenServer.call(pid, {:request, opcode, payload, opts}, @request_timeout)
  catch
    :exit, reason -> {:error, {:port_exit, reason}}
  end

  @doc "Ask the engine to durably checkpoint its repository state."
  @spec checkpoint(pid()) :: :ok | {:error, term()}
  def checkpoint(pid) do
    with {:ok, %{status: status}} when status == @status_ok <-
           request(pid, Git.op_checkpoint()) do
      :ok
    else
      {:ok, response} -> {:error, {:engine, response}}
      {:error, _} = error -> error
    end
  end

  @impl true
  def init(opts) do
    executable =
      Keyword.get(opts, :executable) || System.get_env("AGENTOS_GIT_ENGINE") ||
        default_executable()

    with {:ok, root, kind} <- Durable.resolve_root(opts),
         root <- Durable.ensure_root!(root),
         {:ok, port} <- open_port(executable) do
      state = %{
        port: port,
        root: root,
        mount_path: Keyword.get(opts, :mount_path, "/workspace/repo"),
        executable: executable,
        temp_root?: kind == :temp,
        read_only: Keyword.get(opts, :read_only, false) == true,
        buffer: <<>>,
        next_request_id: 1,
        host_opts: host_opts(opts)
      }

      case transact(state, Git.op_session_open(), session_config(state)) do
        {:ok, %{status: status}, state2} when status == @status_ok -> {:ok, state2}
        {:ok, response, state2} -> {:stop, {:session_open_failed, response}, state2}
        {:error, reason, state2} -> {:stop, reason, state2}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  rescue
    error -> {:stop, {:git_engine_start_failed, error}}
  end

  @impl true
  def handle_call(:alive?, _from, %{port: port} = state) when is_port(port),
    do: {:reply, :ok, state}

  def handle_call(:alive?, _from, state), do: {:reply, {:error, :eio}, state}
  def handle_call(:root, _from, state), do: {:reply, state.root, state}
  def handle_call(:mount_path, _from, state), do: {:reply, state.mount_path, state}
  def handle_call(:executable, _from, state), do: {:reply, state.executable, state}

  def handle_call(_request, _from, %{port: nil} = state),
    do: {:reply, {:error, :eio}, state}

  def handle_call({:request, opcode, payload, opts}, _from, state) do
    case transact_effects(state, opcode, payload, Keyword.merge(state.host_opts, opts)) do
      {:ok, response, state2} -> {:reply, {:ok, response}, state2}
      {:error, reason, state2} -> {:reply, {:error, reason}, state2}
    end
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:noreply, %{state | port: nil}}

  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: {:noreply, %{state | buffer: state.buffer <> data}}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_port(Map.get(state, :port)), do: Port.close(state.port)
    maybe_remove_temp_root(Map.get(state, :root), Map.get(state, :temp_root?, false))
    :ok
  end

  defp transact_effects(state, opcode, payload, opts) do
    case transact(state, opcode, payload) do
      {:ok, %{status: status} = response, state2} when status == @status_effect ->
        continue_effect(state2, response, opts)

      other ->
        other
    end
  end

  defp continue_effect(state, response, opts) do
    with {:ok, effect} <- Git.decode_http_effect(response.payload),
         {:ok, request_body, state2} <- drain_effect_body(state, effect.body) do
      result =
        AgentOS.Git.Http.stream(
          effect,
          request_body,
          opts,
          state2,
          &consume_http_event(response, &1, &2)
        )

      cleanup_body_source(request_body)

      case result do
        {:ok, state3} ->
          with {:ok, final, state4} <- finish_http_effect(state3, response) do
            if final.status == @status_effect,
              do: continue_effect(state4, final, opts),
              else: {:ok, final, state4}
          end

        {:halt, final, state3} ->
          {:ok, final, state3}

        {:error, reason, state3} ->
          abort_effect(state3, response, reason, opts)
      end
    else
      {:error, reason, state2} ->
        abort_effect(state2, response, reason, opts)

      {:error, reason} ->
        abort_effect(state, response, reason, opts)
    end
  end

  defp consume_http_event(pending, {:begin, status, headers}, state) do
    message = %{
      exchange: effect_exchange(pending.payload),
      action: Git.http_response_begin(),
      status: status,
      headers: headers,
      data: nil,
      error_code: nil
    }

    case acknowledge_http_effect(state, pending, message) do
      {:ok, state2} -> {:cont, state2}
      {:terminal, response, state2} -> {:halt, response, state2}
      {:error, reason, state2} -> {:error, reason, state2}
    end
  end

  defp consume_http_event(pending, {:chunk, bytes}, state) do
    message = %{
      exchange: effect_exchange(pending.payload),
      action: Git.http_response_chunk(),
      status: nil,
      headers: %{},
      data: bytes,
      error_code: nil
    }

    case acknowledge_http_effect(state, pending, message) do
      {:ok, state2} -> {:cont, state2}
      {:terminal, response, state2} -> {:halt, response, state2}
      {:error, reason, state2} -> {:error, reason, state2}
    end
  end

  defp finish_http_effect(state, pending) do
    message = %{
      exchange: effect_exchange(pending.payload),
      action: Git.http_response_end(),
      status: nil,
      headers: %{},
      data: nil,
      error_code: nil
    }

    send_http_effect(state, pending, message, :terminal)
  end

  defp abort_effect(state, pending, reason, opts) do
    message = %{
      exchange: effect_exchange(pending.payload),
      action: Git.http_response_abort(),
      status: nil,
      headers: %{},
      data: nil,
      error_code: http_error_code(reason)
    }

    case send_http_effect(state, pending, message, :terminal) do
      {:ok, %{status: @status_effect} = response, state2} ->
        continue_effect(state2, response, opts)

      other ->
        other
    end
  end

  defp acknowledge_http_effect(state, pending, message) do
    case send_http_effect(state, pending, message, :ack) do
      {:ok, %{opcode: opcode} = response, state2} when opcode == pending.opcode ->
        {:terminal, response, state2}

      {:ok, _response, state2} ->
        {:ok, state2}

      {:error, reason, state2} ->
        {:error, reason, state2}
    end
  end

  defp send_http_effect(state, pending, message, phase) do
    payload = Git.encode_http_response(message)

    envelope =
      Git.encode_request_envelope(
        Git.op_http_effect(),
        0,
        pending.request_id,
        payload
      )

    with {:ok, state1} <- send_carrier(state, envelope),
         {:ok, raw, state2} <- receive_carrier(state1),
         {:ok, response} <- Git.decode_response_envelope(raw),
         true <- response.request_id == pending.request_id || {:error, :request_id_mismatch},
         :ok <- validate_http_effect_response(response, pending, phase) do
      response = Map.put(response, :raw, raw)
      {:ok, response, state2}
    else
      {:error, reason, state2} -> {:error, reason, state2}
      {:error, reason} -> {:error, reason, state}
      false -> {:error, :invalid_response, state}
    end
  end

  defp validate_http_effect_response(response, pending, :ack) do
    cond do
      response.opcode == Git.op_http_effect() and response.status == @status_ok -> :ok
      response.opcode == pending.opcode -> :ok
      true -> {:error, :invalid_http_effect_ack}
    end
  end

  defp validate_http_effect_response(response, pending, :terminal) do
    if response.opcode == pending.opcode,
      do: :ok,
      else: {:error, :opcode_mismatch}
  end

  defp drain_effect_body(state, nil), do: {:ok, <<>>, state}

  defp drain_effect_body(state, handle) when is_integer(handle) and handle > 0 do
    path = spool_path("request")

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        case drain_effect_body(state, handle, 0, file, path, 0) do
          {:ok, _source, _state} = result ->
            result

          {:error, _reason, _state} = error ->
            File.close(file)
            File.rm(path)
            error
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp drain_effect_body(state, _), do: {:error, :invalid_stream_handle, state}

  defp drain_effect_body(state, handle, offset, file, path, total) do
    payload =
      Git.encode_stream_request(%{
        action: Git.stream_read(),
        handle: handle,
        offset_low: Bitwise.band(offset, 0xFFFFFFFF),
        offset_high: Bitwise.bsr(offset, 32),
        data: nil
      })

    with {:ok, response, state2} <- transact(state, Git.op_stream(), payload),
         true <- response.status == @status_ok || {:error, :stream_read_failed},
         {:ok, chunk} <- Git.decode_stream_chunk(response.payload),
         true <- chunk.handle == handle || {:error, :stream_handle_mismatch},
         true <-
           chunk.offset_low == Bitwise.band(offset, 0xFFFFFFFF) ||
             {:error, :stream_offset_mismatch},
         true <- (chunk.done or byte_size(chunk.data) > 0) || {:error, :stream_stalled},
         next_total <- total + byte_size(chunk.data),
         true <- next_total <= Git.max_pack_bytes() || {:error, :stream_too_large},
         :ok <- IO.binwrite(file, chunk.data) do
      if chunk.done do
        :ok = File.close(file)
        close_stream(state2, handle, {:file, path})
      else
        drain_effect_body(
          state2,
          handle,
          offset + byte_size(chunk.data),
          file,
          path,
          next_total
        )
      end
    else
      {:error, reason, state2} -> {:error, reason, state2}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp close_stream(state, handle, source) do
    payload =
      Git.encode_stream_request(%{
        action: Git.stream_close(),
        handle: handle,
        offset_low: nil,
        offset_high: nil,
        data: nil
      })

    case transact(state, Git.op_stream(), payload) do
      {:ok, %{status: @status_ok}, state2} ->
        {:ok, source, state2}

      {:ok, _, state2} ->
        {:error, :stream_close_failed, state2}

      {:error, reason, state2} ->
        {:error, reason, state2}
    end
  end

  defp cleanup_body_source({:file, path}), do: File.rm(path)
  defp cleanup_body_source(_), do: :ok

  defp spool_path(kind) do
    Path.join(
      System.tmp_dir!(),
      "agentos-git-engine-#{kind}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp transact(state, opcode, payload) do
    request_id = state.next_request_id

    envelope = Git.encode_request_envelope(opcode, 0, request_id, payload)

    transact_raw(state, envelope, %{opcode: opcode, request_id: request_id})
    |> case do
      {:ok, _raw, response, state2} -> {:ok, response, state2}
      {:error, reason, state2} -> {:error, reason, state2}
    end
  end

  defp transact_raw(state, envelope, request) do
    state = %{state | next_request_id: next_id(state.next_request_id)}

    with {:ok, state1} <- send_carrier(state, envelope),
         {:ok, raw, state2} <- receive_carrier(state1),
         {:ok, response} <- Git.decode_response_envelope(raw),
         true <- response.opcode == request.opcode || {:error, :opcode_mismatch},
         true <- response.request_id == request.request_id || {:error, :request_id_mismatch} do
      {:ok, raw, Map.put(response, :raw, raw), state2}
    else
      {:error, reason, state2} -> {:error, reason, state2}
      {:error, reason} -> {:error, reason, state}
      false -> {:error, :invalid_response, state}
    end
  end

  defp send_carrier(%{port: port} = state, envelope) when is_port(port) do
    length = byte_size(envelope)

    if length > @max_frame_bytes do
      {:error, :frame_too_large, state}
    else
      true = Port.command(port, <<length::little-32, envelope::binary>>)
      {:ok, state}
    end
  rescue
    _ -> {:error, :eio, %{state | port: nil}}
  end

  defp receive_carrier(state), do: receive_carrier(state, 120)

  defp receive_carrier(%{buffer: <<length::little-32, rest::binary>>} = state, _attempts)
       when length <= @max_frame_bytes and byte_size(rest) >= length do
    <<frame::binary-size(^length), tail::binary>> = rest
    {:ok, frame, %{state | buffer: tail}}
  end

  defp receive_carrier(%{buffer: <<length::little-32, _::binary>>} = state, _attempts)
       when length > @max_frame_bytes,
       do: {:error, :frame_too_large, state}

  defp receive_carrier(state, 0), do: {:error, :timeout, state}

  defp receive_carrier(%{port: port} = state, attempts) do
    receive do
      {^port, {:data, data}} ->
        receive_carrier(%{state | buffer: state.buffer <> data}, attempts - 1)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}, %{state | port: nil}}
    after
      1_000 -> receive_carrier(state, attempts - 1)
    end
  end

  defp session_config(state) do
    Git.encode_session_config(%{
      backend: @backend_native,
      read_only: state.read_only,
      root: state.root,
      restore: nil
    })
  end

  defp open_port(executable) do
    if File.regular?(executable) do
      {:ok,
       Port.open({:spawn_executable, String.to_charlist(executable)}, [
         :binary,
         :exit_status
       ])}
    else
      {:error, {:git_engine_missing, executable}}
    end
  rescue
    error -> {:error, {:git_engine_open_failed, error}}
  end

  defp host_opts(opts) do
    Keyword.take(opts, [
      :allowed_origins,
      :auth,
      :connections,
      :policies,
      :http_effect,
      :http_executor,
      :max_response_bytes,
      :remote_binding,
      :remote_bindings
    ])
  end

  defp effect_exchange(payload) do
    case Git.decode_http_effect(payload) do
      {:ok, %{exchange: exchange}} -> exchange
      _ -> 0
    end
  end

  defp http_error_code(:origin_not_allowed), do: 1
  defp http_error_code(:body_too_large), do: 2
  defp http_error_code(:redirect_not_allowed), do: 3
  defp http_error_code(_), do: 255

  defp next_id(0xFFFFFFFF), do: 1
  defp next_id(value), do: value + 1

  defp safe_metadata_call(pid, message) do
    GenServer.call(pid, message, 5_000)
  catch
    :exit, _ -> nil
  end

  defp maybe_remove_temp_root(root, true) when is_binary(root) do
    temp = Path.expand(System.tmp_dir!())
    expanded = Path.expand(root)

    if String.starts_with?(expanded, temp <> "/") and
         String.starts_with?(Path.basename(expanded), "agentos-git-") do
      File.rm_rf(expanded)
    end

    :ok
  end

  defp maybe_remove_temp_root(_, _), do: :ok

  defp default_executable do
    candidates = [
      Path.expand("priv/git-engine", File.cwd!()),
      Path.expand("../memcontainers/lib/git-engine/git-engine", File.cwd!())
    ]

    Enum.find(candidates, &File.regular?/1) || hd(candidates)
  end
end
