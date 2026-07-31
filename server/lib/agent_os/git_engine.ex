defmodule AgentOS.GitEngine do
  @moduledoc """
  BEAM-owned Port to the native C `git-engine` process (GIT.md PR7+).

  Length-prefixed frames on the child's stdin/stdout:

      <<length::little-32, type::8, payload::binary-size(length-1)>>

  Types: 1 Run, 2 pack chunk, 3 pack meta, 4 binary MOUNT_OP.
  Type 5 is legacy/test-only; product remotes use BEAM HTTPS orch (see
  `AgentOS.Git.Orchestrator`) then Port apply frames.

  Lifecycle: start when a gitfs mount attaches (or explicitly); stop with the VM.
  Port exit fails subsequent ops closed (`:eio`). Engine never dials the network.
  """

  use GenServer

  @type identity :: %{required(:name) => String.t(), required(:email) => String.t()}

  @type state :: %{
          optional(:port) => port(),
          optional(:root) => String.t(),
          optional(:mount_path) => String.t(),
          optional(:executable) => String.t(),
          # true when `root` was created under System.tmp_dir! as agentos-git-*
          optional(:temp_root?) => boolean(),
          # Host policy identity for commit inject (K28); never invents defaults.
          optional(:identity) => identity() | nil,
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

  @doc """
  JSON Run (`ge_run_json`). Local porcelain only (engine dial-free).

  When the engine was started with `:identity` / `:git_identity` `%{name:, email:}`,
  `commit` requests missing name/email are rewritten to inject that host identity
  (K28). Never invents Agent/agent@example.com when identity is unset.
  """
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

  @doc """
  Build a push pack from tip OIDs via engine `pack.build` (libgit2 packbuilder).

  Runs `{"op":"pack.build","args":{"oids":[...]}}` then reads
  `.git/agentos/push.pack` from the Port worktree root. Empty `oids` fail closed.
  Result always starts with `PACK` magic (or error).
  """
  @spec pack_build(pid(), [String.t()]) :: {:ok, binary()} | {:error, term()}
  def pack_build(pid, oids) when is_pid(pid) and is_list(oids) do
    GenServer.call(pid, {:pack_build, oids}, 120_000)
  end

  @doc "Binary MOUNT_OP body (peer of dispatchMount). Returns response bytes."
  @spec mount_op(pid(), binary()) :: {:ok, binary()} | {:error, term()}
  def mount_op(pid, body) when is_pid(pid) and is_binary(body) do
    GenServer.call(pid, {:mount_op, body}, 60_000)
  end

  @doc """
  Legacy type-5 frame to C fixture orch. Product remotes use
  `AgentOS.Git.Orchestrator.run/3` (BEAM HTTPS) instead.
  """
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
  Route a relayed host_call (PR7b / PR10c demux helper).

  * `name == "git"` → **BEAM** `AgentOS.Git.Orchestrator` (HTTPS) + Port apply
  * `name` equals `mount_path` → binary MOUNT_OP type 4

  Options (keyword, host-owned — never trust guest body for secrets/policy):
  * `:transport` — injectable SmartHttp transport (tests)
  * `:auth` — `%{kind: :none | :bearer | :header | :basic, ...}`
  * `:allowed_origins` / allowlist — fail-closed product remotes
  * `:pack_cache` — optional `AgentOS.Git.PackCache` pid / `:default`
  """
  @spec handle_host_call(pid(), String.t(), binary(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def handle_host_call(pid, name, body, opts \\ [])

  def handle_host_call(pid, "git", body, opts)
      when is_pid(pid) and is_binary(body) and is_list(opts) do
    case AgentOS.Git.Orchestrator.run(pid, body, opts) do
      {:ok, json} when is_binary(json) -> {:ok, json}
      {:error, _} = err -> err
    end
  end

  def handle_host_call(pid, name, body, _opts)
      when is_pid(pid) and is_binary(name) and is_binary(body) do
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

    {root, temp_root?} =
      case Keyword.get(opts, :root) do
        nil ->
          path =
            Path.join(
              System.tmp_dir!(),
              "agentos-git-" <> Integer.to_string(System.unique_integer([:positive]))
            )

          {path, true}

        given when is_binary(given) ->
          {given, false}
      end

    File.mkdir_p!(root)

    identity = normalize_identity(Keyword.get(opts, :identity) || Keyword.get(opts, :git_identity))

    case open_port(executable, root) do
      {:ok, port} ->
        {:ok,
         %{
           port: port,
           root: root,
           temp_root?: temp_root?,
           mount_path: Keyword.get(opts, :mount_path, "/workspace/repo"),
           executable: executable,
           identity: identity,
           buffer: <<>>
         }}

      {:error, reason} ->
        maybe_rm_temp_root(root, temp_root?)
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
    _ = AgentOS.Git.Metrics.inc(:port_eio)
    {:reply, {:error, :eio}, state}
  end

  def handle_call({:run, json}, _from, state) do
    json2 = maybe_inject_commit_identity(json, Map.get(state, :identity))
    reply_frame(state, @frame_run, json2, &decode_json_response/1)
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

  def handle_call({:pack_build, oids}, _from, state) do
    case do_pack_build(state, oids) do
      {:ok, pack, state2} -> {:reply, {:ok, pack}, state2}
      {:error, reason, state2} -> {:reply, {:error, reason}, state2}
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
  def terminate(_reason, state) do
    case Map.get(state, :port) do
      port when is_port(port) -> Port.close(port)
      _ -> :ok
    end

    maybe_rm_temp_root(Map.get(state, :root), Map.get(state, :temp_root?, false))
    :ok
  end

  # Only delete engine-owned temp roots under System.tmp_dir! named agentos-git-*.
  # Never touch caller-supplied `:root` paths.
  defp maybe_rm_temp_root(root, true) when is_binary(root) do
    tmp = System.tmp_dir!() |> Path.expand()
    root_exp = Path.expand(root)
    base = Path.basename(root_exp)

    if String.starts_with?(root_exp, tmp <> "/") and String.starts_with?(base, "agentos-git-") do
      _ = File.rm_rf(root_exp)
    end

    :ok
  end

  defp maybe_rm_temp_root(_root, _temp?), do: :ok

  # pack.build → export file under worktree `.git/agentos/push.pack` → read bytes.
  # Caller (`handle_call`) already fails closed when `port` is nil.
  defp do_pack_build(state, oids) when is_list(oids) do
    hex_oids =
      for o <- oids,
          is_binary(o),
          Regex.match?(~r/^[0-9a-fA-F]{40}$/, o),
          do: String.downcase(o)

    if hex_oids == [] do
      {:error, :no_oids, state}
    else
      json = encode_request(%{"op" => "pack.build", "args" => %{"oids" => hex_oids}})

      case request_response(state, @frame_run, json) do
        {:ok, payload, state2} ->
          {:ok, m} = decode_json_response(payload)

          if response_ok?(m) do
            root = Map.get(state2, :root)

            path =
              if is_binary(root) do
                Path.join(root, ".git/agentos/push.pack")
              else
                nil
              end

            cond do
              not is_binary(path) ->
                {:error, :no_root, state2}

              true ->
                case File.read(path) do
                  {:ok, <<"PACK", _::binary>> = pack} ->
                    {:ok, pack, state2}

                  {:ok, _} ->
                    {:error, :no_pack_magic, state2}

                  {:error, reason} ->
                    {:error, {:pack_read, reason}, state2}
                end
            end
          else
            stderr = Map.get(m, "stderr") || Map.get(m, :stderr) || inspect(m)
            {:error, {:pack_build_failed, stderr}, state2}
          end

        {:error, reason, state2} ->
          {:error, reason, state2}
      end
    end
  end

  defp response_ok?(m) when is_map(m) do
    case Map.get(m, "ok", Map.get(m, :ok)) do
      true -> true
      "true" -> true
      _ ->
        raw = Map.get(m, "raw")
        is_binary(raw) and String.contains?(raw, "\"ok\":true")
    end
  end

  defp response_ok?(_), do: false

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

  # K28 host identity — only inject when configured and commit args omit fields.
  defp normalize_identity(%{name: name, email: email})
       when is_binary(name) and is_binary(email) do
    n = String.trim(name)
    e = String.trim(email)
    if n != "" and e != "", do: %{name: n, email: e}, else: nil
  end

  defp normalize_identity(%{"name" => name, "email" => email})
       when is_binary(name) and is_binary(email) do
    normalize_identity(%{name: name, email: email})
  end

  defp normalize_identity(_), do: nil

  defp maybe_inject_commit_identity(json, nil) when is_binary(json), do: json
  defp maybe_inject_commit_identity(json, _id) when not is_binary(json), do: json

  defp maybe_inject_commit_identity(json, %{name: name, email: email}) do
    case safe_json_decode(json) do
      {:ok, map} when is_map(map) ->
        op =
          map
          |> Map.get("op", Map.get(map, :op, ""))
          |> to_string()
          |> String.downcase()

        if op == "commit" do
          args0 = Map.get(map, "args") || Map.get(map, :args) || %{}
          args = if is_map(args0), do: json_keys_to_string(args0), else: %{}
          args2 = inject_identity_args(args, name, email)
          encode_request(%{"op" => "commit", "args" => args2})
        else
          json
        end

      _ ->
        json
    end
  end

  defp inject_identity_args(args, name, email) when is_map(args) do
    args
    |> then(fn a ->
      n = Map.get(a, "name")
      if is_binary(n) and String.trim(n) != "", do: a, else: Map.put(a, "name", name)
    end)
    |> then(fn a ->
      e = Map.get(a, "email")
      if is_binary(e) and String.trim(e) != "", do: a, else: Map.put(a, "email", email)
    end)
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
    plen = len - 1
    <<type::8, payload::binary-size(^plen), next::binary>> = rest
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
    # OTP 27+ `:json.decode/1` returns the term directly (raises on error).
    try do
      term = :json.decode(bin)
      {:ok, json_keys_to_string(term)}
    rescue
      _ ->
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
    # Prefer OTP :json when present; it may return iodata (charlist chunks).
    if function_exported?(:json, :encode, 1) do
      map
      |> atom_keys_to_string()
      |> :json.encode()
      |> IO.iodata_to_binary()
    else
      # Tiny encoder for %{op, args} maps used by tests.
      op = Map.get(map, :op) || Map.get(map, "op") || ""
      args = Map.get(map, :args) || Map.get(map, "args")

      if args do
        ~s({"op":"#{escape(op)}","args":#{encode_value(args)}})
      else
        ~s({"op":"#{escape(op)}"})
      end
    end
  end

  defp atom_keys_to_string(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), atom_keys_to_string(v)}
      {k, v} -> {k, atom_keys_to_string(v)}
    end)
  end

  defp atom_keys_to_string(list) when is_list(list), do: Enum.map(list, &atom_keys_to_string/1)
  defp atom_keys_to_string(other), do: other

  defp encode_value(map) when is_map(map) do
    parts =
      Enum.map(map, fn {k, v} ->
        key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
        ~s("#{escape(key)}":#{encode_value(v)})
      end)

    "{" <> Enum.join(parts, ",") <> "}"
  end

  defp encode_value(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &encode_value/1) <> "]"
  end

  defp encode_value(s) when is_binary(s), do: ~s("#{escape(s)}")
  defp encode_value(n) when is_integer(n), do: Integer.to_string(n)
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(nil), do: "null"
  defp encode_value(other), do: ~s("#{escape(inspect(other))}")

  defp escape(s) when is_binary(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
  end
end
