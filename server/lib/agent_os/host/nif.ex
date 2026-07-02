defmodule AgentOS.Host.Nif do
  @moduledoc """
  Raw NIF binding to `libhost_nif.so` — the Rustler wrapper over the wasmtime
  `host::KernelHost` (CONTROL_PLANE.md §6.1). This is the ONLY module that touches the NIF;
  all process discipline (single-owner, crash-only, the tick loop) lives in `AgentOS.Vm`.
  Do not call these directly.

  ## Why manual loading (no `use Rustler`)

  Bazel builds the release `.so` (`//memcontainers/hosts/wasmtime/nif:host_nif_release`) and stages it into
  this app's `priv/`. We therefore want Elixir to *load* a prebuilt artifact, never *compile*
  one — so we skip the `rustler` hex package entirely and load the NIF by hand via `@on_load`
  + `:erlang.load_nif/2`. The Rust `rustler::init!` still emits the standard `nif_init`
  entrypoint, so the manual load works unchanged and the app carries no extra dependency.

  ## Contract

  Every fallible call returns `{:ok, value} | {:error, reason}` — host failures are *values*,
  not raises (the owning `AgentOS.Vm` decides policy). The public functions below validate the
  small Elixir-facing option surface, then call raw `*_nif` entries that run host work on a
  DirtyCpu scheduler.
  """

  @on_load :load_nif

  alias AgentOS.Contracts.Control

  @doc false
  def load_nif do
    priv = :code.priv_dir(:agent_os)

    # The exact sub-path under priv/ is decided by the mix_library `priv` staging, so locate
    # the cdylib by wildcard and hand `load_nif` the path with the OS extension stripped.
    base =
      case :filelib.wildcard(:filename.join([priv, ~c"**", ~c"libhost_nif.*"])) do
        [path | _] -> :filename.rootname(path)
        [] -> :filename.join(priv, ~c"libhost_nif")
      end

    :erlang.load_nif(base, 0)
  end

  @typedoc "Opaque handle to a live VM (a `ResourceArc<Vm>` on the Rust side)."
  @opaque vm :: reference()

  @typedoc "A host error message."
  @type reason :: binary()

  @type contract :: {tier :: integer(), budget_mib :: integer(), fuel :: integer()}
  @type net_mode :: :deny | :relay | :real
  @type relay_mode :: :deny | :relay
  @type persist_mode :: :deny | :relay
  @type connection_auth ::
          :none
          | {:none}
          | {:bearer, binary()}
          | {:header, binary(), binary()}
          | {:query, binary(), binary()}
          | %{
              required(:kind) => :none | :bearer | :header | :query,
              optional(:token) => binary(),
              optional(:name) => binary(),
              optional(:value) => binary()
            }
          | %{required(String.t()) => binary()}
  @type connection_def ::
          {ref :: binary(), connection_auth()}
          | {ref :: binary(), connection_auth(), origins :: [binary()]}
          | %{required(:ref) => binary(), required(:auth) => connection_auth()}
          | %{required(String.t()) => term()}
  @type connection_policy_owner :: :org | :user
  @type connection_policy_action :: :approve | :require_approval | :block
  @type connection_policy_rule ::
          {connection_policy_owner(), binary(), connection_policy_action()}
          | %{
              required(:owner) => connection_policy_owner(),
              required(:pattern) => binary(),
              required(:action) => connection_policy_action()
            }
          | %{required(String.t()) => term()}
  @type boot_opt ::
          {:layers, [binary()]}
          | {:deterministic, boolean()}
          | {:contract, contract() | nil}
          | {:workers, non_neg_integer() | nil}
          | {:net, net_mode() | {:real, [connection_def()]}}
          | {:connections, [connection_def()]}
          | {:connection_policies, [connection_policy_rule()]}
          | {:tool_approval, :deny | :relay}
          | {:host_call, relay_mode()}
          | {:persist, persist_mode()}

  @type catalog_spec ::
          nil
          | {:bytes, binary()}
          | {:bytes, binary(), keyword() | map()}
          | {:path, binary()}
          | {:path, binary(), keyword() | map()}
          | {:url, binary()}
          | {:url, binary(), keyword() | map()}
          | %{required(String.t() | atom()) => term()}
  @type catalog_status :: %{
          generation: non_neg_integer(),
          digest: String.t(),
          tools: non_neg_integer()
        }

  @type relay_event ::
          %{kind: :http, handle: pos_integer(), request: binary()}
          | %{kind: :host_call, handle: pos_integer(), name: String.t(), body: binary()}
          | %{kind: :persist_get, handle: pos_integer(), key: binary()}
          | %{kind: :persist_put, handle: pos_integer(), key: binary(), value: binary()}
          | %{kind: :persist_delete, handle: pos_integer(), key: binary()}
          | %{kind: :persist_list, handle: pos_integer(), prefix: binary()}
          | %{kind: :ws_connect, handle: pos_integer(), url: String.t()}
          | %{kind: :ws_send, handle: pos_integer(), data: binary()}
          | %{kind: :ws_close, handle: pos_integer()}
          | %{
              kind: :tool_approval,
              handle: pos_integer(),
              connection: String.t(),
              method: String.t(),
              url: String.t(),
              origin: String.t(),
              args_digest: String.t() | nil
            }

  @doc """
  Boot a VM from a `kernel.wasm` plus either one base image or an ordered layer stack.

  Options intentionally mirror the production host builder rather than the whole Rust host:
  deterministic clock/RNG for parity tests, boot contract, worker count, and the explicit P2
  relay switches.

  `:host_call` and `:persist` accept `:deny` or `:relay`. `:net` accepts `:deny`,
  `:relay`, or `:real`; real net may also receive host-only `:connections`, whose
  secrets are injected by the Rust host when a guest request names `X-MC-Connection`.
  Secret-bearing connections must include the absolute `http`/`https` origins allowed to
  receive that credential.
  """
  @spec boot(binary(), binary() | nil, [boot_opt()]) :: {:ok, vm()} | {:error, reason()}
  def boot(wasm, base_image, opts \\ [])

  def boot(wasm, base_image, opts)
      when is_binary(wasm) and (is_binary(base_image) or is_nil(base_image)) and is_list(opts) do
    with {:ok, layers, deterministic, contract, workers, net, connection_policies, tool_approval,
          host_call, persist} <-
           boot_args(base_image, opts) do
      {net_relay, net_real, connections} = net

      boot_nif(
        wasm,
        base_image,
        layers,
        deterministic,
        contract,
        workers,
        net_relay,
        net_real,
        connections,
        connection_policies,
        tool_approval,
        host_call,
        persist
      )
    end
  end

  def boot(_wasm, _base_image, _opts),
    do: {:error, "boot expects binary wasm, binary-or-nil base image, and keyword options"}

  @doc "Restore (or fork) a VM from a snapshot blob — the booted state IS the image (A8)."
  @spec restore(binary(), binary(), [boot_opt()]) :: {:ok, vm()} | {:error, reason()}
  def restore(wasm, snapshot, opts \\ [])

  def restore(wasm, snapshot, opts)
      when is_binary(wasm) and is_binary(snapshot) and is_list(opts) do
    with {:ok, deterministic, workers, net, connection_policies, tool_approval, host_call,
          persist} <-
           restore_args(opts) do
      {net_relay, net_real, connections} = net

      restore_nif(
        wasm,
        snapshot,
        deterministic,
        workers,
        net_relay,
        net_real,
        connections,
        connection_policies,
        tool_approval,
        host_call,
        persist
      )
    end
  end

  def restore(_wasm, _snapshot, _opts),
    do: {:error, "restore expects binary wasm, binary snapshot, and keyword options"}

  @doc "Drive one bounded `mc_tick`: `{:ok, true}` while running, `{:ok, false}` once exited."
  @spec tick(vm()) :: {:ok, boolean()} | {:error, reason()}
  def tick(vm), do: tick_nif(vm)

  @doc "Feed bytes to the kernel as terminal input."
  @spec send_input(vm(), binary()) :: :ok | {:error, reason()}
  def send_input(vm, bytes) when is_binary(bytes), do: send_input_nif(vm, bytes)
  def send_input(_vm, _bytes), do: {:error, "send_input expects binary bytes"}

  @doc "Drain (and clear) the terminal output captured since the last call."
  @spec take_output(vm()) :: binary()
  def take_output(_vm), do: nif_not_loaded()

  @doc "Run a command to completion → `{:ok, {exit_code, stdout, stderr}}`."
  @spec exec(vm(), String.t(), non_neg_integer(), keyword() | map()) ::
          {:ok, {integer(), binary(), binary()}} | {:error, reason()}
  def exec(vm, cmd, max_ticks, opts \\ [])

  def exec(vm, cmd, max_ticks, opts)
      when is_binary(cmd) and is_integer(max_ticks) and max_ticks >= 0 do
    with {:ok, {cwd, env, stdin_present, stdin}} <- exec_options(opts) do
      exec_nif(vm, cmd, max_ticks, cwd, env, stdin_present, stdin)
    end
  end

  def exec(_vm, _cmd, _max_ticks, _opts),
    do: {:error, "exec expects a binary command, non-negative max_ticks, and valid options"}

  @doc "Start a structured exec job without driving it to completion."
  @spec exec_start(vm(), String.t(), keyword() | map()) :: {:ok, integer()} | {:error, reason()}
  def exec_start(vm, cmd, opts \\ [])

  def exec_start(vm, cmd, opts) when is_binary(cmd) do
    with {:ok, {cwd, env, stdin_present, stdin}} <- exec_options(opts) do
      exec_start_nif(vm, cmd, cwd, env, stdin_present, stdin)
    end
  end

  def exec_start(_vm, _cmd, _opts),
    do: {:error, "exec_start expects a binary command and valid options"}

  @doc "Poll a structured exec job; `nil` means still running."
  @spec exec_poll(vm(), integer()) ::
          {:ok, nil | {integer(), binary(), binary()}} | {:error, reason()}
  def exec_poll(vm, job) when is_integer(job) and job > 0, do: exec_poll_nif(vm, job)
  def exec_poll(_vm, _job), do: {:error, "exec_poll expects a positive job id"}

  @doc "Read stdout produced so far by a running exec job."
  @spec exec_stdout_peek(vm(), integer()) :: {:ok, binary()} | {:error, reason()}
  def exec_stdout_peek(vm, job) when is_integer(job) and job > 0,
    do: exec_stdout_peek_nif(vm, job)

  def exec_stdout_peek(_vm, _job), do: {:error, "exec_stdout_peek expects a positive job id"}

  @doc "Cancel a structured exec job."
  @spec exec_cancel(vm(), integer()) :: :ok | {:error, reason()}
  def exec_cancel(vm, job) when is_integer(job) and job > 0, do: exec_cancel_nif(vm, job)
  def exec_cancel(_vm, _job), do: {:error, "exec_cancel expects a positive job id"}

  @doc """
  Call a resident service as host control (`SYSTEM_CALLER`) through the kernel service channel →
  `{:ok, {status, body}}`. `status` is the service's own status code (0 = ok); a nonzero status
  still returns its body so the owning `AgentOS.Vm` decides policy.
  """
  @spec svc_call(vm(), String.t(), binary()) ::
          {:ok, {integer(), binary()}} | {:error, reason()}
  def svc_call(vm, service, request) when is_binary(service) and is_binary(request),
    do: svc_call_nif(vm, service, request)

  def svc_call(_vm, _service, _request),
    do: {:error, "svc_call expects a binary service name and request"}

  @doc "Read a whole file through the Rust host control channel."
  @spec read_file(vm(), String.t()) :: {:ok, binary()} | {:error, reason()}
  def read_file(vm, path) when is_binary(path), do: read_file_nif(vm, path)
  def read_file(_vm, _path), do: {:error, "read_file expects a binary path"}

  @doc "Write a whole file through the Rust host control channel."
  @spec write_file(vm(), String.t(), binary()) :: :ok | {:error, reason()}
  def write_file(vm, path, data) when is_binary(path) and is_binary(data),
    do: write_file_nif(vm, path, data)

  def write_file(_vm, _path, _data), do: {:error, "write_file expects a binary path and data"}

  @type dir_entry :: %{name: String.t(), type: :directory | :symlink | :file}

  @doc "List a directory through the Rust host control channel."
  @spec readdir(vm(), String.t()) :: {:ok, [dir_entry()]} | {:error, reason()}
  def readdir(vm, path) when is_binary(path) do
    case readdir_nif(vm, path) do
      {:ok, entries} -> {:ok, Enum.map(entries, &dir_entry/1)}
      {:error, _reason} = err -> err
    end
  end

  def readdir(_vm, _path), do: {:error, "readdir expects a binary path"}

  @type file_stat :: %{
          size: non_neg_integer(),
          type: :directory | :symlink | :file,
          nlink: non_neg_integer(),
          mode: non_neg_integer()
        }

  @doc "Stat a path through the Rust host control channel."
  @spec stat(vm(), String.t()) :: {:ok, file_stat()} | {:error, reason()}
  def stat(vm, path) when is_binary(path) do
    case stat_nif(vm, path) do
      {:ok, {size, is_dir, is_symlink, nlink, mode}} ->
        {:ok, %{size: size, type: file_type(is_dir, is_symlink), nlink: nlink, mode: mode}}

      {:error, _reason} = err ->
        err
    end
  end

  def stat(_vm, _path), do: {:error, "stat expects a binary path"}

  @doc "Read the target text of a symlink through the Rust host control channel."
  @spec readlink(vm(), String.t()) :: {:ok, binary()} | {:error, reason()}
  def readlink(vm, path) when is_binary(path), do: readlink_nif(vm, path)
  def readlink(_vm, _path), do: {:error, "readlink expects a binary path"}

  @doc "Create a directory through the Rust host control channel."
  @spec mkdir(vm(), String.t()) :: :ok | {:error, reason()}
  def mkdir(vm, path) when is_binary(path), do: mkdir_nif(vm, path)
  def mkdir(_vm, _path), do: {:error, "mkdir expects a binary path"}

  @doc "Remove a file or empty directory through the Rust host control channel."
  @spec unlink(vm(), String.t()) :: :ok | {:error, reason()}
  def unlink(vm, path) when is_binary(path), do: unlink_nif(vm, path)
  def unlink(_vm, _path), do: {:error, "unlink expects a binary path"}

  @doc "Set POSIX permission bits through the Rust host control channel."
  @spec chmod(vm(), String.t(), non_neg_integer()) :: :ok | {:error, reason()}
  def chmod(vm, path, mode) when is_binary(path) and is_integer(mode) and mode in 0..0o7777,
    do: chmod_nif(vm, path, mode)

  def chmod(_vm, _path, _mode),
    do: {:error, "chmod expects a binary path and mode in 0..0o7777"}

  @doc "Create a symbolic link through the Rust host control channel."
  @spec symlink(vm(), String.t(), String.t()) :: :ok | {:error, reason()}
  def symlink(vm, target, link) when is_binary(target) and is_binary(link),
    do: symlink_nif(vm, target, link)

  def symlink(_vm, _target, _link),
    do: {:error, "symlink expects binary target and link paths"}

  @doc "Mount a host-call-backed filesystem driver at path."
  @spec mount(vm(), String.t(), boolean()) :: :ok | {:error, reason()}
  def mount(vm, path, read_only \\ false)

  def mount(vm, path, read_only) when is_binary(path) and is_boolean(read_only),
    do: mount_nif(vm, path, read_only)

  def mount(_vm, _path, _read_only),
    do: {:error, "mount expects a binary path and boolean read_only"}

  @doc "Unmount a host-backed filesystem driver at path."
  @spec unmount(vm(), String.t()) :: :ok | {:error, reason()}
  def unmount(vm, path) when is_binary(path), do: unmount_nif(vm, path)
  def unmount(_vm, _path), do: {:error, "unmount expects a binary path"}

  @doc "Serialize the live CoW overlay into `{tar_bytes, digest}`."
  @spec commit_layer(vm()) :: {:ok, {binary(), String.t()}} | {:error, reason()}
  def commit_layer(vm), do: commit_layer_nif(vm)

  @type status :: %{
          bytes_written: non_neg_integer(),
          exit_code: integer() | nil,
          at_prompt: boolean(),
          workers: non_neg_integer(),
          has_worker_entry: boolean(),
          inflight_egress: non_neg_integer(),
          pending_commits: non_neg_integer()
        }

  @doc "Host-level VM status from the Rust host."
  @spec status(vm()) :: {:ok, status()} | {:error, reason()}
  def status(vm) do
    case status_nif(vm) do
      {:ok,
       {bytes_written, exit_code, at_prompt, workers, has_worker_entry, inflight_egress,
        pending_commits}} ->
        {:ok,
         %{
           bytes_written: bytes_written,
           exit_code: exit_code,
           at_prompt: at_prompt,
           workers: workers,
           has_worker_entry: has_worker_entry,
           inflight_egress: inflight_egress,
           pending_commits: pending_commits
         }}

      {:error, _reason} = err ->
        err
    end
  end

  @doc "Capture the whole VM (linear memory + header) into a portable blob (A8)."
  @spec snapshot(vm()) :: {:ok, binary()} | {:error, reason()}
  def snapshot(vm), do: snapshot_nif(vm)

  @doc """
  Compile and inject a host-side tool catalog through the wasmtime host. `connections` carry
  spec/group selectors compiled via `catalog-compiler.wasm`; `host_tools` carry host-call tool
  definitions (BEAM-relayed) sharded directly without the compiler. `compiler_wasm` may be empty
  when only `host_tools` are injected.
  """
  @spec inject_catalog(
          vm(),
          binary(),
          [connection_def()],
          [String.t()],
          [map()],
          non_neg_integer()
        ) ::
          {:ok, catalog_status() | nil} | {:error, reason()}
  def inject_catalog(vm, compiler_wasm, connections, tools, host_tools, generation)
      when is_binary(compiler_wasm) and is_list(connections) and is_list(tools) and
             is_list(host_tools) and is_integer(generation) and generation >= 0 do
    with {:ok, connections} <- catalog_connections_arg(connections),
         {:ok, tools} <- tools_arg(tools),
         {:ok, host_tools} <- host_tools_arg(host_tools) do
      case inject_catalog_nif(vm, compiler_wasm, generation, tools, host_tools, connections) do
        {:ok, nil} ->
          {:ok, nil}

        {:ok, {generation, digest, tools}} ->
          {:ok, %{generation: generation, digest: digest, tools: tools}}

        {:error, _reason} = err ->
          err
      end
    end
  end

  def inject_catalog(_vm, _compiler_wasm, _connections, _tools, _host_tools, _generation),
    do:
      {:error,
       "inject_catalog expects vm, compiler wasm, connections, tools, host_tools, and generation"}

  @doc "Drain the next outbound egress relay event, if any."
  @spec relay_next(vm()) :: {:ok, relay_event() | nil} | {:error, reason()}
  def relay_next(vm) do
    case relay_next_nif(vm) do
      {:ok, nil} -> {:ok, nil}
      {:ok, frame} when is_binary(frame) -> decode_relay_event(frame)
      {:ok, other} -> {:error, "invalid relay event frame #{inspect(other)}"}
      {:error, _reason} = err -> err
    end
  end

  @doc "Answer an HTTP relay event with a complete buffered response."
  @spec relay_http_respond(
          vm(),
          integer(),
          non_neg_integer(),
          String.t(),
          [{String.t(), String.t()}],
          binary()
        ) ::
          :ok | {:error, reason()}
  def relay_http_respond(vm, handle, status, reason, headers, body)
      when is_integer(handle) and handle > 0 and is_integer(status) and status >= 100 and
             status <= 999 and is_binary(reason) and is_list(headers) and is_binary(body) do
    with {:ok, head} <- http_head(status, reason, headers) do
      relay_http_respond_nif(vm, handle, true, head, body)
    end
  end

  def relay_http_respond(_vm, _handle, _status, _reason, _headers, _body),
    do: {:error, "relay_http_respond expects handle, status, reason, headers, and binary body"}

  @doc "Fail an HTTP relay event."
  @spec relay_http_fail(vm(), integer()) :: :ok | {:error, reason()}
  def relay_http_fail(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_http_respond_nif(vm, handle, false, "", "")

  def relay_http_fail(_vm, _handle), do: {:error, "relay_http_fail expects a positive handle"}

  @doc "Answer a host_call relay event."
  @spec relay_host_call_respond(vm(), integer(), binary()) :: :ok | {:error, reason()}
  def relay_host_call_respond(vm, handle, result)
      when is_integer(handle) and handle > 0 and is_binary(result),
      do: relay_host_call_respond_nif(vm, handle, true, result)

  def relay_host_call_respond(_vm, _handle, _result),
    do: {:error, "relay_host_call_respond expects a positive handle and binary result"}

  @doc "Fail a host_call relay event."
  @spec relay_host_call_fail(vm(), integer()) :: :ok | {:error, reason()}
  def relay_host_call_fail(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_host_call_respond_nif(vm, handle, false, "")

  def relay_host_call_fail(_vm, _handle),
    do: {:error, "relay_host_call_fail expects a positive handle"}

  @doc "Answer a persist relay event with the exact async-persist body bytes."
  @spec relay_persist_respond(vm(), integer(), binary()) :: :ok | {:error, reason()}
  def relay_persist_respond(vm, handle, body)
      when is_integer(handle) and handle > 0 and is_binary(body),
      do: relay_persist_respond_nif(vm, handle, true, body)

  def relay_persist_respond(_vm, _handle, _body),
    do: {:error, "relay_persist_respond expects a positive handle and binary body"}

  @doc "Fail a persist relay event."
  @spec relay_persist_fail(vm(), integer()) :: :ok | {:error, reason()}
  def relay_persist_fail(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_persist_respond_nif(vm, handle, false, "")

  def relay_persist_fail(_vm, _handle),
    do: {:error, "relay_persist_fail expects a positive handle"}

  @doc """
  Answer a `tool_approval` relay event: allow or deny the destructive connection call the host parked
  on. `remember_session` caches an allow for the exact connection/method/url for the VM's lifetime.
  """
  @spec relay_tool_approval_respond(vm(), integer(), boolean(), boolean()) ::
          :ok | {:error, reason()}
  def relay_tool_approval_respond(vm, handle, allow, remember_session \\ false)

  def relay_tool_approval_respond(vm, handle, allow, remember_session)
      when is_integer(handle) and handle > 0 and is_boolean(allow) and
             is_boolean(remember_session),
      do: relay_tool_approval_respond_nif(vm, handle, allow, remember_session)

  def relay_tool_approval_respond(_vm, _handle, _allow, _remember),
    do:
      {:error, "relay_tool_approval_respond expects a positive handle and boolean allow/remember"}

  @doc "Mark a WebSocket relay connection as opened."
  @spec relay_ws_open(vm(), integer()) :: :ok | {:error, reason()}
  def relay_ws_open(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_ws_open_nif(vm, handle, true)

  def relay_ws_open(_vm, _handle), do: {:error, "relay_ws_open expects a positive handle"}

  @doc "Fail a WebSocket relay connection."
  @spec relay_ws_fail(vm(), integer()) :: :ok | {:error, reason()}
  def relay_ws_fail(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_ws_open_nif(vm, handle, false)

  def relay_ws_fail(_vm, _handle), do: {:error, "relay_ws_fail expects a positive handle"}

  @doc "Push one received WebSocket message into a relay connection."
  @spec relay_ws_push(vm(), integer(), binary()) :: :ok | {:error, reason()}
  def relay_ws_push(vm, handle, data) when is_integer(handle) and handle > 0 and is_binary(data),
    do: relay_ws_push_nif(vm, handle, data)

  def relay_ws_push(_vm, _handle, _data),
    do: {:error, "relay_ws_push expects a positive handle and binary data"}

  @doc "Mark a WebSocket relay connection as closed by the peer."
  @spec relay_ws_close(vm(), integer()) :: :ok | {:error, reason()}
  def relay_ws_close(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_ws_close_nif(vm, handle)

  def relay_ws_close(_vm, _handle), do: {:error, "relay_ws_close expects a positive handle"}

  @doc false
  def boot_nif(
        _wasm,
        _base_image,
        _layers,
        _deterministic,
        _contract,
        _workers,
        _net,
        _net_real,
        _connections,
        _connection_policies,
        _tool_approval,
        _host_call,
        _persist
      ),
      do: nif_not_loaded()

  @doc false
  def restore_nif(
        _wasm,
        _snapshot,
        _deterministic,
        _workers,
        _net,
        _net_real,
        _connections,
        _connection_policies,
        _tool_approval,
        _host_call,
        _persist
      ),
      do: nif_not_loaded()

  @doc false
  def tick_nif(_vm), do: nif_not_loaded()

  @doc false
  def send_input_nif(_vm, _bytes), do: nif_not_loaded()

  @doc false
  def exec_nif(_vm, _cmd, _max_ticks, _cwd, _env, _stdin_present, _stdin), do: nif_not_loaded()

  @doc false
  def exec_start_nif(_vm, _cmd, _cwd, _env, _stdin_present, _stdin), do: nif_not_loaded()

  @doc false
  def exec_poll_nif(_vm, _job), do: nif_not_loaded()

  @doc false
  def exec_stdout_peek_nif(_vm, _job), do: nif_not_loaded()

  @doc false
  def exec_cancel_nif(_vm, _job), do: nif_not_loaded()

  @doc false
  def svc_call_nif(_vm, _service, _request), do: nif_not_loaded()

  @doc false
  def read_file_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def write_file_nif(_vm, _path, _data), do: nif_not_loaded()

  @doc false
  def readdir_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def stat_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def readlink_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def mkdir_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def unlink_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def chmod_nif(_vm, _path, _mode), do: nif_not_loaded()

  @doc false
  def symlink_nif(_vm, _target, _link), do: nif_not_loaded()

  @doc false
  def mount_nif(_vm, _path, _read_only), do: nif_not_loaded()

  @doc false
  def unmount_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def commit_layer_nif(_vm), do: nif_not_loaded()

  @doc false
  def status_nif(_vm), do: nif_not_loaded()

  @doc false
  def snapshot_nif(_vm), do: nif_not_loaded()

  @doc false
  def inject_catalog_nif(_vm, _compiler_wasm, _generation, _tools, _host_tools, _connections),
    do: nif_not_loaded()

  @doc false
  def relay_next_nif(_vm), do: nif_not_loaded()

  @doc false
  def relay_http_respond_nif(_vm, _handle, _ok, _head, _body), do: nif_not_loaded()

  @doc false
  def relay_host_call_respond_nif(_vm, _handle, _ok, _result), do: nif_not_loaded()

  @doc false
  def relay_tool_approval_respond_nif(_vm, _handle, _allow, _remember), do: nif_not_loaded()

  @doc false
  def relay_persist_respond_nif(_vm, _handle, _ok, _body), do: nif_not_loaded()

  @doc false
  def relay_ws_open_nif(_vm, _handle, _ok), do: nif_not_loaded()

  @doc false
  def relay_ws_push_nif(_vm, _handle, _data), do: nif_not_loaded()

  @doc false
  def relay_ws_close_nif(_vm, _handle), do: nif_not_loaded()

  defp exec_options(opts) when is_list(opts) or is_map(opts) do
    with {:ok, cwd} <- normalize_cwd(opt(opts, :cwd, nil)),
         {:ok, env} <- normalize_env(opt(opts, :env, nil)),
         {:ok, stdin_present, stdin} <- normalize_stdin(opt(opts, :stdin, nil)) do
      {:ok, {cwd, env, stdin_present, stdin}}
    end
  end

  defp exec_options(_opts), do: {:error, "exec options must be a keyword list or map"}

  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp opt(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)

  defp normalize_cwd(nil), do: {:ok, ""}
  defp normalize_cwd(cwd) when is_binary(cwd), do: {:ok, cwd}
  defp normalize_cwd(_cwd), do: {:error, "exec cwd must be a binary"}

  defp normalize_env(nil), do: {:ok, []}
  defp normalize_env(env) when is_map(env), do: normalize_env_pairs(Map.to_list(env))
  defp normalize_env(env) when is_list(env), do: normalize_env_pairs(env)

  defp normalize_env(_env),
    do: {:error, "exec env must be a map or list of binary key/value pairs"}

  defp normalize_env_pairs(pairs) do
    case Enum.reduce_while(pairs, {:ok, []}, fn
           {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
             {:cont, {:ok, [{key, value} | acc]}}

           _entry, _acc ->
             {:halt, {:error, "exec env must be a map or list of binary key/value pairs"}}
         end) do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_stdin(nil), do: {:ok, false, ""}
  defp normalize_stdin(stdin) when is_binary(stdin), do: {:ok, true, stdin}
  defp normalize_stdin(_stdin), do: {:error, "exec stdin must be a binary"}

  defp boot_args(base_image, opts) do
    with {:ok, layers} <- layers_arg(opts),
         :ok <- exclusive_base_or_layers(base_image, layers),
         {:ok, deterministic} <- boolean_arg(opts, :deterministic, false),
         {:ok, contract} <- contract_arg(opts),
         {:ok, workers} <- workers_arg(opts),
         {:ok, net, host_call, persist} <- capability_args(opts),
         {:ok, connection_policies} <- connection_policies_arg(opts),
         {:ok, tool_approval} <- tool_approval_arg(opts) do
      {:ok, layers, deterministic, contract, workers, net, connection_policies, tool_approval,
       host_call, persist}
    end
  end

  defp restore_args(opts) do
    with {:ok, deterministic} <- boolean_arg(opts, :deterministic, false),
         {:ok, workers} <- workers_arg(opts),
         {:ok, net, host_call, persist} <- capability_args(opts),
         {:ok, connection_policies} <- connection_policies_arg(opts),
         {:ok, tool_approval} <- tool_approval_arg(opts) do
      {:ok, deterministic, workers, net, connection_policies, tool_approval, host_call, persist}
    end
  end

  defp layers_arg(opts) do
    case Keyword.get(opts, :layers, []) do
      layers when is_list(layers) ->
        if Enum.all?(layers, &is_binary/1) do
          {:ok, layers}
        else
          {:error, "layers must be a list of binaries"}
        end

      _other ->
        {:error, "layers must be a list of binaries"}
    end
  end

  defp exclusive_base_or_layers(nil, _layers), do: :ok
  defp exclusive_base_or_layers(_base_image, []), do: :ok

  defp exclusive_base_or_layers(_base_image, _layers),
    do: {:error, "base_image and layers are mutually exclusive"}

  defp boolean_arg(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, "#{key} must be a boolean"}
    end
  end

  defp contract_arg(opts) do
    case Keyword.get(opts, :contract, nil) do
      nil ->
        {:ok, nil}

      {tier, budget_mib, fuel}
      when is_integer(tier) and is_integer(budget_mib) and is_integer(fuel) ->
        {:ok, {tier, budget_mib, fuel}}

      _other ->
        {:error, "contract must be nil or {tier, budget_mib, fuel}"}
    end
  end

  defp workers_arg(opts) do
    case Keyword.get(opts, :workers, nil) do
      nil -> {:ok, nil}
      workers when is_integer(workers) and workers >= 0 -> {:ok, workers}
      _other -> {:error, "workers must be nil or a non-negative integer"}
    end
  end

  defp capability_args(opts) do
    with {:ok, net} <- net_arg(opts),
         {:ok, host_call} <- relay_mode_arg(opts, :host_call),
         {:ok, persist} <- persist_mode_arg(opts) do
      {:ok, net, host_call == :relay, persist == :relay}
    end
  end

  defp net_arg(opts) do
    separate_connections? = Keyword.has_key?(opts, :connections)

    with {:ok, mode, inline_connections} <- net_mode_arg(Keyword.get(opts, :net, :deny)),
         {:ok, configured_connections} <- connections_arg(Keyword.get(opts, :connections, [])),
         :ok <- connection_location_arg(mode, inline_connections, separate_connections?) do
      connections =
        if inline_connections == [], do: configured_connections, else: inline_connections

      case {mode, connections} do
        {:deny, []} -> {:ok, {false, false, []}}
        {:relay, []} -> {:ok, {true, false, []}}
        {:real, connections} -> {:ok, {false, true, connections}}
        {_mode, _connections} -> {:error, "connections require net: :real"}
      end
    end
  end

  defp net_mode_arg(:deny), do: {:ok, :deny, []}
  defp net_mode_arg(:relay), do: {:ok, :relay, []}
  defp net_mode_arg(:real), do: {:ok, :real, []}

  defp net_mode_arg({:real, connections}) do
    with {:ok, connections} <- connections_arg(connections) do
      {:ok, :real, connections}
    end
  end

  defp net_mode_arg(_other),
    do: {:error, "net must be :deny, :relay, :real, or {:real, connections}"}

  defp connection_location_arg(:real, connections, true) when connections != [],
    do:
      {:error,
       "connections must be specified either in net: {:real, ...} or :connections, not both"}

  defp connection_location_arg(_mode, _connections, _separate_connections?), do: :ok

  defp connections_arg(connections) when is_list(connections) do
    Enum.reduce_while(connections, {:ok, []}, fn entry, {:ok, acc} ->
      case connection_arg(entry) do
        {:ok, connection} -> {:cont, {:ok, [connection | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = err -> err
    end
  end

  defp connections_arg(_other), do: {:error, "connections must be a list"}

  defp connection_arg({ref, auth}) when is_binary(ref) do
    with {:ok, kind, a, b} <- connection_auth_arg(auth) do
      {:ok, {ref, kind, a, b, []}}
    end
  end

  defp connection_arg({ref, auth, origins}) when is_binary(ref) do
    with {:ok, kind, a, b} <- connection_auth_arg(auth),
         {:ok, origins} <- connection_origins_arg(origins) do
      {:ok, {ref, kind, a, b, origins}}
    end
  end

  defp connection_arg(%{ref: ref, auth: auth} = entry) when is_binary(ref),
    do: connection_arg({ref, auth, Map.get(entry, :origins, [])})

  defp connection_arg(%{"ref" => ref, "auth" => auth} = entry) when is_binary(ref),
    do: connection_arg({ref, auth, Map.get(entry, "origins", [])})

  defp connection_arg(_other),
    do:
      {:error, "connection must be {ref, auth}, {ref, auth, origins}, or %{ref: ref, auth: auth}"}

  defp connection_origins_arg(origins) when is_list(origins) do
    if Enum.all?(origins, &is_binary/1) do
      {:ok, origins}
    else
      {:error, "connection origins must be a list of binaries"}
    end
  end

  defp connection_origins_arg(_other),
    do: {:error, "connection origins must be a list of binaries"}

  defp connection_auth_arg(:none), do: {:ok, "none", "", ""}
  defp connection_auth_arg({:none}), do: {:ok, "none", "", ""}
  defp connection_auth_arg({:bearer, token}) when is_binary(token), do: {:ok, "bearer", token, ""}

  defp connection_auth_arg({:header, name, value}) when is_binary(name) and is_binary(value),
    do: {:ok, "header", name, value}

  defp connection_auth_arg({:query, name, value}) when is_binary(name) and is_binary(value),
    do: {:ok, "query", name, value}

  defp connection_auth_arg(%{kind: :none}), do: {:ok, "none", "", ""}

  defp connection_auth_arg(%{kind: :bearer, token: token}) when is_binary(token),
    do: {:ok, "bearer", token, ""}

  defp connection_auth_arg(%{kind: :header, name: name, value: value})
       when is_binary(name) and is_binary(value),
       do: {:ok, "header", name, value}

  defp connection_auth_arg(%{kind: :query, name: name, value: value})
       when is_binary(name) and is_binary(value),
       do: {:ok, "query", name, value}

  defp connection_auth_arg(%{"kind" => "none"}), do: {:ok, "none", "", ""}

  defp connection_auth_arg(%{"kind" => "bearer", "token" => token}) when is_binary(token),
    do: {:ok, "bearer", token, ""}

  defp connection_auth_arg(%{"kind" => "header", "name" => name, "value" => value})
       when is_binary(name) and is_binary(value),
       do: {:ok, "header", name, value}

  defp connection_auth_arg(%{"kind" => "query", "name" => name, "value" => value})
       when is_binary(name) and is_binary(value),
       do: {:ok, "query", name, value}

  defp connection_auth_arg(_other),
    do: {:error, "connection auth must be none, bearer, header, or query"}

  defp connection_policies_arg(opts) do
    rules = Keyword.get(opts, :connection_policies, Keyword.get(opts, :policies, []))

    if is_list(rules) do
      Enum.reduce_while(rules, {:ok, []}, fn rule, {:ok, acc} ->
        case connection_policy_rule_arg(rule) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, _reason} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        {:error, _reason} = err -> err
      end
    else
      {:error, "connection_policies must be a list"}
    end
  end

  defp connection_policy_rule_arg({owner, pattern, action}) when is_binary(pattern) do
    with {:ok, owner} <- connection_policy_owner_arg(owner),
         {:ok, action} <- connection_policy_action_arg(action) do
      {:ok, {owner, pattern, action}}
    end
  end

  defp connection_policy_rule_arg(%{owner: owner, pattern: pattern, action: action})
       when is_binary(pattern),
       do: connection_policy_rule_arg({owner, pattern, action})

  defp connection_policy_rule_arg(%{"owner" => owner, "pattern" => pattern, "action" => action})
       when is_binary(pattern),
       do: connection_policy_rule_arg({owner, pattern, action})

  defp connection_policy_rule_arg(_other),
    do: {:error, "connection policy rule must be {owner, pattern, action}"}

  defp connection_policy_owner_arg(owner) when owner in [:org, "org"], do: {:ok, "org"}
  defp connection_policy_owner_arg(owner) when owner in [:user, "user"], do: {:ok, "user"}

  defp connection_policy_owner_arg(_other),
    do: {:error, "connection policy owner must be :org or :user"}

  defp connection_policy_action_arg(action) when action in [:approve, "approve"],
    do: {:ok, "approve"}

  defp connection_policy_action_arg(action)
       when action in [:require_approval, "require_approval"],
       do: {:ok, "require_approval"}

  defp connection_policy_action_arg(action) when action in [:block, "block"], do: {:ok, "block"}

  defp connection_policy_action_arg(_other),
    do: {:error, "connection policy action must be :approve, :require_approval, or :block"}

  defp tool_approval_arg(opts) do
    case Keyword.get(opts, :tool_approval, :deny) do
      :deny -> {:ok, false}
      :relay -> {:ok, true}
      _other -> {:error, "tool_approval must be :deny or :relay"}
    end
  end

  defp catalog_connections_arg(connections) do
    Enum.reduce_while(connections, {:ok, []}, fn entry, {:ok, acc} ->
      case catalog_connection_arg(entry) do
        {:ok, connection} -> {:cont, {:ok, [connection | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = err -> err
    end
  end

  defp catalog_connection_arg({ref, _auth}) when is_binary(ref),
    do: {:ok, {ref, "none", "", {"", "", "", ""}, []}}

  defp catalog_connection_arg({ref, _auth, _origins}) when is_binary(ref),
    do: {:ok, {ref, "none", "", {"", "", "", ""}, []}}

  defp catalog_connection_arg(%{ref: ref} = entry) when is_binary(ref),
    do: catalog_connection_from_map(ref, entry)

  defp catalog_connection_arg(%{"ref" => ref} = entry) when is_binary(ref),
    do: catalog_connection_from_map(ref, entry)

  defp catalog_connection_arg(_other),
    do: {:error, "catalog connection must include a binary ref"}

  defp catalog_connection_from_map(ref, entry) do
    with {:ok, tools} <- tools_arg(map_get_any(entry, [:tools, "tools"], [])),
         {:ok, spec} <- catalog_spec_arg(map_get_any(entry, [:spec, "spec"], nil)) do
      {:ok, catalog_connection_tuple(ref, spec, tools)}
    end
  end

  # The catalog connection carries only the spec/tool selection. The credential + egress origins live once
  # in the boot net connections (the egress owner), which the host reads for live discovery via the
  # connection registry — they are not duplicated onto the inject path.
  defp catalog_connection_tuple(ref, nil, tools), do: {ref, "none", "", {"", "", "", ""}, tools}

  defp catalog_connection_tuple(ref, {kind, payload, opts}, tools) do
    {
      ref,
      kind,
      payload,
      {
        catalog_opt(opts, :source_format),
        catalog_opt(opts, :format),
        catalog_opt(opts, :base_url),
        catalog_opt(opts, :endpoint)
      },
      tools
    }
  end

  defp catalog_spec_arg(nil), do: {:ok, nil}
  defp catalog_spec_arg({:bytes, bytes}) when is_binary(bytes), do: {:ok, {"bytes", bytes, %{}}}

  defp catalog_spec_arg({:bytes, bytes, opts}) when is_binary(bytes),
    do: {:ok, {"bytes", bytes, opts}}

  defp catalog_spec_arg({:path, path}) when is_binary(path), do: {:ok, {"path", path, %{}}}
  defp catalog_spec_arg({:path, path, opts}) when is_binary(path), do: {:ok, {"path", path, opts}}
  defp catalog_spec_arg({:url, url}) when is_binary(url), do: {:ok, {"url", url, %{}}}
  defp catalog_spec_arg({:url, url, opts}) when is_binary(url), do: {:ok, {"url", url, opts}}

  defp catalog_spec_arg(spec) when is_map(spec) do
    cond do
      is_binary(map_get_any(spec, [:bytes, "bytes"], nil)) ->
        {:ok, {"bytes", map_get_any(spec, [:bytes, "bytes"], nil), spec}}

      is_binary(map_get_any(spec, [:path, "path"], nil)) ->
        {:ok, {"path", map_get_any(spec, [:path, "path"], nil), spec}}

      is_binary(map_get_any(spec, [:url, "url"], nil)) ->
        {:ok, {"url", map_get_any(spec, [:url, "url"], nil), spec}}

      true ->
        {:error, "catalog spec map must include bytes, path, or url"}
    end
  end

  defp catalog_spec_arg(_other),
    do: {:error, "catalog spec must be nil, {:bytes|:path|:url, value}, or a spec map"}

  defp catalog_opt(opts, key) do
    value = map_get_any(opts, [key, Atom.to_string(key)], nil)

    cond do
      is_binary(value) -> value
      is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      is_nil(value) -> ""
      true -> ""
    end
  end

  defp tools_arg(tools) when is_list(tools) do
    if Enum.all?(tools, &is_binary/1) do
      {:ok, tools}
    else
      {:error, "tools must be a list of binaries"}
    end
  end

  defp tools_arg(_other), do: {:error, "tools must be a list of binaries"}

  # Each host tool -> the NIF 7-tuple (address, description, binding_name, args_mode,
  # input_schema_json, output_schema_json, annotations_json). Schema/annotation fields are
  # JSON strings ("" when absent) — the server has no JSON encoder dependency.
  defp host_tools_arg(host_tools) when is_list(host_tools) do
    Enum.reduce_while(host_tools, {:ok, []}, fn entry, {:ok, acc} ->
      case host_tool_arg(entry) do
        {:ok, tool} -> {:cont, {:ok, [tool | acc]}}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = err -> err
    end
  end

  defp host_tool_arg(entry) when is_map(entry) do
    name = map_get_any(entry, [:name, "name"], nil)

    cond do
      not (is_binary(name) and name != "") ->
        {:error, "host tool must include a non-empty binary :name"}

      true ->
        with {:ok, input_json} <- host_tool_json(entry, [:input_schema, "input_schema"]),
             {:ok, output_json} <- host_tool_json(entry, [:output_schema, "output_schema"]),
             {:ok, annot_json} <- host_tool_json(entry, [:annotations, "annotations"]) do
          {:ok,
           {
             map_get_any(entry, [:address, "address"], default_host_address(name)),
             to_binary(map_get_any(entry, [:description, "description"], "")),
             name,
             host_tool_args_mode(map_get_any(entry, [:args, "args"], "json")),
             input_json,
             output_json,
             annot_json
           }}
        end
    end
  end

  defp host_tool_arg(_other), do: {:error, "host tool must be a map with at least a :name"}

  defp host_tool_json(entry, keys) do
    case map_get_any(entry, keys, nil) do
      nil -> {:ok, ""}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, "host tool #{hd(keys)} must be a JSON string"}
    end
  end

  defp host_tool_args_mode(mode) when mode in ["json", "raw"], do: mode
  defp host_tool_args_mode(:json), do: "json"
  defp host_tool_args_mode(:raw), do: "raw"
  defp host_tool_args_mode(_other), do: "json"

  defp default_host_address(name) do
    tail =
      name
      |> String.split(~r/[^A-Za-z0-9_-]+/, trim: true)
      |> Enum.join(".")

    tail = if tail == "", do: "tool", else: tail
    "host.org.main." <> tail
  end

  defp to_binary(value) when is_binary(value), do: value
  defp to_binary(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp to_binary(_other), do: ""

  defp map_get_any(map, keys, default) when is_map(map) do
    Enum.find_value(keys, default, fn key ->
      if Map.has_key?(map, key), do: Map.get(map, key), else: nil
    end)
  end

  defp map_get_any(list, keys, default) when is_list(list) do
    Enum.find_value(keys, default, fn key ->
      if Keyword.has_key?(list, key), do: Keyword.get(list, key), else: nil
    end)
  end

  defp map_get_any(_other, _keys, default), do: default

  defp relay_mode_arg(opts, key) do
    case Keyword.get(opts, key, :deny) do
      mode when mode in [:deny, :relay] -> {:ok, mode}
      _other -> {:error, "#{key} must be :deny or :relay"}
    end
  end

  defp persist_mode_arg(opts) do
    case Keyword.get(opts, :persist, :deny) do
      mode when mode in [:deny, :relay] -> {:ok, mode}
      _other -> {:error, "persist must be :deny or :relay"}
    end
  end

  defp http_head(status, reason, headers) do
    with :ok <- headers_arg(headers) do
      head =
        IO.iodata_to_binary([
          Integer.to_string(status),
          " ",
          reason,
          "\r\n",
          Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
          "\r\n"
        ])

      {:ok, head}
    end
  end

  defp headers_arg(headers) do
    if Enum.all?(headers, fn
         {name, value} -> is_binary(name) and is_binary(value)
         _other -> false
       end) do
      :ok
    else
      {:error, "headers must be {binary_name, binary_value} pairs"}
    end
  end

  defp decode_relay_event(frame) when is_binary(frame) do
    with {:ok, %{kind: kind, handle: handle} = event} <- Control.decode_relay_event(frame),
         :ok <- relay_handle(handle) do
      relay_event(kind, handle, Map.drop(event, [:kind, :handle]))
    else
      {:error, reason} when is_binary(reason) -> {:error, "invalid relay event frame: #{reason}"}
      {:error, _reason} = err -> err
    end
  end

  defp relay_handle(handle) when handle > 0, do: :ok
  defp relay_handle(handle), do: {:error, "invalid relay event handle #{inspect(handle)}"}

  defp relay_event("http", handle, fields) do
    with :ok <- relay_fields("http", fields, [:request]),
         {:ok, request} <- relay_required("http", fields, :request) do
      {:ok, %{kind: :http, handle: handle, request: request}}
    end
  end

  defp relay_event("host_call", handle, fields) do
    with :ok <- relay_fields("host_call", fields, [:name, :body]),
         {:ok, name} <- relay_required("host_call", fields, :name),
         {:ok, body} <- relay_required("host_call", fields, :body) do
      {:ok, %{kind: :host_call, handle: handle, name: name, body: body}}
    end
  end

  defp relay_event("persist_get", handle, fields) do
    with :ok <- relay_fields("persist_get", fields, [:key]),
         {:ok, key} <- relay_required("persist_get", fields, :key) do
      {:ok, %{kind: :persist_get, handle: handle, key: key}}
    end
  end

  defp relay_event("persist_put", handle, fields) do
    with :ok <- relay_fields("persist_put", fields, [:key, :value]),
         {:ok, key} <- relay_required("persist_put", fields, :key),
         {:ok, value} <- relay_required("persist_put", fields, :value) do
      {:ok, %{kind: :persist_put, handle: handle, key: key, value: value}}
    end
  end

  defp relay_event("persist_delete", handle, fields) do
    with :ok <- relay_fields("persist_delete", fields, [:key]),
         {:ok, key} <- relay_required("persist_delete", fields, :key) do
      {:ok, %{kind: :persist_delete, handle: handle, key: key}}
    end
  end

  defp relay_event("persist_list", handle, fields) do
    with :ok <- relay_fields("persist_list", fields, [:prefix]),
         {:ok, prefix} <- relay_required("persist_list", fields, :prefix) do
      {:ok, %{kind: :persist_list, handle: handle, prefix: prefix}}
    end
  end

  defp relay_event("ws_connect", handle, fields) do
    with :ok <- relay_fields("ws_connect", fields, [:url]),
         {:ok, url} <- relay_required("ws_connect", fields, :url) do
      {:ok, %{kind: :ws_connect, handle: handle, url: url}}
    end
  end

  defp relay_event("ws_send", handle, fields) do
    with :ok <- relay_fields("ws_send", fields, [:data]),
         {:ok, data} <- relay_required("ws_send", fields, :data) do
      {:ok, %{kind: :ws_send, handle: handle, data: data}}
    end
  end

  defp relay_event("ws_close", handle, fields) do
    with :ok <- relay_fields("ws_close", fields, []) do
      {:ok, %{kind: :ws_close, handle: handle}}
    end
  end

  defp relay_event("tool_approval", handle, fields) do
    with :ok <-
           relay_fields("tool_approval", fields, [
             :connection,
             :method,
             :url,
             :origin,
             :args_digest
           ]),
         {:ok, connection} <- relay_required("tool_approval", fields, :connection),
         {:ok, method} <- relay_required("tool_approval", fields, :method),
         {:ok, url} <- relay_required("tool_approval", fields, :url),
         {:ok, origin} <- relay_required("tool_approval", fields, :origin) do
      {:ok,
       %{
         kind: :tool_approval,
         handle: handle,
         connection: connection,
         method: method,
         url: url,
         origin: origin,
         args_digest: Map.get(fields, :args_digest)
       }}
    end
  end

  defp relay_event(kind, _handle, _fields),
    do: {:error, "unknown relay event kind #{inspect(kind)}"}

  defp relay_fields(kind, fields, allowed) do
    case Enum.find(fields, fn {key, value} -> not is_nil(value) and key not in allowed end) do
      nil -> :ok
      {key, _value} -> {:error, "relay event #{kind} has unexpected #{key}"}
    end
  end

  defp relay_required(kind, fields, key) do
    case Map.fetch(fields, key) do
      {:ok, nil} -> {:error, "relay event #{kind} missing #{key}"}
      {:ok, value} -> {:ok, value}
      :error -> {:error, "relay event #{kind} missing #{key}"}
    end
  end

  defp dir_entry({name, is_dir, is_symlink}),
    do: %{name: name, type: file_type(is_dir, is_symlink)}

  defp file_type(true, _is_symlink), do: :directory
  defp file_type(false, true), do: :symlink
  defp file_type(false, false), do: :file

  # Replaced by the native implementations once the .so loads; raising this means the .so was
  # not found/staged (a deployment error, not a VM error).
  defp nif_not_loaded, do: :erlang.nif_error(:nif_not_loaded)
end
