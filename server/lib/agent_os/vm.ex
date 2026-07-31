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

  `exec/3` is the direct, synchronous primitive. The served control plane uses
  `exec_interleaved/4`, which drives the same structured exec protocol one bounded tick at a time
  so host-owned egress can make progress between calls. Both paths preserve single ownership.

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

  defstruct [
    :id,
    :nif,
    :booted_at,
    :last_active_ms,
    :snapshot_base,
    # Optional BEAM-owned native git-engine Port (GIT.md PR7+ / PR10c demux).
    :git_engine,
    :git_engine_mon,
    git_mount_path: nil,
    # Host-owned remote policy (never from guest body). See attach_git/2.
    git_allowed_origins: [],
    git_auth: nil,
    # Test-only injectable SmartHttp transport (fixture double).
    git_transport: nil,
    # Inflight async remote host_calls: handle => Task.t(), ref => handle.
    git_tasks: %{},
    git_task_refs: %{},
    shell_log: "",
    shell_base: 0
  ]

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

  @doc """
  PERF-013: enable or disable command-stage instrumentation on this VM.

  Off by default. When on, subsequent `exec`/`run` fill a take-able stage map via
  `take_command_perf/1`.
  """
  @spec set_perf_enabled(server(), boolean()) :: :ok | {:error, Nif.reason()}
  def set_perf_enabled(server, on) when is_boolean(on),
    do: GenServer.call(server, {:set_perf_enabled, on})

  def set_perf_enabled(_server, _on), do: {:error, "set_perf_enabled expects a boolean"}

  @doc "PERF-013: scrub kernel diagnostic counters (disable + zero)."
  @spec scrub_perf(server()) :: :ok | {:error, Nif.reason()}
  def scrub_perf(server), do: GenServer.call(server, :scrub_perf)

  @doc "PERF-013: take the last command's stage breakdown, or `nil` when tracing is off."
  @spec take_command_perf(server()) :: {:ok, map() | nil} | {:error, Nif.reason()}
  def take_command_perf(server), do: GenServer.call(server, :take_command_perf)

  @doc "Run `cmd` to completion → `{:ok, %{exit_code, stdout, stderr}}` or `{:error, reason}`."
  @spec exec(server(), String.t(), keyword()) :: {:ok, map()} | {:error, Nif.reason()}
  def exec(server, cmd, opts \\ [])

  def exec(server, cmd, opts) when is_binary(cmd) and is_list(opts) do
    max_ticks = Keyword.get(opts, :max_ticks, @default_max_ticks)
    GenServer.call(server, {:exec, cmd, max_ticks, exec_opts(opts)}, timeout(opts))
  end

  def exec(_server, _cmd, _opts),
    do: {:error, "exec expects a binary command and keyword options"}

  @doc "Execute one program with literal argv values, without invoking a shell."
  @spec run(server(), String.t(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, Nif.reason()}
  def run(server, program, args, opts \\ [])

  def run(server, program, args, opts)
      when is_binary(program) and is_list(args) and is_list(opts) do
    if Enum.all?(args, &is_binary/1) do
      max_ticks = Keyword.get(opts, :max_ticks, @default_max_ticks)

      GenServer.call(
        server,
        {:run, program, args, max_ticks, exec_opts(opts)},
        timeout(opts)
      )
    else
      {:error, "run expects every argument to be a binary"}
    end
  end

  def run(_server, _program, _args, _opts),
    do: {:error, "run expects a program, argv list, and keyword options"}

  @doc false
  @spec exec_interleaved(server(), String.t(), keyword(), (-> :ok | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def exec_interleaved(server, cmd, opts, on_yield)
      when is_binary(cmd) and is_list(opts) and is_function(on_yield, 0) do
    exec_request_interleaved(
      server,
      fn -> exec_start(server, cmd, opts) end,
      cmd,
      opts,
      on_yield
    )
  end

  def exec_interleaved(_server, _cmd, _opts, _on_yield),
    do: {:error, "exec_interleaved expects a command, keyword options, and a zero-arity callback"}

  @doc false
  @spec run_interleaved(
          server(),
          String.t(),
          [String.t()],
          keyword(),
          (-> :ok | {:error, term()})
        ) :: {:ok, map()} | {:error, term()}
  def run_interleaved(server, program, args, opts, on_yield)
      when is_binary(program) and is_list(args) and is_list(opts) and is_function(on_yield, 0) do
    if Enum.all?(args, &is_binary/1) do
      exec_request_interleaved(
        server,
        fn -> run_start(server, program, args, opts) end,
        program,
        opts,
        on_yield
      )
    else
      {:error, "run_interleaved expects every argument to be a binary"}
    end
  end

  def run_interleaved(_server, _program, _args, _opts, _on_yield),
    do: {:error, "run_interleaved expects a program, argv list, options, and callback"}

  @doc "Start a structured exec job. Poll it with `exec_poll/2`; cancel it with `exec_cancel/2`."
  @spec exec_start(server(), String.t(), keyword()) :: {:ok, integer()} | {:error, Nif.reason()}
  def exec_start(server, cmd, opts \\ [])

  def exec_start(server, cmd, opts) when is_binary(cmd) and is_list(opts),
    do: GenServer.call(server, {:exec_start, cmd, exec_opts(opts)}, timeout(opts))

  def exec_start(_server, _cmd, _opts),
    do: {:error, "exec_start expects a binary command and keyword options"}

  @doc "Start a direct argv exec job. Poll it with `exec_poll/2`; cancel it with `exec_cancel/2`."
  @spec run_start(server(), String.t(), [String.t()], keyword()) ::
          {:ok, integer()} | {:error, Nif.reason()}
  def run_start(server, program, args, opts \\ [])

  def run_start(server, program, args, opts)
      when is_binary(program) and is_list(args) and is_list(opts) do
    if Enum.all?(args, &is_binary/1) do
      GenServer.call(
        server,
        {:run_start, program, args, exec_opts(opts)},
        timeout(opts)
      )
    else
      {:error, "run_start expects every argument to be a binary"}
    end
  end

  def run_start(_server, _program, _args, _opts),
    do: {:error, "run_start expects a program, argv list, and keyword options"}

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
    GenServer.call(
      server,
      {:autocomplete, source, cursor, Keyword.take(opts, [:cwd, :env, :limit])},
      timeout(opts)
    )
  end

  def autocomplete(_server, _source, _cursor, _opts),
    do:
      {:error,
       "autocomplete expects binary source, a non-negative byte cursor, and keyword options"}

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

  @doc "Drive `n` bounded ticks (default 1): `:runnable`, `:waiting`, `:exited`, or an error."
  @spec tick(server(), pos_integer()) ::
          :runnable | :waiting | :exited | {:error, Nif.reason()}
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

  @doc "The full baseline used by incremental snapshots, or nil before one is established."
  @spec snapshot_base(server()) :: binary() | nil
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

  @doc """
  Attach a BEAM-owned native `git-engine` Port for this VM (GIT.md K15/K22).

  Options:
  * `:executable`, `:root`, `:mount_path` (default `"/workspace/repo"`)
  * `:allowed_origins` / `:allow_origins` — host-owned origin allowlist for product
    remotes (empty/missing fails closed; guest body cannot smuggle origins)
  * `:auth` — `%{kind: :none | :bearer | :header, ...}` kept in BEAM only
  * `:transport` — injectable SmartHttp transport (tests / fixture double only)

  Replaces any prior attachment. Stops the previous Port and cancels inflight
  remote host_calls first.
  """
  @spec attach_git(server(), keyword()) :: :ok | {:error, term()}
  def attach_git(server, opts \\ []) when is_list(opts),
    do: GenServer.call(server, {:attach_git, opts}, timeout(opts))

  @doc "Detach and stop the git-engine Port for this VM; fail inflight remote handles."
  @spec detach_git(server(), keyword()) :: :ok
  def detach_git(server, opts \\ []),
    do: GenServer.call(server, :detach_git, timeout(opts))

  @doc """
  If `event` is a host_call for name `\"git\"` or this VM's gitfs mount path,
  claim it and return `:answered`.

  * `name == \"git\"` (remote orch / HTTPS) is **async**: spawn under
    `AgentOS.SidecarTaskSupervisor`, return immediately, then answer via
    `egress_host_call_respond/3` or fail the handle. Host opts come from
    `attach_git/2` (origins/auth/transport) — never from the guest body.
  * Mount-path host_calls (gitfs type-4) stay **synchronous** so single-writer
    Port ordering is preserved.
  """
  @spec try_answer_git_host_call(server(), map(), keyword()) ::
          :answered | :unclaimed | {:error, term()}
  def try_answer_git_host_call(server, event, opts \\ []) when is_map(event),
    do: GenServer.call(server, {:try_answer_git_host_call, event}, timeout(opts))

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

  @doc false
  def egress_next_sidecar(server, opts \\ []),
    do: GenServer.call(server, :egress_next_sidecar, timeout(opts))

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

            base =
              if fresh_boot,
                do: nil,
                else: Keyword.get(opts, :base_snapshot, Keyword.fetch!(opts, :snapshot))

            id = Keyword.fetch!(opts, :id)

            case AgentOS.Sidecars.attach_vm(
                   id,
                   self(),
                   Keyword.get(opts, :sidecars, []),
                   Keyword.get(opts, :sidecar_options, [])
                 ) do
              {:ok, _scope} ->
                state0 = %__MODULE__{
                  id: id,
                  nif: nif,
                  booted_at: now,
                  last_active_ms: now,
                  snapshot_base: base,
                  git_engine: nil,
                  git_mount_path: nil,
                  git_allowed_origins: [],
                  git_auth: nil,
                  git_transport: nil,
                  git_tasks: %{},
                  git_task_refs: %{}
                }

                case maybe_attach_git_on_boot(state0, opts) do
                  {:ok, state} -> {:ok, state}
                  {:error, reason} -> {:stop, reason}
                end

              {:error, reason} ->
                {:stop, "failed to attach sidecars: #{inspect(reason)}"}
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
  def handle_call({:set_perf_enabled, on}, _from, state) do
    {:reply, Nif.set_perf_enabled(state.nif, on), touch(state)}
  end

  def handle_call(:scrub_perf, _from, state) do
    {:reply, Nif.scrub_perf(state.nif), touch(state)}
  end

  def handle_call(:take_command_perf, _from, state) do
    {:reply, Nif.take_command_perf(state.nif), touch(state)}
  end

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

  def handle_call({:run, program, args, max_ticks, exec_opts}, _from, state) do
    reply =
      case Nif.run(state.nif, program, args, max_ticks, exec_opts) do
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

  def handle_call({:run_start, program, args, exec_opts}, _from, state) do
    {:reply, Nif.run_start(state.nif, program, args, exec_opts), touch(state)}
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
    case state.snapshot_base do
      nil ->
        case Nif.snapshot(state.nif) do
          {:ok, base} = reply -> {:reply, reply, %{state | snapshot_base: base}}
          {:error, _reason} = reply -> {:reply, reply, state}
        end

      base ->
        {:reply, Nif.snapshot_incremental(state.nif, base), state}
    end
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

  def handle_call({:attach_git, opts}, _from, state) do
    case do_attach_git(state, opts) do
      {:ok, state2} -> {:reply, :ok, touch(state2)}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:detach_git, _from, state) do
    {:reply, :ok, touch(do_detach_git(state))}
  end

  def handle_call({:try_answer_git_host_call, event}, _from, state) do
    case answer_git_event(state, event) do
      {:answered, state2} -> {:reply, :answered, touch(state2)}
      :unclaimed -> {:reply, :unclaimed, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    {:reply,
     %{
       id: state.id,
       booted_at: state.booted_at,
       idle_ms: now_ms() - state.last_active_ms,
       git_attached: is_pid(state.git_engine) and Process.alive?(state.git_engine),
       git_mount_path: state.git_mount_path,
       git_inflight: map_size(state.git_tasks || %{}),
       git_allowed_origins: state.git_allowed_origins || []
     }, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, Nif.status(state.nif), state}
  end

  def handle_call(:egress_next, _from, state) do
    {:reply, Nif.relay_next(state.nif), state}
  end

  def handle_call(:egress_next_sidecar, _from, state) do
    {:reply, Nif.relay_next_sidecar(state.nif), state}
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

  # Tick exactly `n` times, returning the final work state and stopping early
  # only if the kernel exits or errors.
  defp tick_n(nif, n) do
    case Nif.tick(nif) do
      {:ok, state} when state in [:runnable, :waiting] and n > 1 -> tick_n(nif, n - 1)
      {:ok, state} when state in [:runnable, :waiting, :exited] -> state
      {:error, _reason} = err -> err
    end
  end

  defp exec_request_interleaved(server, start, label, opts, on_yield) do
    max_ticks = Keyword.get(opts, :max_ticks, @default_max_ticks)
    call_timeout = timeout(opts)

    cond do
      not is_integer(max_ticks) or max_ticks < 0 ->
        {:error, "max_ticks must be a non-negative integer"}

      call_timeout != :infinity and (not is_integer(call_timeout) or call_timeout <= 0) ->
        {:error, "timeout must be a positive integer or :infinity"}

      true ->
        deadline =
          if call_timeout == :infinity,
            do: :infinity,
            else: System.monotonic_time(:millisecond) + call_timeout

        with {:ok, job} <- start.() do
          drive_exec(server, job, label, max_ticks, deadline, on_yield)
        end
    end
  end

  defp drive_exec(server, job, cmd, remaining, deadline, on_yield) do
    drive_exec(server, job, cmd, remaining, deadline, on_yield, false)
  end

  defp drive_exec(server, job, cmd, remaining, deadline, on_yield, pace_before_tick) do
    with :ok <- on_yield.() do
      case exec_poll(server, job) do
        {:ok, nil} ->
          drive_running_exec(
            server,
            job,
            cmd,
            remaining,
            deadline,
            on_yield,
            pace_before_tick
          )

        done ->
          done
      end
    else
      {:error, _reason} = error -> cancel_exec(server, job, error)
      other -> cancel_exec(server, job, {:error, {:invalid_exec_yield, other}})
    end
  end

  defp drive_running_exec(server, job, cmd, 0, _deadline, _on_yield, _pace_before_tick),
    do: cancel_exec(server, job, {:error, "exec '#{cmd}' exhausted its tick budget"})

  defp drive_running_exec(
         server,
         job,
         cmd,
         remaining,
         deadline,
         on_yield,
         pace_before_tick
       ) do
    if deadline_expired?(deadline) do
      cancel_exec(server, job, {:error, "exec '#{cmd}' timed out"})
    else
      if pace_before_tick, do: Process.sleep(1)

      case tick(server) do
        :runnable ->
          drive_exec(server, job, cmd, remaining - 1, deadline, on_yield, false)

        :waiting ->
          drive_exec(server, job, cmd, remaining - 1, deadline, on_yield, true)

        :exited ->
          case exec_poll(server, job) do
            {:ok, nil} ->
              cancel_exec(server, job, {:error, "kernel exited before exec '#{cmd}' completed"})

            done ->
              done
          end

        {:error, _reason} = error ->
          cancel_exec(server, job, error)
      end
    end
  end

  defp deadline_expired?(:infinity), do: false
  defp deadline_expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  defp cancel_exec(server, job, error) do
    _ = exec_cancel(server, job)
    error
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

  defp maybe_attach_git_on_boot(state, opts) do
    case Keyword.get(opts, :git) do
      nil ->
        {:ok, state}

      false ->
        {:ok, state}

      true ->
        do_attach_git(state, [])

      git_opts when is_list(git_opts) ->
        do_attach_git(state, git_opts)

      _other ->
        {:error, "git boot option must be true | false | keyword list"}
    end
  end

  defp do_attach_git(state, opts) do
    state = do_detach_git(state)
    mount_path = Keyword.get(opts, :mount_path, "/workspace/repo")
    allowed = git_allowed_origins_from_opts(opts)
    auth = Keyword.get(opts, :auth)
    transport = Keyword.get(opts, :transport)

    # Unlinked start + monitor so engine crash does not kill the VM actor.
    case AgentOS.GitEngine.start(
           executable: Keyword.get(opts, :executable),
           root: Keyword.get(opts, :root),
           mount_path: mount_path
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        read_only = Keyword.get(opts, :read_only, false)

        case Nif.mount(state.nif, mount_path, read_only) do
          :ok ->
            {:ok,
             %{
               state
               | git_engine: pid,
                 git_mount_path: mount_path,
                 git_engine_mon: ref,
                 git_allowed_origins: allowed,
                 git_auth: auth,
                 git_transport: transport
             }}

          {:error, reason} ->
            Process.demonitor(ref, [:flush])
            _ = AgentOS.GitEngine.stop(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp git_allowed_origins_from_opts(opts) do
    case Keyword.get(opts, :allowed_origins, Keyword.get(opts, :allow_origins, [])) do
      list when is_list(list) -> list
      :any -> :any
      _ -> []
    end
  end

  defp do_detach_git(state) do
    state = cancel_git_tasks(state)
    mon = Map.get(state, :git_engine_mon)
    pid = Map.get(state, :git_engine)
    path = Map.get(state, :git_mount_path)

    if is_reference(mon), do: Process.demonitor(mon, [:flush])
    if is_binary(path), do: _ = Nif.unmount(state.nif, path)
    if is_pid(pid) and Process.alive?(pid), do: _ = AgentOS.GitEngine.stop(pid)

    %{
      state
      | git_engine: nil,
        git_mount_path: nil,
        git_engine_mon: nil,
        git_allowed_origins: [],
        git_auth: nil,
        git_transport: nil
    }
  end

  # Fail outstanding remote handles and kill tasks so they cannot double-respond.
  defp cancel_git_tasks(state) do
    tasks = state.git_tasks || %{}

    Enum.each(tasks, fn {handle, task} ->
      if is_reference(task.ref), do: Process.demonitor(task.ref, [:flush])
      Task.shutdown(task, :brutal_kill)
      _ = Nif.relay_host_call_fail(state.nif, handle)
    end)

    %{state | git_tasks: %{}, git_task_refs: %{}}
  end

  defp git_host_opts(state) do
    opts = [allowed_origins: state.git_allowed_origins || []]

    opts =
      case state.git_auth do
        nil -> opts
        auth -> Keyword.put(opts, :auth, auth)
      end

    case state.git_transport do
      fun when is_function(fun, 2) -> Keyword.put(opts, :transport, fun)
      _ -> opts
    end
  end

  # Remote orch (`name == "git"`) is async so HTTPS cannot freeze the VM actor.
  # Mount-path host_calls stay sync (single-writer Port ordering).
  defp answer_git_event(
         %{git_engine: pid} = state,
         %{kind: :host_call, handle: handle, name: name, body: body}
       )
       when is_pid(pid) and is_integer(handle) and is_binary(name) and is_binary(body) do
    cond do
      not Process.alive?(pid) ->
        _ = Nif.relay_host_call_fail(state.nif, handle)
        {:answered, do_detach_git(state)}

      name == "git" ->
        answer_git_remote_async(state, pid, handle, body)

      true ->
        answer_git_mount_sync(state, pid, handle, name, body)
    end
  end

  defp answer_git_event(_state, _event), do: :unclaimed

  defp answer_git_remote_async(state, pid, handle, body) do
    tasks = state.git_tasks || %{}

    if Map.has_key?(tasks, handle) do
      # Already claimed — do not spawn a second task (double-respond risk).
      {:answered, state}
    else
      orch_opts = git_host_opts(state)

      # async_nolink → owner receives {ref, result} then DOWN; NIF answer stays on Vm.
      task =
        Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fn ->
          result = AgentOS.GitEngine.handle_host_call(pid, "git", body, orch_opts)
          {handle, result}
        end)

      state = %{
        state
        | git_tasks: Map.put(tasks, handle, task),
          git_task_refs: Map.put(state.git_task_refs || %{}, task.ref, handle)
      }

      {:answered, state}
    end
  end

  defp answer_git_mount_sync(state, pid, handle, name, body) do
    case AgentOS.GitEngine.handle_host_call(pid, name, body, []) do
      {:ok, result} when is_binary(result) ->
        case Nif.relay_host_call_respond(state.nif, handle, result) do
          :ok -> {:answered, state}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_git} ->
        :unclaimed

      {:error, :eio} ->
        _ = Nif.relay_host_call_fail(state.nif, handle)
        {:answered, do_detach_git(state)}

      {:error, _reason} ->
        _ = Nif.relay_host_call_fail(state.nif, handle)
        {:answered, state}
    end
  end

  defp finish_git_task(state, ref, handle, result) do
    tasks = Map.delete(state.git_tasks || %{}, handle)
    refs = Map.delete(state.git_task_refs || %{}, ref)
    state = %{state | git_tasks: tasks, git_task_refs: refs}

    # Drop result if engine was detached while the task ran (handle already failed).
    if is_nil(state.git_engine) do
      state
    else
      case result do
        {:ok, bin} when is_binary(bin) ->
          _ = Nif.relay_host_call_respond(state.nif, handle, bin)
          state

        {:error, :eio} ->
          _ = Nif.relay_host_call_fail(state.nif, handle)
          do_detach_git(state)

        {:error, _reason} ->
          _ = Nif.relay_host_call_fail(state.nif, handle)
          state

        _other ->
          _ = Nif.relay_host_call_fail(state.nif, handle)
          state
      end
    end
  end

  @impl true
  def handle_info({ref, {handle, result}}, %{git_task_refs: refs} = state)
      when is_reference(ref) and is_integer(handle) and is_map(refs) do
    if Map.has_key?(refs, ref) do
      Process.demonitor(ref, [:flush])
      {:noreply, touch(finish_git_task(state, ref, handle, result))}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, mon, :process, pid, _reason},
        %{git_engine: pid, git_engine_mon: mon} = state
      ) do
    # Port owner died — unmount, cancel inflight remotes, clear state.
    {:noreply, do_detach_git(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{git_task_refs: refs} = state)
      when is_reference(ref) and is_map(refs) do
    case Map.pop(refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {handle, next_refs} ->
        # Task crashed before returning a result — fail the handle closed.
        tasks = Map.delete(state.git_tasks || %{}, handle)

        if not is_nil(state.git_engine) do
          _ = Nif.relay_host_call_fail(state.nif, handle)
        end

        {:noreply, touch(%{state | git_tasks: tasks, git_task_refs: next_refs})}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = do_detach_git(state)
    :ok
  end

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
