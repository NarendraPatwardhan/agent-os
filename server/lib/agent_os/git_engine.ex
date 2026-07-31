defmodule AgentOS.GitEngine do
  @moduledoc """
  BEAM-owned Port to the native C `git-engine` process (GIT.md PR7a–PR10c).

  Length-prefixed frames on the child's stdin/stdout:

      <<length::little-32, type::8, payload::binary-size(length-1)>>

  Types: 1 Run, 2 pack chunk, 3 pack meta, 4 binary MOUNT_OP, 5 remote orch.

  Lifecycle: start when a gitfs mount attaches (or explicitly); stop with the VM.
  Port exit fails subsequent ops closed (`:eio`).
  """

  use GenServer

  @type state :: %{
          optional(:port) => port(),
          optional(:root) => String.t(),
          optional(:mount_path) => String.t(),
          optional(:executable) => String.t(),
          buffer: binary()
        }

  @frame_run 1
  @frame_pack 2
  @frame_pack_meta 3
  @frame_mount 4
  @frame_remote 5

  # ── public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Start unlinked (preferred from AgentOS.Vm so engine crash does not take down the VM)."
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts \\ []) do
    GenServer.start(__MODULE__, opts)
  end

  @doc "JSON Run (`ge_run_json`). Local ops only; remotes use `remote/2`."
  @spec run(pid(), String.t() | map()) :: {:ok, map()} | {:error, term()}
  def run(pid, request) when is_pid(pid) do
    json = if is_binary(request), do: request, else: encode_request(request)
    GenServer.call(pid, {:run, json}, 60_000)
  end

  @doc "Binary pack import chunk; `final: true` finalizes the indexer."
  @spec import_pack(pid(), binary(), keyword()) :: :ok | {:error, term()}
  def import_pack(pid, chunk, opts \\ []) when is_pid(pid) and is_binary(chunk) do
    GenServer.call(pid, {:import_pack, chunk, Keyword.get(opts, :final, false)}, 60_000)
  end

  @doc "Binary MOUNT_OP body (peer of dispatchMount). Returns response bytes."
  @spec mount_op(pid(), binary()) :: {:ok, binary()} | {:error, term()}
  def mount_op(pid, body) when is_pid(pid) and is_binary(body) do
    GenServer.call(pid, {:mount_op, body}, 60_000)
  end

  @doc "Remote orch entry (clone/fetch) — C smart-HTTP + apply (PR10c)."
  @spec remote(pid(), String.t() | map()) :: {:ok, map()} | {:error, term()}
  def remote(pid, request) when is_pid(pid) do
    json = if is_binary(request), do: request, else: encode_request(request)
    GenServer.call(pid, {:remote, json}, 120_000)
  end

  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid), do: GenServer.stop(pid, :normal, 5_000)

  @spec alive?(pid()) :: boolean()
  def alive?(pid) when is_pid(pid) do
    GenServer.call(pid, :alive?) == :ok
  rescue
    _ -> false
  end

  @doc """
  Route a relayed host_call to this engine (PR7b / PR10c demux helper).

  * `name == "git"` → remote orch (type 5)
  * `name` equals `mount_path` → binary MOUNT_OP (type 4)

  Connection-bound remotes (`args.connection` / credential splice) are the JS
  orchestrator path (PR11). The C Port path accepts public URL remotes only and
  refuses connection refs so secrets are never expected here.
  """
  @spec handle_host_call(pid(), String.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def handle_host_call(pid, "git", body) when is_pid(pid) and is_binary(body) do
    if connection_bound_request?(body) do
      {:ok,
       ~s({"ok":false,"code":1,"stdout":"","stderr":"git: connection-bound remotes require JS orchestrator (PR11); use public url on server Port"})}
    else
      case remote(pid, body) do
        {:ok, map} when is_map(map) ->
          raw = Map.get(map, "raw")
          if is_binary(raw), do: {:ok, raw}, else: {:ok, encode_request(map)}

        {:error, _} = err ->
          err
      end
    end
  end

  def handle_host_call(pid, name, body) when is_pid(pid) and is_binary(name) and is_binary(body) do
    case GenServer.call(pid, :mount_path, 5_000) do
      path when is_binary(path) and path == name ->
        mount_op(pid, body)

      _ ->
        {:error, :not_git}
    end
  rescue
    _ -> {:error, :eio}
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    executable =
      Keyword.get(opts, :executable) ||
        System.get_env("AGENTOS_GIT_ENGINE") ||
        default_executable()

    root =
      Keyword.get(opts, :root) ||
        Path.join(System.tmp_dir!(), "agentos-git-" <> Integer.to_string(System.unique_integer([:positive])))

    File.mkdir_p!(root)

    case open_port(executable, root) do
      {:ok, port} ->
        {:ok,
         %{
           port: port,
           root: root,
           mount_path: Keyword.get(opts, :mount_path, "/workspace/repo"),
           executable: executable,
           buffer: <<>>
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:alive?, _from, %{port: port} = state) when is_port(port) do
    {:reply, :ok, state}
  end

  def handle_call(:alive?, _from, state), do: {:reply, {:error, :eio}, state}

  def handle_call(:mount_path, _from, state) do
    {:reply, Map.get(state, :mount_path), state}
  end

  def handle_call(_msg, _from, %{port: nil} = state) do
    {:reply, {:error, :eio}, state}
  end

  def handle_call({:run, json}, _from, state) do
    reply_frame(state, @frame_run, json, &decode_json_response/1)
  end

  def handle_call({:remote, json}, _from, state) do
    reply_frame(state, @frame_remote, json, &decode_json_response/1)
  end

  def handle_call({:import_pack, chunk, final}, _from, state) do
    with {:ok, state1} <- send_frame(state, @frame_pack, chunk),
         {:ok, _status, state2} <- recv_status_frame(state1, @frame_pack) do
      if final do
        with {:ok, state3} <- send_frame(state2, @frame_pack_meta, <<1>>),
             {:ok, st, state4} <- recv_status_frame(state3, @frame_pack_meta) do
          if st == 0, do: {:reply, :ok, state4}, else: {:reply, {:error, :import_pack}, state4}
        end
      else
        {:reply, :ok, state2}
      end
    else
      {:error, reason, st} -> {:reply, {:error, reason}, st}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:mount_op, body}, _from, state) do
    reply_frame(state, @frame_mount, body, fn payload -> {:ok, payload} end)
  end

  @impl true
  def handle_info({port, {:exit_status, _status}}, %{port: port} = state) do
    {:noreply, %{state | port: nil}}
  end

  def handle_info({port, {:data, data}}, %{port: port, buffer: buf} = state)
      when is_binary(data) do
    {:noreply, %{state | buffer: buf <> data}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── framing ─────────────────────────────────────────────────────────────────

  defp open_port(executable, root) do
    if not File.regular?(executable) do
      {:error, {:git_engine_missing, executable}}
    else
      # Do not merge stderr into stdout — ready banner on stderr must not corrupt frames.
      # Stream mode (no {:packet, N}): we own little-endian length framing.
      port =
        Port.open({:spawn_executable, String.to_charlist(executable)}, [
          :binary,
          :exit_status,
          {:args, [~c"--root", String.to_charlist(root)]}
        ])

      {:ok, port}
    end
  rescue
    error -> {:error, {:git_engine_open_failed, error}}
  end

  defp encode_request(map) when is_map(map), do: AgentOS.GitEngine.Jason_like.encode!(map)

  defp connection_bound_request?(body) when is_binary(body) do
    String.contains?(body, "\"connection\"") or String.contains?(body, "\"agentos\"")
  end

  defp reply_frame(state, type, payload, decode) do
    case request_response(state, type, payload) do
      {:ok, resp_payload, state2} ->
        case decode.(resp_payload) do
          {:ok, value} -> {:reply, {:ok, value}, state2}
          {:error, reason} -> {:reply, {:error, reason}, state2}
        end

      {:error, reason, state2} ->
        {:reply, {:error, reason}, state2}
    end
  end

  defp request_response(%{port: nil} = state, _type, _payload),
    do: {:error, :eio, state}

  defp request_response(state, type, payload) do
    with {:ok, state1} <- send_frame(state, type, payload),
         {:ok, _type, resp, state2} <- recv_frame(state1) do
      {:ok, resp, state2}
    end
  end

  defp send_frame(%{port: port} = state, type, payload) when is_port(port) do
    body = IO.iodata_to_binary([<<type::8>>, payload])
    len = byte_size(body)
    frame = <<len::little-32, body::binary>>
    true = Port.command(port, frame)
    {:ok, state}
  rescue
    _ -> {:error, :eio, %{state | port: nil}}
  end

  defp recv_status_frame(state, expect_type) do
    case recv_frame(state) do
      {:ok, ^expect_type, <<st::little-signed-32, _::binary>>, state2} ->
        {:ok, st, state2}

      {:ok, ^expect_type, <<st::little-signed-32>>, state2} ->
        {:ok, st, state2}

      {:ok, _t, _p, state2} ->
        {:error, :bad_frame, state2}

      other ->
        other
    end
  end

  defp recv_frame(state), do: recv_frame(state, 50)

  defp recv_frame(%{buffer: buf} = state, attempts) do
    case take_frame(buf) do
      {:ok, type, payload, rest} ->
        {:ok, type, payload, %{state | buffer: rest}}

      :incomplete when attempts > 0 ->
        receive do
          {port, {:data, data}} when is_port(port) and is_binary(data) ->
            recv_frame(%{state | buffer: buf <> data}, attempts - 1)

          {port, {:exit_status, _}} when is_port(port) ->
            {:error, :eio, %{state | port: nil}}
        after
          2_000 ->
            # Force a Port flush by yielding; some runtimes batch stdout.
            recv_frame(state, attempts - 1)
        end

      :incomplete ->
        {:error, :timeout, state}
    end
  end

  defp take_frame(<<len::little-32, rest::binary>>) when byte_size(rest) >= len and len >= 1 do
    <<type::8, payload::binary-size(len - 1), next::binary>> = rest
    {:ok, type, payload, next}
  end

  defp take_frame(_), do: :incomplete

  defp decode_json_response(payload) when is_binary(payload) do
    # Minimal JSON object extract without Jason dependency: use :json if OTP 27+, else regex ok.
    case safe_json_decode(payload) do
      {:ok, map} when is_map(map) -> {:ok, map}
      other -> other
    end
  end

  defp safe_json_decode(bin) do
    if function_exported?(:json, :decode, 1) do
      case :json.decode(bin) do
        {:ok, term} -> {:ok, json_keys_to_string(term)}
        error -> {:error, error}
      end
    else
      # Fallback: return raw under "raw" if no decoder — tests use :json on OTP 27+.
      {:ok, %{"raw" => bin, "ok" => String.contains?(bin, "\"ok\":true")}}
    end
  end

  defp json_keys_to_string(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), json_keys_to_string(v)}
      {k, v} when is_binary(k) -> {k, json_keys_to_string(v)}
      {k, v} -> {k, json_keys_to_string(v)}
    end)
  end

  defp json_keys_to_string(list) when is_list(list), do: Enum.map(list, &json_keys_to_string/1)
  defp json_keys_to_string(other), do: other

  defp default_executable do
    # Bazel runfiles or release priv layout.
    candidates = [
      System.get_env("AGENTOS_GIT_ENGINE"),
      Path.join(Application.app_dir(:agent_os, "priv"), "git-engine"),
      "memcontainers/lib/git-engine/git-engine"
    ]

    Enum.find(candidates, "git-engine", fn
      nil -> false
      path -> File.regular?(path)
    end)
  end
end

defmodule AgentOS.GitEngine.Jason_like do
  @moduledoc false

  def encode!(map) when is_map(map) do
    if function_exported?(:json, :encode, 1) do
      case :json.encode(map) do
        bin when is_binary(bin) -> bin
        {:ok, bin} -> bin
      end
    else
      # Tiny encoder for %{op, args} maps used by tests.
      op = Map.get(map, :op) || Map.get(map, "op") || ""
      args = Map.get(map, :args) || Map.get(map, "args")

      if args do
        ~s({"op":"#{op}","args":#{encode_value(args)}})
      else
        ~s({"op":"#{op}"})
      end
    end
  end

  defp encode_value(map) when is_map(map) do
    parts =
      Enum.map(map, fn {k, v} ->
        key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
        ~s("#{key}":#{encode_value(v)})
      end)

    "{" <> Enum.join(parts, ",") <> "}"
  end

  defp encode_value(s) when is_binary(s), do: ~s("#{s}")
  defp encode_value(n) when is_integer(n), do: Integer.to_string(n)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(nil), do: "null"
  defp encode_value(other), do: ~s("#{inspect(other)}")
end
