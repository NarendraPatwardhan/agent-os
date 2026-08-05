defmodule AgentOS.GitEngine do
  @moduledoc """
  BEAM-owned Port to the native C `git-engine` process (SYSTEMS.md §11b).

  Length-prefixed frames on the child's stdin/stdout:

      <<length::little-32, type::8, payload::binary-size(length-1)>>

  Types: 1 Run, 2 pack chunk, 3 pack meta, 4 binary MOUNT_OP, 5 pack abort.
  Remotes: `AgentOS.Git.Orchestrator` (BEAM HTTPS) then Port apply.

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
          # true when root is a durable (re-openable) directory — never rm_rf
          optional(:durable?) => boolean(),
          # Host policy identity for commit inject (K28); never invents defaults.
          optional(:identity) => identity() | nil,
          buffer: binary()
        }

  @frame_run 1
  @frame_pack 2
  @frame_pack_meta 3
  @frame_mount 4
  @frame_pack_abort 5
  @frame_max_bytes 17 * 1024 * 1024

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

  When the engine was started with `:identity` `%{name:, email:}`,
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

  @doc "Abort and discard an incomplete streamed pack import. Idempotent."
  @spec abort_import_pack(pid()) :: :ok | {:error, term()}
  def abort_import_pack(pid) when is_pid(pid) do
    GenServer.call(pid, :abort_import_pack, 60_000)
  end

  @doc """
  Build a push pack from tip OIDs via engine `pack.build` (libgit2 packbuilder).

  Runs `{"op":"pack.build","args":{"oids":[...],"haves":[...]}}` then reads
  `.git/agentos/push.pack` from the Port worktree root. Empty `oids` fail closed.
  Optional `opts[:haves]` are remote tip OIDs already held (lease old hashes) so
  the pack omits objects the remote already has (R48). Result always starts with
  `PACK` magic (or error).
  """
  @spec pack_build(pid(), [String.t()], keyword()) :: {:ok, binary()} | {:error, term()}
  def pack_build(pid, oids, opts \\ []) when is_pid(pid) and is_list(oids) and is_list(opts) do
    GenServer.call(pid, {:pack_build, oids, opts}, 120_000)
  end

  @doc "Binary MOUNT_OP body (peer of dispatchMount). Returns response bytes."
  @spec mount_op(pid(), binary()) :: {:ok, binary()} | {:error, term()}
  def mount_op(pid, body) when is_pid(pid) and is_binary(body) do
    GenServer.call(pid, {:mount_op, body}, 60_000)
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
  Absolute worktree root bound at Port open (`ge_open` path).

  Durable roots (opts `:root` / `:durable_dir` / `:durable_id`) survive `stop/1`;
  temp roots under `System.tmp_dir!/agentos-git-*` are removed on terminate.
  Used by D16 reopen and D23 nested submodule clone.
  """
  @spec root(pid()) :: String.t() | nil
  def root(pid) when is_pid(pid) do
    GenServer.call(pid, :root, 5_000)
  rescue
    _ -> nil
  end

  @doc "Path to the git-engine executable used by this Port."
  @spec executable(pid()) :: String.t() | nil
  def executable(pid) when is_pid(pid) do
    GenServer.call(pid, :executable, 5_000)
  rescue
    _ -> nil
  end

  @doc """
  Checkpoint durable state for this engine.

  Native Port writes already land on the host filesystem. This validates that
  the bound root still exists for a later reopen. No blob export or portable
  directory fsync occurs on the BEAM path — the directory **is** the store
  (D16).
  """
  @spec checkpoint(pid()) :: :ok | {:error, term()}
  def checkpoint(pid) when is_pid(pid) do
    GenServer.call(pid, :checkpoint, 30_000)
  rescue
    _ -> {:error, :eio}
  end

  @doc """
  Route a relayed host_call (PR7b / PR10c demux helper).

  * `name == "git"` → **BEAM** `AgentOS.Git.Orchestrator` (HTTPS) + Port apply
  * `name` equals `mount_path` → binary MOUNT_OP type 4

  Options (keyword, host-owned — never trust guest body for secrets/policy):
  * `:transport` — injectable SmartHttp transport (tests)
  * `:auth` — `%{kind: :none | :bearer | :header | :basic, ...}`
  * `:allowed_origins` / allowlist — fail-closed product remotes
  * `:pack_cache` — optional cache: pid / `:default` (product: fresh Memory
    unless `AGENTOS_GIT_PACK_CACHE_SHARED=1` or disk env) / `:process` /
    `:shared` / `:disk` / `{:disk, dir}` (see `AgentOS.Git.Orchestrator`;
    env `AGENTOS_GIT_PACK_CACHE` / `AGENTOS_GIT_PACK_CACHE_SHARED`)
  * `:sparse_cone` — cone prefixes after clone (D20)
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

    # D16/D18: resolve root / durable_dir / durable_id, or allocate a temp root.
    case AgentOS.Git.Durable.resolve_root(opts) do
      {:error, reason} ->
        # Fail closed when durable_id is set without AGENTOS_GIT_DURABLE_ROOT.
        {:stop, reason}

      {:ok, root, kind} ->
        temp_root? = kind == :temp
        durable? = kind == :durable
        root = AgentOS.Git.Durable.ensure_root!(root)

        identity = normalize_identity(Keyword.get(opts, :identity))

        case open_port(executable, root) do
          {:ok, port} ->
            {:ok,
             %{
               port: port,
               root: root,
               temp_root?: temp_root?,
               durable?: durable?,
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
  end

  @impl true
  def handle_call(:alive?, _from, %{port: port} = state) when is_port(port) do
    {:reply, :ok, state}
  end

  def handle_call(:alive?, _from, state), do: {:reply, {:error, :eio}, state}

  def handle_call(:root, _from, state) do
    {:reply, Map.get(state, :root), state}
  end

  def handle_call(:checkpoint, _from, state) do
    case Map.get(state, :root) do
      root when is_binary(root) ->
        {:reply, AgentOS.Git.Durable.sync_root(root), state}

      _ ->
        {:reply, {:error, :no_root}, state}
    end
  end

  def handle_call(:mount_path, _from, state) do
    {:reply, Map.get(state, :mount_path), state}
  end

  def handle_call(:executable, _from, state) do
    {:reply, Map.get(state, :executable), state}
  end

  def handle_call(_msg, _from, %{port: nil} = state) do
    _ = AgentOS.Git.Metrics.inc(:port_eio)
    {:reply, {:error, :eio}, state}
  end

  def handle_call({:run, json}, _from, state) do
    json2 = maybe_inject_commit_identity(json, Map.get(state, :identity))
    reply_frame(state, @frame_run, json2, &decode_json_response/1)
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

  def handle_call(:abort_import_pack, _from, state) do
    with {:ok, state1} <- send_frame(state, @frame_pack_abort, <<>>),
         {:ok, status, state2} <- recv_status_frame(state1, @frame_pack_abort) do
      if status == 0,
        do: {:reply, :ok, state2},
        else: {:reply, {:error, :import_pack_abort}, state2}
    else
      {:error, reason, st} -> {:reply, {:error, reason}, st}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:pack_build, oids, opts}, _from, state) do
    case do_pack_build(state, oids, opts) do
      {:ok, pack, state2} -> {:reply, {:ok, pack}, state2}
      {:error, reason, state2} -> {:reply, {:error, reason}, state2}
    end
  end

  def handle_call({:mount_op, body}, _from, state) do
    body2 = maybe_inject_mount_commit_identity(body, Map.get(state, :identity))
    reply_frame(state, @frame_mount, body2, fn payload -> {:ok, payload} end)
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
  defp do_pack_build(state, oids, opts) when is_list(oids) and is_list(opts) do
    haves = Keyword.get(opts, :haves, [])
    valid_oid? = fn oid -> is_binary(oid) and Regex.match?(~r/^[0-9a-fA-F]{40}$/, oid) end

    cond do
      oids == [] ->
        {:error, :no_oids, state}

      not Enum.all?(oids, valid_oid?) or not is_list(haves) or not Enum.all?(haves, valid_oid?) ->
        {:error, :invalid_oid, state}

      true ->
        hex_oids = oids |> Enum.map(&String.downcase/1) |> Enum.uniq()
        hex_haves = haves |> Enum.map(&String.downcase/1) |> Enum.uniq()

        args =
          if hex_haves == [] do
            %{"oids" => hex_oids}
          else
            %{"oids" => hex_oids, "haves" => hex_haves}
          end

        json = encode_request(%{"op" => "pack.build", "args" => args})

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
                  result =
                    case File.read(path) do
                      {:ok, <<"PACK", _::binary>> = pack} ->
                        {:ok, pack, state2}

                      {:ok, _} ->
                        {:error, :no_pack_magic, state2}

                      {:error, reason} ->
                        {:error, {:pack_read, reason}, state2}
                    end

                  case {result, File.rm(path)} do
                    {value, :ok} -> value
                    {{:error, _, _} = error, {:error, _}} -> error
                    {{:ok, _, _}, {:error, reason}} -> {:error, {:pack_cleanup, reason}, state2}
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
      true ->
        true

      "true" ->
        true

      _ ->
        false
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
        op = map |> Map.get("op", "") |> to_string() |> String.downcase()
        valid_top? = Map.keys(map) |> MapSet.new() |> MapSet.subset?(MapSet.new(["op", "args"]))
        args_present? = Map.has_key?(map, "args")
        args0 = Map.get(map, "args", %{})

        if op == "commit" and valid_top? and (not args_present? or is_map(args0)) do
          args = json_keys_to_string(args0)
          args2 = inject_identity_args(args, name, email)
          map |> Map.put("args", args2) |> encode_request()
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
      if Map.has_key?(a, "name"), do: a, else: Map.put(a, "name", name)
    end)
    |> then(fn a ->
      if Map.has_key?(a, "email"), do: a, else: Map.put(a, "email", email)
    end)
  end

  # MOUNT_OP WRITE (6): u32 op, u32 path_len, path, u32 arg_len, arg, data.
  # Rewrite only ctl data; every other mount frame remains opaque.
  defp maybe_inject_mount_commit_identity(body, nil), do: body

  defp maybe_inject_mount_commit_identity(
         <<6::little-32, path_len::little-32, rest::binary>> = body,
         identity
       )
       when path_len <= byte_size(rest) do
    case rest do
      <<path::binary-size(path_len), arg_len::little-32, tail::binary>>
      when arg_len <= byte_size(tail) ->
        <<arg::binary-size(arg_len), data::binary>> = tail

        if String.trim_leading(path, "/") == ".git/mc/ctl" do
          rewritten = maybe_inject_commit_identity(data, identity)

          <<6::little-32, path_len::little-32, path::binary, arg_len::little-32, arg::binary,
            rewritten::binary>>
        else
          body
        end

      _ ->
        body
    end
  end

  defp maybe_inject_mount_commit_identity(body, _identity), do: body

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
         {:ok, ^type, resp, state2} <- recv_frame(state1) do
      {:ok, resp, state2}
    else
      {:ok, _wrong_type, _resp, state2} -> {:error, :bad_frame, state2}
      other -> other
    end
  end

  defp send_frame(%{port: port} = state, type, payload) when is_port(port) do
    body = IO.iodata_to_binary([<<type::8>>, payload])
    len = byte_size(body)

    if len > @frame_max_bytes do
      {:error, :frame_too_large, state}
    else
      frame = <<len::little-32, body::binary>>
      true = Port.command(port, frame)
      {:ok, state}
    end
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

      {:error, reason} ->
        {:error, reason, %{state | port: nil}}

      :incomplete when attempts > 0 ->
        expected_port = Map.get(state, :port)

        receive do
          {^expected_port, {:data, data}} when is_port(expected_port) and is_binary(data) ->
            recv_frame(%{state | buffer: buf <> data}, attempts - 1)

          {^expected_port, {:exit_status, _}} when is_port(expected_port) ->
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

  defp take_frame(<<len::little-32, _::binary>>) when len < 1 or len > @frame_max_bytes,
    do: {:error, :bad_frame}

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
    # OTP 27+ uses `:json`; OTP 26 (Bazel) uses Jason_like.parse so tests and
    # orch get real maps (stdout/stderr/ok) instead of opaque %{"raw" => …}.
    case AgentOS.GitEngine.Jason_like.decode(bin) do
      {:ok, map} when is_map(map) ->
        {:ok, json_keys_to_string(map)}

      {:ok, other} ->
        {:ok, other}

      _ ->
        {:error, :invalid_json}
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

  @doc """
  Discover the product `git-engine` Port binary (D38).

  Search order (first regular file wins):
  1. `AGENTOS_GIT_ENGINE` env (explicit override; tests/Bazel)
  2. `Application.app_dir(:agent_os, "priv/git-engine")` — Mix/`mix release` priv
  3. `:code.priv_dir(:agent_os)/git-engine` when the app is loaded
  4. `$RELEASE_ROOT/priv/git-engine` and `$RELEASE_ROOT/lib/*/priv/git-engine`
  5. CWD-relative `priv/git-engine` (dev / path-dep package layout)
  6. Workspace-relative Bazel/runfiles fallbacks

  Returns the path string even if missing (Port open fails closed later).
  """
  @spec discover_executable() :: String.t()
  def discover_executable, do: default_executable()

  defp default_executable do
    candidates =
      [
        System.get_env("AGENTOS_GIT_ENGINE"),
        app_priv_git_engine(),
        code_priv_git_engine(),
        release_root_git_engine(),
        Path.join(File.cwd!(), "priv/git-engine"),
        Path.join(File.cwd!(), "server/priv/git-engine"),
        "memcontainers/lib/git-engine/git-engine",
        Path.join(File.cwd!(), "memcontainers/lib/git-engine/git-engine")
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.find(candidates, "git-engine", fn path ->
      is_binary(path) and path != "" and File.regular?(path)
    end)
  end

  defp app_priv_git_engine do
    try do
      Path.join(Application.app_dir(:agent_os, "priv"), "git-engine")
    rescue
      _ -> nil
    end
  end

  defp code_priv_git_engine do
    case :code.priv_dir(:agent_os) do
      dir when is_list(dir) or is_binary(dir) ->
        Path.join(to_string(dir), "git-engine")

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp release_root_git_engine do
    root =
      case System.get_env("RELEASE_ROOT") do
        r when is_binary(r) and r != "" ->
          r

        _ ->
          case System.get_env("RELEASE_SYS_CONFIG") do
            cfg when is_binary(cfg) and cfg != "" ->
              # releases/<v>/sys.config → release root is three dirs up
              cfg |> Path.dirname() |> Path.dirname() |> Path.dirname()

            _ ->
              nil
          end
      end

    if is_binary(root) and root != "" do
      [
        Path.join(root, "priv/git-engine"),
        Path.join(root, "lib/agent_os/priv/git-engine")
      ] ++
        case Path.wildcard(Path.join(root, "lib/agent_os-*/priv/git-engine")) do
          paths when is_list(paths) -> paths
          _ -> []
        end
    else
      []
    end
  end
end

defmodule AgentOS.GitEngine.Jason_like do
  @moduledoc false

  # Small deterministic JSON codec used on every supported OTP version.
  @max_json_bytes 1024 * 1024
  @max_json_depth 64

  def encode!(map) when is_map(map) do
    # Prefer OTP :json when present; it may return iodata (charlist chunks).
    if function_exported?(:json, :encode, 1) do
      map
      |> atom_keys_to_string()
      |> then(&apply(:json, :encode, [&1]))
      |> IO.iodata_to_binary()
    else
      encode_value(atom_keys_to_string(map))
    end
  end

  @doc """
  Decode a bounded UTF-8 JSON binary consistently on every supported OTP.
  """
  def decode(bin) when is_binary(bin) do
    if byte_size(bin) <= @max_json_bytes and String.valid?(bin) and valid_json_nesting?(bin) do
      parse_json(bin)
    else
      {:error, :invalid_json}
    end
  end

  def decode(_), do: {:error, :invalid_json}

  defp parse_json(bin) do
    case parse_value(trim_json_ws(bin)) do
      {:ok, term, rest} ->
        if trim_json_ws(rest) == "", do: {:ok, term}, else: {:error, :invalid_json}

      _ ->
        {:error, :invalid_json}
    end
  end

  defp parse_value(<<"true", rest::binary>>), do: {:ok, true, rest}
  defp parse_value(<<"false", rest::binary>>), do: {:ok, false, rest}
  defp parse_value(<<"null", rest::binary>>), do: {:ok, nil, rest}

  defp parse_value(<<"\"", rest::binary>>), do: parse_string(rest, [])

  defp parse_value(<<"{", rest::binary>>), do: parse_object(trim_json_ws(rest), %{})

  defp parse_value(<<"[", rest::binary>>), do: parse_array(trim_json_ws(rest), [])

  defp parse_value(<<c, _::binary>> = bin) when c in ?0..?9 or c == ?- do
    parse_number(bin)
  end

  defp parse_value(_), do: :error

  defp parse_string(<<"\"", rest::binary>>, acc) do
    {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp parse_string(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    with {codepoint, ""} <- Integer.parse(hex, 16),
         {:ok, utf8, rest} <- decode_json_codepoint(codepoint, rest) do
      parse_string(rest, [utf8 | acc])
    else
      _ -> :error
    end
  end

  defp parse_string(<<"\\", e, rest::binary>>, acc) when e in [?", ?\\, ?/] do
    parse_string(rest, [<<e>> | acc])
  end

  defp parse_string(<<"\\b", rest::binary>>, acc), do: parse_string(rest, [<<8>> | acc])
  defp parse_string(<<"\\f", rest::binary>>, acc), do: parse_string(rest, [<<12>> | acc])
  defp parse_string(<<"\\n", rest::binary>>, acc), do: parse_string(rest, ["\n" | acc])
  defp parse_string(<<"\\r", rest::binary>>, acc), do: parse_string(rest, ["\r" | acc])
  defp parse_string(<<"\\t", rest::binary>>, acc), do: parse_string(rest, ["\t" | acc])
  defp parse_string(<<"\\", _e, _rest::binary>>, _acc), do: :error
  defp parse_string(<<c, _rest::binary>>, _acc) when c < 0x20, do: :error
  defp parse_string(<<c, rest::binary>>, acc), do: parse_string(rest, [<<c>> | acc])
  defp parse_string(<<>>, _acc), do: :error

  defp decode_json_codepoint(high, <<"\\u", low_hex::binary-size(4), rest::binary>>)
       when high in 0xD800..0xDBFF do
    case Integer.parse(low_hex, 16) do
      {low, ""} when low in 0xDC00..0xDFFF ->
        codepoint = 0x10000 + (high - 0xD800) * 0x400 + low - 0xDC00
        {:ok, <<codepoint::utf8>>, rest}

      _ ->
        :error
    end
  end

  defp decode_json_codepoint(high, _rest) when high in 0xD800..0xDFFF, do: :error
  defp decode_json_codepoint(codepoint, rest), do: {:ok, <<codepoint::utf8>>, rest}

  defp parse_object(<<"}", rest::binary>>, acc), do: {:ok, acc, rest}

  defp parse_object(bin, acc) do
    bin = trim_json_ws(bin)

    with {:ok, key, rest} <- parse_value(bin),
         true <- is_binary(key),
         false <- Map.has_key?(acc, key),
         rest = trim_json_ws(rest),
         <<":", rest::binary>> <- rest,
         rest = trim_json_ws(rest),
         {:ok, val, rest} <- parse_value(rest) do
      acc = Map.put(acc, key, val)
      rest = trim_json_ws(rest)

      case rest do
        <<",", rest::binary>> -> parse_object(trim_json_ws(rest), acc)
        <<"}", rest::binary>> -> {:ok, acc, rest}
        _ -> :error
      end
    else
      _ -> :error
    end
  end

  defp parse_array(<<"]", rest::binary>>, acc), do: {:ok, Enum.reverse(acc), rest}

  defp parse_array(bin, acc) do
    with {:ok, val, rest} <- parse_value(bin) do
      acc = [val | acc]
      rest = trim_json_ws(rest)

      case rest do
        <<",", rest::binary>> -> parse_array(trim_json_ws(rest), acc)
        <<"]", rest::binary>> -> {:ok, Enum.reverse(acc), rest}
        _ -> :error
      end
    end
  end

  defp parse_number(bin) do
    case Regex.run(~r/^(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/, bin) do
      [raw | _] ->
        rest = binary_part(bin, byte_size(raw), byte_size(bin) - byte_size(raw))

        cond do
          String.contains?(raw, ".") or String.contains?(raw, "e") or String.contains?(raw, "E") ->
            case Float.parse(raw) do
              {n, ""} -> {:ok, n, rest}
              _ -> :error
            end

          true ->
            case Integer.parse(raw) do
              {n, ""} -> {:ok, n, rest}
              _ -> :error
            end
        end

      _ ->
        :error
    end
  end

  defp trim_json_ws(<<c, rest::binary>>) when c in [0x20, 0x09, 0x0A, 0x0D],
    do: trim_json_ws(rest)

  defp trim_json_ws(bin), do: bin

  defp valid_json_nesting?(bin), do: scan_json_nesting?(bin, false, false, 0)

  defp scan_json_nesting?(<<>>, false, false, 0), do: true
  defp scan_json_nesting?(<<>>, _quoted, _escaped, _depth), do: false

  defp scan_json_nesting?(<<_c, rest::binary>>, true, true, depth),
    do: scan_json_nesting?(rest, true, false, depth)

  defp scan_json_nesting?(<<"\\", rest::binary>>, true, false, depth),
    do: scan_json_nesting?(rest, true, true, depth)

  defp scan_json_nesting?(<<"\"", rest::binary>>, true, false, depth),
    do: scan_json_nesting?(rest, false, false, depth)

  defp scan_json_nesting?(<<_c, rest::binary>>, true, false, depth),
    do: scan_json_nesting?(rest, true, false, depth)

  defp scan_json_nesting?(<<"\"", rest::binary>>, false, false, depth),
    do: scan_json_nesting?(rest, true, false, depth)

  defp scan_json_nesting?(<<c, rest::binary>>, false, false, depth) when c in [?{, ?[] do
    next = depth + 1
    next <= @max_json_depth and scan_json_nesting?(rest, false, false, next)
  end

  defp scan_json_nesting?(<<c, rest::binary>>, false, false, depth) when c in [?}, ?]] do
    depth > 0 and scan_json_nesting?(rest, false, false, depth - 1)
  end

  defp scan_json_nesting?(<<_c, rest::binary>>, false, false, depth),
    do: scan_json_nesting?(rest, false, false, depth)

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
  defp encode_value(n) when is_float(n), do: :erlang.float_to_binary(n, [:short])
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(nil), do: "null"
  defp encode_value(other), do: raise(ArgumentError, "unsupported JSON value: #{inspect(other)}")

  defp escape(s) when is_binary(s), do: escape_bytes(s, [])

  defp escape_bytes(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp escape_bytes(<<8, rest::binary>>, acc), do: escape_bytes(rest, ["\\b" | acc])
  defp escape_bytes(<<9, rest::binary>>, acc), do: escape_bytes(rest, ["\\t" | acc])
  defp escape_bytes(<<10, rest::binary>>, acc), do: escape_bytes(rest, ["\\n" | acc])
  defp escape_bytes(<<12, rest::binary>>, acc), do: escape_bytes(rest, ["\\f" | acc])
  defp escape_bytes(<<13, rest::binary>>, acc), do: escape_bytes(rest, ["\\r" | acc])
  defp escape_bytes(<<34, rest::binary>>, acc), do: escape_bytes(rest, ["\\\"" | acc])
  defp escape_bytes(<<92, rest::binary>>, acc), do: escape_bytes(rest, ["\\\\" | acc])

  defp escape_bytes(<<c, rest::binary>>, acc) when c < 0x20 do
    escaped = "\\u00" <> (c |> Integer.to_string(16) |> String.pad_leading(2, "0"))
    escape_bytes(rest, [escaped | acc])
  end

  defp escape_bytes(<<c, rest::binary>>, acc), do: escape_bytes(rest, [<<c>> | acc])
end
