defmodule AgentOS.Vm do
  @moduledoc """
  One AgentOS VM, owned by exactly one BEAM process — the **actor-per-VM** unit
  described in SYSTEMS.md §13.1.

  ## Why one process per VM

  A VM is a `wasmtime::Store`, which is `Send` but **not `Sync`** — exactly one entity may
  touch it at a time. A GenServer is the natural owner: its mailbox serializes every command,
  so the single-owner invariant holds for free and the NIF's `Mutex` is uncontended. Because
  the kernel's bridge is poll-based, an idle VM has *yielded* and costs ~nothing, so a node
  carries many mostly-idle VMs — and this process does **no background ticking**: it advances
  the kernel only when commanded, which is what keeps idleness free.

  ## Error policy

  The NIF reports host failures as `{:error, reason}` values (not raises). This process turns
  those into policy: a failed boot/restore stops the process cleanly (so the facade's
  get-or-create sees `{:error, …}`, never a half-live VM); a failed `exec`/`snapshot` is
  returned to the caller. A *non-zero command exit* is not an error — `exec/3` returns
  `{:ok, %{exit_code: …}}`.

  ## Blocking

  `exec/3` runs synchronously: the NIF ticks the kernel to completion on a DirtyCpu thread, so
  it never stalls a BEAM scheduler — only *this* actor's mailbox, which is correct (one VM runs
  one command at a time). For streaming or long-running commands, use the structured
  `exec_start/2` + `exec_poll/2` + `exec_stdout_peek/2` lifecycle; it still serializes through
  this actor and reuses the Rust host's control channel.

  ## Egress relay

  P2 keeps the host bridge in Rust but moves egress policy to the owner. `net`,
  `host_call`, and async `persist` can be booted with relay capabilities; during ticks the
  Rust host queues outbound events, and this GenServer exposes drain/answer calls for the
  eventual Phoenix/wire layer.
  """

  use GenServer, restart: :transient

  alias AgentOS.Host.Nif

  @typedoc "A VM address: a tenancy namespace plus a within-namespace key."
  @type id :: {namespace :: String.t(), key :: String.t()}

  # A generous default tick ceiling for a single command. SQLite/typst compiles burn millions
  # of fuel slices; this bounds a runaway command rather than the common case.
  @default_max_ticks 5_000_000
  @default_call_timeout 60_000
  @exec_option_keys [:cwd, :env, :stdin]

  # Bounded terminal scrollback retained in the VM so a reconnecting client can resume the shell
  # stream from its last cursor (the typed socket's Hello `resume`) and a fresh client can render
  # recent history. Capped to avoid reintroducing the unbounded-output flooding the CaptureSink
  # exists to prevent; older bytes are dropped and `shell_base` advances past them.
  @shell_log_cap 262_144

  defstruct [:id, :nif, :booted_at, :last_active_ms, :snapshot_base, shell_log: "", shell_base: 0]

  # ── Client API ────────────────────────────────────────────────────────────

  @doc """
  Start a VM actor. Required `opts`: `:id` (`t:id/0`) and `:wasm` (kernel bytes). Optional:
  `:base_image` (layered tar) or `:snapshot` (restore instead of boot). Blocks until the VM is
  booted and at its prompt, so a started VM is a usable VM.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc "Run `cmd` to completion → `{:ok, %{exit_code, stdout, stderr}}` or `{:error, reason}`."
  @spec exec(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Nif.reason()}
  def exec(server, cmd, opts \\ [])

  def exec(server, cmd, opts) when is_binary(cmd) and is_list(opts) do
    max_ticks = Keyword.get(opts, :max_ticks, @default_max_ticks)
    GenServer.call(server, {:exec, cmd, max_ticks, exec_opts(opts)}, timeout(opts))
  end

  def exec(_server, _cmd, _opts),
    do: {:error, "exec expects a binary command and keyword options"}

  @doc "Start a structured exec job. Poll it with `exec_poll/2`; cancel it with `exec_cancel/2`."
  @spec exec_start(server(), String.t(), keyword()) :: {:ok, integer()} | {:error, Nif.reason()}
  def exec_start(server, cmd, opts \\ [])

  def exec_start(server, cmd, opts) when is_binary(cmd) and is_list(opts),
    do: GenServer.call(server, {:exec_start, cmd, exec_opts(opts)}, timeout(opts))

  def exec_start(_server, _cmd, _opts),
    do: {:error, "exec_start expects a binary command and keyword options"}

  @doc "Poll a structured exec job; `{:ok, nil}` means still running."
  @spec exec_poll(server(), integer(), keyword()) ::
          {:ok, nil | map()} | {:error, Nif.reason()}
  def exec_poll(server, job, opts \\ []),
    do: GenServer.call(server, {:exec_poll, job}, timeout(opts))

  @doc "Read stdout produced so far by a running structured exec job."
  @spec exec_stdout_peek(server(), integer(), keyword()) ::
          {:ok, binary()} | {:error, Nif.reason()}
  def exec_stdout_peek(server, job, opts \\ []),
    do: GenServer.call(server, {:exec_stdout_peek, job}, timeout(opts))

  @doc "Cancel a structured exec job."
  @spec exec_cancel(server(), integer(), keyword()) :: :ok | {:error, Nif.reason()}
  def exec_cancel(server, job, opts \\ []),
    do: GenServer.call(server, {:exec_cancel, job}, timeout(opts))

  @doc "Query shell completions without executing input; offsets are UTF-8 byte positions."
  @spec autocomplete(server(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, Nif.reason()}
  def autocomplete(server, source, cursor, opts \\ [])

  def autocomplete(server, source, cursor, opts)
      when is_binary(source) and is_integer(cursor) and cursor >= 0 and is_list(opts) do
    GenServer.call(server, {:autocomplete, source, cursor, Keyword.take(opts, [:cwd, :env, :limit])}, timeout(opts))
  end

  def autocomplete(_server, _source, _cursor, _opts),
    do: {:error, "autocomplete expects binary source, a non-negative byte cursor, and keyword options"}

  @doc "Call a resident service as host control through the kernel service channel."
  @spec svc_call(server(), String.t(), binary(), keyword()) ::
          {:ok, {integer(), binary()}} | {:error, Nif.reason()}
  def svc_call(server, service, request, opts \\ [])

  def svc_call(server, service, request, opts) when is_binary(service) and is_binary(request),
    do: GenServer.call(server, {:svc_call, service, request}, timeout(opts))

  def svc_call(_server, _service, _request, _opts),
    do: {:error, "svc_call expects a binary service name and request"}

  @doc "Feed terminal input bytes."
  @spec send_input(server(), binary()) :: :ok | {:error, Nif.reason()}
  def send_input(server, bytes) when is_binary(bytes),
    do: GenServer.call(server, {:send_input, bytes})

  def send_input(_server, _bytes), do: {:error, "send_input expects binary bytes"}

  @doc "Drive `n` bounded ticks (default 1): `:running`, `:exited`, or `{:error, reason}`."
  @spec tick(server(), pos_integer()) :: :running | :exited | {:error, Nif.reason()}
  def tick(server, n \\ 1)

  def tick(server, n) when n > 0, do: GenServer.call(server, {:tick, n})

  def tick(_server, _n), do: {:error, "tick expects a positive integer count"}

  @doc "Drain the terminal output captured since the last drain."
  @spec take_output(server()) :: binary()
  def take_output(server), do: GenServer.call(server, :take_output)

  @doc """
  Terminal scrollback the VM has retained since `cursor` (an absolute byte offset) plus the
  absolute `total` bytes ever produced. Powers typed-socket resume: a reconnecting client passes
  its last cursor and gets exactly the bytes it missed. Bytes older than the retained window
  (`@shell_log_cap`) are dropped, so the returned `from` may exceed `cursor`.
  """
  @spec shell_since(server(), non_neg_integer()) ::
          {:ok, %{bytes: binary(), total: non_neg_integer(), from: non_neg_integer()}}
          | {:error, term()}
  def shell_since(server, cursor) when is_integer(cursor) and cursor >= 0,
    do: GenServer.call(server, {:shell_since, cursor})

  def shell_since(_server, _cursor), do: {:error, "shell_since expects a non-negative cursor"}

  @doc "Snapshot the whole VM into a portable blob (refuses while egress is in flight)."
  @spec snapshot(server(), keyword()) :: {:ok, binary()} | {:error, Nif.reason()}
  def snapshot(server, opts \\ []) do
    mode = Keyword.get(opts, :mode, :full)
    GenServer.call(server, {:snapshot, mode}, @default_call_timeout)
  end

  @doc "The immutable full baseline used by incremental snapshots for this VM."
  @spec snapshot_base(server()) :: binary()
  def snapshot_base(server), do: GenServer.call(server, :snapshot_base)

  @doc "Serialize the live CoW overlay into a content-addressed tar layer."
  @spec commit_layer(server(), keyword()) ::
          {:ok, %{tar: binary(), digest: String.t()}} | {:error, Nif.reason()}
  def commit_layer(server, opts \\ []),
    do: GenServer.call(server, :commit_layer, timeout(opts))

  @doc "Read a whole file through the control channel."
  @spec read_file(server(), String.t(), keyword()) :: {:ok, binary()} | {:error, Nif.reason()}
  def read_file(server, path, opts \\ [])

  def read_file(server, path, opts) when is_binary(path),
    do: GenServer.call(server, {:read_file, path}, timeout(opts))

  def read_file(_server, _path, _opts), do: {:error, "read_file expects a binary path"}

  @doc "Write a whole file through the control channel."
  @spec write_file(server(), String.t(), binary(), keyword()) :: :ok | {:error, Nif.reason()}
  def write_file(server, path, data, opts \\ [])

  def write_file(server, path, data, opts) when is_binary(path) and is_binary(data),
    do: GenServer.call(server, {:write_file, path, data}, timeout(opts))

  def write_file(_server, _path, _data, _opts),
    do: {:error, "write_file expects a binary path and data"}

  @doc "List a directory through the control channel."
  @spec readdir(server(), String.t(), keyword()) ::
          {:ok, [Nif.dir_entry()]} | {:error, Nif.reason()}
  def readdir(server, path, opts \\ [])

  def readdir(server, path, opts) when is_binary(path),
    do: GenServer.call(server, {:readdir, path}, timeout(opts))

  def readdir(_server, _path, _opts), do: {:error, "readdir expects a binary path"}

  @doc "Stat a path through the control channel."
  @spec stat(server(), String.t(), keyword()) :: {:ok, Nif.file_stat()} | {:error, Nif.reason()}
  def stat(server, path, opts \\ [])

  def stat(server, path, opts) when is_binary(path),
    do: GenServer.call(server, {:stat, path}, timeout(opts))

  def stat(_server, _path, _opts), do: {:error, "stat expects a binary path"}

  @doc "Read the target text of a symlink through the control channel."
  @spec readlink(server(), String.t(), keyword()) :: {:ok, binary()} | {:error, Nif.reason()}
  def readlink(server, path, opts \\ [])

  def readlink(server, path, opts) when is_binary(path),
    do: GenServer.call(server, {:readlink, path}, timeout(opts))

  def readlink(_server, _path, _opts), do: {:error, "readlink expects a binary path"}

  @doc "Create a directory through the control channel."
  @spec mkdir(server(), String.t(), keyword()) :: :ok | {:error, Nif.reason()}
  def mkdir(server, path, opts \\ [])

  def mkdir(server, path, opts) when is_binary(path),
    do: GenServer.call(server, {:mkdir, path}, timeout(opts))

  def mkdir(_server, _path, _opts), do: {:error, "mkdir expects a binary path"}

  @doc "Remove a file or empty directory through the control channel."
  @spec unlink(server(), String.t(), keyword()) :: :ok | {:error, Nif.reason()}
  def unlink(server, path, opts \\ [])

  def unlink(server, path, opts) when is_binary(path),
    do: GenServer.call(server, {:unlink, path}, timeout(opts))

  def unlink(_server, _path, _opts), do: {:error, "unlink expects a binary path"}

  @doc "Set POSIX permission bits through the control channel."
  @spec chmod(server(), String.t(), non_neg_integer(), keyword()) :: :ok | {:error, Nif.reason()}
  def chmod(server, path, mode, opts \\ [])

  def chmod(server, path, mode, opts) when is_binary(path) and is_integer(mode),
    do: GenServer.call(server, {:chmod, path, mode}, timeout(opts))

  def chmod(_server, _path, _mode, _opts),
    do: {:error, "chmod expects a binary path and integer mode"}

  @doc "Create a symbolic link through the control channel."
  @spec symlink(server(), String.t(), String.t(), keyword()) :: :ok | {:error, Nif.reason()}
  def symlink(server, target, link, opts \\ [])

  def symlink(server, target, link, opts) when is_binary(target) and is_binary(link),
    do: GenServer.call(server, {:symlink, target, link}, timeout(opts))

  def symlink(_server, _target, _link, _opts),
    do: {:error, "symlink expects binary target and link paths"}

  @doc "Mount a host-call-backed filesystem driver through the control channel."
  @spec mount(server(), String.t(), keyword()) :: :ok | {:error, Nif.reason()}
  def mount(server, path, opts \\ [])

  def mount(server, path, opts) when is_binary(path) do
    read_only = Keyword.get(opts, :read_only, false)

    if is_boolean(read_only) do
      GenServer.call(server, {:mount, path, read_only}, timeout(opts))
    else
      {:error, "mount read_only option must be a boolean"}
    end
  end

  def mount(_server, _path, _opts), do: {:error, "mount expects a binary path"}

  @doc "Unmount a host-backed filesystem driver through the control channel."
  @spec unmount(server(), String.t(), keyword()) :: :ok | {:error, Nif.reason()}
  def unmount(server, path, opts \\ [])

  def unmount(server, path, opts) when is_binary(path),
    do: GenServer.call(server, {:unmount, path}, timeout(opts))

  def unmount(_server, _path, _opts), do: {:error, "unmount expects a binary path"}

  @doc "Liveness/age info."
  @spec info(server()) :: map()
  def info(server), do: GenServer.call(server, :info)

  @doc "Host status from the Rust VM resource."
  @spec status(server()) :: {:ok, Nif.status()} | {:error, Nif.reason()}
  def status(server), do: GenServer.call(server, :status, @default_call_timeout)

  @doc "Drain the next outbound egress relay event, if any."
  @spec egress_next(server(), keyword()) ::
          {:ok, Nif.relay_event() | nil} | {:error, Nif.reason()}
  def egress_next(server, opts \\ []), do: GenServer.call(server, :egress_next, timeout(opts))

  @doc "Answer an HTTP relay event."
  @spec egress_http_respond(
          server(),
          integer(),
          non_neg_integer(),
          String.t(),
          [{String.t(), String.t()}],
          binary(),
          keyword()
        ) ::
          :ok | {:error, Nif.reason()}
  def egress_http_respond(server, handle, status, reason, headers, body, opts \\ [])

  def egress_http_respond(server, handle, status, reason, headers, body, opts)
      when is_integer(handle) and handle > 0 and is_binary(reason) and is_list(headers) and
             is_binary(body) do
    GenServer.call(
      server,
      {:egress_http_respond, handle, status, reason, headers, body},
      timeout(opts)
    )
  end

  def egress_http_respond(_server, _handle, _status, _reason, _headers, _body, _opts),
    do: {:error, "egress_http_respond expects handle, status, reason, headers, and body"}

  @doc "Fail an HTTP relay event."
  @spec egress_http_fail(server(), integer(), keyword()) :: :ok | {:error, Nif.reason()}
  def egress_http_fail(server, handle, opts \\ []),
    do: GenServer.call(server, {:egress_http_fail, handle}, timeout(opts))

  @doc "Answer a host_call relay event."
  @spec egress_host_call_respond(server(), integer(), binary(), keyword()) ::
          :ok | {:error, Nif.reason()}
  def egress_host_call_respond(server, handle, result, opts \\ [])

  def egress_host_call_respond(server, handle, result, opts)
      when is_integer(handle) and handle > 0 and is_binary(result),
      do: GenServer.call(server, {:egress_host_call_respond, handle, result}, timeout(opts))

  def egress_host_call_respond(_server, _handle, _result, _opts),
    do: {:error, "egress_host_call_respond expects a positive handle and binary result"}

  @doc "Fail a host_call relay event."
  @spec egress_host_call_fail(server(), integer(), keyword()) :: :ok | {:error, Nif.reason()}
  def egress_host_call_fail(server, handle, opts \\ []),
    do: GenServer.call(server, {:egress_host_call_fail, handle}, timeout(opts))

  @doc "Answer a tool_approval relay event (allow or deny the parked destructive connection call)."
  @spec egress_tool_approval_respond(server(), integer(), boolean(), boolean(), keyword()) ::
          :ok | {:error, Nif.reason()}
  def egress_tool_approval_respond(server, handle, allow, remember_session \\ false, opts \\ [])

  def egress_tool_approval_respond(server, handle, allow, remember_session, opts)
      when is_integer(handle) and handle > 0 and is_boolean(allow) and
             is_boolean(remember_session),
      do:
        GenServer.call(
          server,
          {:egress_tool_approval_respond, handle, allow, remember_session},
          timeout(opts)
        )

  def egress_tool_approval_respond(_server, _handle, _allow, _remember, _opts),
    do:
      {:error,
       "egress_tool_approval_respond expects a positive handle and boolean allow/remember"}

  @doc "Answer a persist relay event with raw async-persist body bytes."
  @spec egress_persist_respond(server(), integer(), binary(), keyword()) ::
          :ok | {:error, Nif.reason()}
  def egress_persist_respond(server, handle, body, opts \\ [])

  def egress_persist_respond(server, handle, body, opts)
      when is_integer(handle) and handle > 0 and is_binary(body),
      do: GenServer.call(server, {:egress_persist_respond, handle, body}, timeout(opts))

  def egress_persist_respond(_server, _handle, _body, _opts),
    do: {:error, "egress_persist_respond expects a positive handle and binary body"}

  @doc "Fail a persist relay event."
  @spec egress_persist_fail(server(), integer(), keyword()) :: :ok | {:error, Nif.reason()}
  def egress_persist_fail(server, handle, opts \\ []),
    do: GenServer.call(server, {:egress_persist_fail, handle}, timeout(opts))

  @doc "Mark a WebSocket relay event as connected."
  @spec egress_ws_open(server(), integer(), keyword()) :: :ok | {:error, Nif.reason()}
  def egress_ws_open(server, handle, opts \\ []),
    do: GenServer.call(server, {:egress_ws_open, handle}, timeout(opts))

  @doc "Fail a WebSocket relay connection."
  @spec egress_ws_fail(server(), integer(), keyword()) :: :ok | {:error, Nif.reason()}
  def egress_ws_fail(server, handle, opts \\ []),
    do: GenServer.call(server, {:egress_ws_fail, handle}, timeout(opts))

  @doc "Push one received WebSocket message into a relay connection."
  @spec egress_ws_push(server(), integer(), binary(), keyword()) :: :ok | {:error, Nif.reason()}
  def egress_ws_push(server, handle, data, opts \\ [])

  def egress_ws_push(server, handle, data, opts)
      when is_integer(handle) and handle > 0 and is_binary(data),
      do: GenServer.call(server, {:egress_ws_push, handle, data}, timeout(opts))

  def egress_ws_push(_server, _handle, _data, _opts),
    do: {:error, "egress_ws_push expects a positive handle and binary data"}

  @doc "Mark a WebSocket relay connection as closed by the peer."
  @spec egress_ws_close(server(), integer(), keyword()) :: :ok | {:error, Nif.reason()}
  def egress_ws_close(server, handle, opts \\ []),
    do: GenServer.call(server, {:egress_ws_close, handle}, timeout(opts))

  @typep server :: pid() | {:via, module(), term()}

  @doc "The `:via` tuple addressing a VM by id through the registry."
  @spec via(id()) :: {:via, Registry, {module(), id()}}
  def via(id), do: {:via, Registry, {AgentOS.VmRegistry, id}}

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    wasm = Keyword.fetch!(opts, :wasm)

    fresh_boot = Keyword.get(opts, :snapshot) == nil

    result =
      if fresh_boot do
        Nif.boot(wasm, Keyword.get(opts, :base_image), nif_opts(opts))
      else
        Nif.restore(wasm, Keyword.get(opts, :snapshot), nif_opts(opts))
      end

    case result do
      {:ok, nif} ->
        # Inject the catalog only on a fresh boot; a restored snapshot already carries the warm
        # catalog (§4.9), so re-injecting would needlessly recompile and reset the generation.
        catalog_result = if fresh_boot, do: inject_catalog_on_create(nif, opts), else: :ok

        case catalog_result do
          :ok ->
            now = now_ms()

            base_result =
              if fresh_boot do
                Nif.snapshot(nif)
              else
                {:ok, Keyword.get(opts, :base_snapshot, Keyword.fetch!(opts, :snapshot))}
              end

            case base_result do
              {:ok, base} ->
                {:ok,
                 %__MODULE__{
                   id: Keyword.fetch!(opts, :id),
                   nif: nif,
                   booted_at: now,
                   last_active_ms: now,
                   snapshot_base: base
                 }}

              {:error, reason} ->
                {:stop, "failed to capture snapshot baseline: #{reason}"}
            end

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        # A boot/restore failure is a clean stop, so the caller sees `{:error, reason}` rather
        # than a mailbox for a VM that never came up.
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:exec, cmd, max_ticks, exec_opts}, _from, state) do
    reply =
      case Nif.exec(state.nif, cmd, max_ticks, exec_opts) do
        {:ok, {exit_code, stdout, stderr}} ->
          {:ok, exec_result(exit_code, stdout, stderr)}

        {:error, _reason} = err ->
          err
      end

    {:reply, reply, touch(state)}
  end

  def handle_call({:exec_start, cmd, exec_opts}, _from, state) do
    {:reply, Nif.exec_start(state.nif, cmd, exec_opts), touch(state)}
  end

  def handle_call({:exec_poll, job}, _from, state) do
    reply =
      case Nif.exec_poll(state.nif, job) do
        {:ok, nil} -> {:ok, nil}
        {:ok, {exit_code, stdout, stderr}} -> {:ok, exec_result(exit_code, stdout, stderr)}
        {:error, _reason} = err -> err
      end

    {:reply, reply, touch(state)}
  end

  def handle_call({:exec_stdout_peek, job}, _from, state) do
    {:reply, Nif.exec_stdout_peek(state.nif, job), touch(state)}
  end

  def handle_call({:exec_cancel, job}, _from, state) do
    {:reply, Nif.exec_cancel(state.nif, job), touch(state)}
  end

  def handle_call({:autocomplete, source, cursor, opts}, _from, state) do
    reply =
      case Nif.autocomplete(state.nif, source, cursor, opts) do
        {:ok, {replace_start, replace_end, common_prefix, items, truncated}} ->
          {:ok,
           %{
             replace_start: replace_start,
             replace_end: replace_end,
             common_prefix: common_prefix,
             items:
               Enum.map(items, fn {label, value, kind} ->
                 %{label: label, value: value, kind: kind}
               end),
             truncated: truncated
           }}

        {:error, _reason} = error ->
          error
      end

    {:reply, reply, touch(state)}
  end

  def handle_call({:svc_call, service, request}, _from, state) do
    {:reply, Nif.svc_call(state.nif, service, request), touch(state)}
  end

  def handle_call({:send_input, bytes}, _from, state) do
    {:reply, Nif.send_input(state.nif, bytes), touch(state)}
  end

  def handle_call({:tick, n}, _from, state) do
    {:reply, tick_n(state.nif, n), touch(state)}
  end

  def handle_call(:take_output, _from, state) do
    output = Nif.take_output(state.nif)
    {:reply, output, record_shell_output(state, output)}
  end

  def handle_call({:shell_since, cursor}, _from, state) do
    total = state.shell_base + byte_size(state.shell_log)
    from = cursor |> max(state.shell_base) |> min(total)
    offset = from - state.shell_base
    bytes = binary_part(state.shell_log, offset, byte_size(state.shell_log) - offset)
    {:reply, {:ok, %{bytes: bytes, total: total, from: from}}, state}
  end

  def handle_call({:snapshot, :full}, _from, state) do
    {:reply, Nif.snapshot(state.nif), state}
  end

  def handle_call({:snapshot, :incremental}, _from, state) do
    {:reply, Nif.snapshot_incremental(state.nif, state.snapshot_base), state}
  end

  def handle_call({:snapshot, mode}, _from, state) do
    {:reply, {:error, "snapshot mode must be :full or :incremental, got #{inspect(mode)}"}, state}
  end

  def handle_call(:snapshot_base, _from, state) do
    {:reply, state.snapshot_base, state}
  end

  def handle_call(:commit_layer, _from, state) do
    reply =
      case Nif.commit_layer(state.nif) do
        {:ok, {tar, digest}} -> {:ok, %{tar: tar, digest: digest}}
        {:error, _reason} = err -> err
      end

    {:reply, reply, touch(state)}
  end

  def handle_call({:read_file, path}, _from, state) do
    {:reply, Nif.read_file(state.nif, path), touch(state)}
  end

  def handle_call({:write_file, path, data}, _from, state) do
    {:reply, Nif.write_file(state.nif, path, data), touch(state)}
  end

  def handle_call({:readdir, path}, _from, state) do
    {:reply, Nif.readdir(state.nif, path), touch(state)}
  end

  def handle_call({:stat, path}, _from, state) do
    {:reply, Nif.stat(state.nif, path), touch(state)}
  end

  def handle_call({:readlink, path}, _from, state) do
    {:reply, Nif.readlink(state.nif, path), touch(state)}
  end

  def handle_call({:mkdir, path}, _from, state) do
    {:reply, Nif.mkdir(state.nif, path), touch(state)}
  end

  def handle_call({:unlink, path}, _from, state) do
    {:reply, Nif.unlink(state.nif, path), touch(state)}
  end

  def handle_call({:chmod, path, mode}, _from, state) do
    {:reply, Nif.chmod(state.nif, path, mode), touch(state)}
  end

  def handle_call({:symlink, target, link}, _from, state) do
    {:reply, Nif.symlink(state.nif, target, link), touch(state)}
  end

  def handle_call({:mount, path, read_only}, _from, state) do
    {:reply, Nif.mount(state.nif, path, read_only), touch(state)}
  end

  def handle_call({:unmount, path}, _from, state) do
    {:reply, Nif.unmount(state.nif, path), touch(state)}
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{id: state.id, booted_at: state.booted_at, idle_ms: now_ms() - state.last_active_ms}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, Nif.status(state.nif), state}
  end

  def handle_call(:egress_next, _from, state) do
    {:reply, Nif.relay_next(state.nif), state}
  end

  def handle_call({:egress_http_respond, handle, status, reason, headers, body}, _from, state) do
    reply = Nif.relay_http_respond(state.nif, handle, status, reason, headers, body)
    {:reply, reply, touch(state)}
  end

  def handle_call({:egress_http_fail, handle}, _from, state) do
    {:reply, Nif.relay_http_fail(state.nif, handle), touch(state)}
  end

  def handle_call({:egress_host_call_respond, handle, result}, _from, state) do
    {:reply, Nif.relay_host_call_respond(state.nif, handle, result), touch(state)}
  end

  def handle_call({:egress_host_call_fail, handle}, _from, state) do
    {:reply, Nif.relay_host_call_fail(state.nif, handle), touch(state)}
  end

  def handle_call({:egress_tool_approval_respond, handle, allow, remember_session}, _from, state) do
    {:reply, Nif.relay_tool_approval_respond(state.nif, handle, allow, remember_session),
     touch(state)}
  end

  def handle_call({:egress_persist_respond, handle, body}, _from, state) do
    {:reply, Nif.relay_persist_respond(state.nif, handle, body), touch(state)}
  end

  def handle_call({:egress_persist_fail, handle}, _from, state) do
    {:reply, Nif.relay_persist_fail(state.nif, handle), touch(state)}
  end

  def handle_call({:egress_ws_open, handle}, _from, state) do
    {:reply, Nif.relay_ws_open(state.nif, handle), touch(state)}
  end

  def handle_call({:egress_ws_fail, handle}, _from, state) do
    {:reply, Nif.relay_ws_fail(state.nif, handle), touch(state)}
  end

  def handle_call({:egress_ws_push, handle, data}, _from, state) do
    {:reply, Nif.relay_ws_push(state.nif, handle, data), touch(state)}
  end

  def handle_call({:egress_ws_close, handle}, _from, state) do
    {:reply, Nif.relay_ws_close(state.nif, handle), touch(state)}
  end

  # Tick up to `n` times, stopping early if the kernel exits or errors.
  defp tick_n(_nif, 0), do: :running

  defp tick_n(nif, n) do
    case Nif.tick(nif) do
      {:ok, true} -> tick_n(nif, n - 1)
      {:ok, false} -> :exited
      {:error, _reason} = err -> err
    end
  end

  # Append freshly-drained terminal output to the bounded scrollback, dropping the oldest bytes
  # (and advancing the absolute base past them) once the retained window exceeds the cap.
  defp record_shell_output(state, output) when is_binary(output) and output != "" do
    combined = state.shell_log <> output
    size = byte_size(combined)

    if size <= @shell_log_cap do
      %{state | shell_log: combined}
    else
      drop = size - @shell_log_cap
      <<_dropped::binary-size(^drop), kept::binary>> = combined
      %{state | shell_log: kept, shell_base: state.shell_base + drop}
    end
  end

  defp record_shell_output(state, _output), do: state

  defp touch(state), do: %{state | last_active_ms: now_ms()}
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp nif_opts(opts),
    do:
      Keyword.take(opts, [
        :layers,
        :deterministic,
        :contract,
        :workers,
        :net,
        :connections,
        :connection_policies,
        :policies,
        :tool_approval,
        :host_call,
        :persist,
        :base_snapshot
      ])

  defp timeout(opts), do: Keyword.get(opts, :timeout, @default_call_timeout)

  defp exec_opts(opts), do: Keyword.take(opts, @exec_option_keys)

  defp exec_result(exit_code, stdout, stderr),
    do: %{exit_code: exit_code, stdout: stdout, stderr: stderr}

  # The wasmtime/Elixir host injects the catalog exactly once, at fresh boot (this is the only caller),
  # so this is the catalog's INITIAL commit. `catalog.apply` therefore needs no `base_digest` — there is
  # no prior catalog to lose-update against (the broker treats a missing base as the initial apply). The
  # compare-and-swap base_digest is the JS host's runtime-mutation (`vm.tool`) concern; were runtime
  # re-injection ever added here, this call would need to thread the live digest.
  defp inject_catalog_on_create(nif, opts) do
    connections = Keyword.get(opts, :catalog_connections, Keyword.get(opts, :connections, []))
    host_tools = Keyword.get(opts, :catalog_host_tools, Keyword.get(opts, :host_tools, []))
    tools = Keyword.get(opts, :catalog_tools, Keyword.get(opts, :tools, []))
    generation = Keyword.get(opts, :catalog_generation, 1)

    if connections == [] and host_tools == [] do
      :ok
    else
      with {:ok, compiler_wasm} <- compiler_bytes_for(opts, connections),
           {:ok, _status} <-
             Nif.inject_catalog(nif, compiler_wasm, connections, tools, host_tools, generation) do
        :ok
      end
    end
  end

  # Connection/spec tools are compiled by catalog-compiler.wasm; host-call tools are sharded
  # directly and need no compiler. So host-call-only injection passes an empty compiler binary, and
  # a declared connection without an explicit compiler falls back to MC_CATALOG_COMPILER_WASM — a
  # declared connection is intent enough; the caller need not thread compiler config (finding F).
  defp compiler_bytes_for(opts, connections) do
    case catalog_compiler(opts) do
      {:ok, nil} when connections == [] -> {:ok, <<>>}
      {:ok, nil} -> default_compiler_bytes()
      other -> other
    end
  end

  defp default_compiler_bytes do
    case System.get_env("MC_CATALOG_COMPILER_WASM") do
      nil ->
        {:error,
         "connections require a catalog compiler (set :catalog_compiler_path/:catalog_compiler_wasm or MC_CATALOG_COMPILER_WASM)"}

      path ->
        File.read(path)
    end
  end

  defp catalog_compiler(opts) do
    cond do
      Keyword.has_key?(opts, :catalog_compiler_wasm) ->
        case Keyword.get(opts, :catalog_compiler_wasm) do
          bytes when is_binary(bytes) -> {:ok, bytes}
          _other -> {:error, "catalog_compiler_wasm must be a binary"}
        end

      Keyword.has_key?(opts, :catalog_compiler_path) ->
        case Keyword.get(opts, :catalog_compiler_path) do
          path when is_binary(path) -> File.read(path)
          _other -> {:error, "catalog_compiler_path must be a binary path"}
        end

      Keyword.has_key?(opts, :catalog_compiler) ->
        case Keyword.get(opts, :catalog_compiler) do
          bytes when is_binary(bytes) -> {:ok, bytes}
          _other -> {:error, "catalog_compiler must be wasm bytes"}
        end

      true ->
        {:ok, nil}
    end
  end
end
