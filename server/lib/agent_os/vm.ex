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
    # Multi-mount git (R63–R65 / K21 per path):
    # mount_path => %{pid, mon, sparse_cone: [prefix, ...]}.
    # One Port engine per mount path; single-writer per engine (not shared).
    # sparse_cone is per-mount (D20 / JS git.sparse | git.mounts[].sparse).
    git_engines: %{},
    # Host-owned remote policy (never from guest body). See attach_git/2.
    # Shared across mounts on this VM (policy is host-owned, not per-repo).
    #
    # Product path (PR11): `git_connections` mirrors JS ConnectionDefinition
    # `%{ref, auth, origins, spec?}`; origins + auth live on the matching
    # connection. `git_policies` are push policy rules `%{pattern, action}`.
    # Legacy flat `git_allowed_origins` / `git_auth` apply only when
    # connections are empty (fixture / migration).
    git_connections: [],
    git_policies: [],
    git_allowed_origins: [],
    git_auth: nil,
    # Test-only injectable SmartHttp transport (fixture double).
    git_transport: nil,
    # Push approval (R31) — host-owned; never from guest body.
    git_require_approval: false,
    git_on_push_approval: nil,
    git_push_approval: false,
    # Inflight async remote host_calls: handle => %{task, mount}.
    # Per-mount single-writer: remotes for the same mount serialize; different
    # mounts may run in parallel (each engine has its own Port).
    git_tasks: %{},
    git_task_refs: %{},
    # mount_path => [{handle, body}]
    git_remote_queue: %{},
    # Unclaimed relay events popped while auto-answering git during tick
    # (D25/D30 product path). Served first by egress_next so non-git owners
    # still see them in order.
    egress_pending: [],
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

  @doc """
  Snapshot the whole VM into a portable blob.

  Refuses while host egress is in flight (kernel `mc_inflight_egress`, including
  open `host_call` handles) **or** while a BEAM-owned git remote Task/queue is
  inflight (`git_tasks` / `git_remote_queue`). Guest remotes use `host_call` name
  `"git"`; the kernel host handle already pins egress for the monorepo pattern,
  and the BEAM git bookkeeping is a second gate so async orch cannot silently
  snapshot mid-clone when the handle is synthetic or already answered.
  """
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
  Attach a BEAM-owned native `git-engine` Port for this VM (GIT.md K15/K22 / K21 / PR11).

  Host-owned remote policy is stored on the VM actor and forwarded into
  `GitEngine.handle_host_call/4` / orch via `git_host_opts_for_mount/2`. The guest body
  never supplies secrets, origins, or push policy.

  ## Product path — connections catalog (PR11)

  Prefer `:connections` (mirrors JS `ConnectionDefinition`). When non-empty,
  **origins and auth come from the matching connection** — a separate
  `:allowed_origins` / `:auth` is **not** required.

  * `:connections` — list of maps:
      `%{ref: binary, auth: map, origins: [binary], spec: map | nil}`
    - `ref` — connection id (`integration.owner.name`)
    - `auth` — `%{kind: :none | :bearer | :header | :basic | :query, ...}`
      (host-only; never guest-visible)
    - `origins` — absolute `http(s)` origins allowed to receive this credential
      (empty list = fail closed for that connection)
    - `spec` — optional `%{url: binary}` and/or `%{baseUrl: binary}` used when
      the guest names a connection without a public URL
    String keys (`"ref"`, `"auth"`, …) are also accepted and normalized.

  * `:policies` / `:connection_policies` — optional push policy rules
    `[%{pattern: binary, action: action}]` where `action` is
    `:approve | :require_approval | :block` (atoms or strings).
    Optional `:owner` (`:org | :user` or `"org"` / `"user"`) is preserved when
    present. Pattern matches a **connection** prefix (not a tool).

  ## Legacy flat allowlist (connections empty only)

  When `:connections` is empty/missing, the parallel legacy surface still works
  for fixtures and migration:

  * `:allowed_origins` / `:allow_origins` — host-owned origin allowlist
    (empty/missing fails closed; guest cannot smuggle origins).
    Defaults to `[]`. `:any` is rejected outside `Mix.env() == :test`.
  * `:auth` — flat `%{kind: :none | :bearer | :header, ...}` kept in BEAM only

  When `:connections` is non-empty these legacy keys are ignored for remote
  policy (connections win).

  ## Other options

  * `:executable`, `:root`, `:mount_path` (default `"/workspace/repo"`)
  * `:durable_dir` — re-openable libgit2 worktree directory (D16); same as `:root`
    for durability (never deleted on detach). Preferred over temp roots.
  * `:durable_id` — named durable root under `AGENTOS_GIT_DURABLE_ROOT` /
    `:git_durable_root` as `{base}/{id}/{mount_slug}` (D18 partial).
  * `:transport` — injectable SmartHttp transport (tests / fixture double only)
  * `:identity` / `:git_identity` — `%{name: binary, email: binary}` host policy
    identity injected into Port `commit` when args omit name/email (K28). Never
    invents a default identity when unset.
  * `:on_push_approval` / `:push_approval` / `:require_approval` — push approval
    opts forwarded to `AgentOS.Git.Orchestrator` via host_call demux (R31).
    Prefer connection `:policies` for product push gating when available.
  * `:sparse_cone` / `:git_sparse_cone` — list of cone-mode path prefixes
    (e.g. `["src", "docs"]`) stored **on this mount** and applied after
    clone via Port `sparse-set` (D20 / JS `git.sparse` / engine `sparseCone`).
    **Cone-only** — not full sparse-checkout pattern language. Gitfs projects
    the post-sparse worktree (no separate mount-side cone filter on BEAM).

  **K21 / R63–R66:** one engine **per mount path**. A second attach with a
  **different** `mount_path` succeeds (multi-repo). Same path while live returns
  `{:error, :git_already_attached}` without opening another Port. Call
  `detach_git/2` with `:mount_path` to replace one mount, or without to detach all.

  Latest attach **refreshes** shared host policy (connections / policies /
  origins / auth / transport) for all mounts on this VM. Sparse cone is
  **per-mount** and only applies to the attach that set it.
  """
  @spec attach_git(server(), keyword()) :: :ok | {:error, term()}
  def attach_git(server, opts \\ []) when is_list(opts),
    do: GenServer.call(server, {:attach_git, opts}, timeout(opts))

  @doc """
  Detach and stop git-engine Port(s) for this VM; fail inflight remote handles.

  Options:
  * `:mount_path` — detach only that mount; omit to detach **all** engines.
  """
  @spec detach_git(server(), keyword()) :: :ok
  def detach_git(server, opts \\ []) when is_list(opts),
    do: GenServer.call(server, {:detach_git, opts}, timeout(opts))

  @doc """
  If `event` is a host_call (or host_call_close) for name `\"git\"` or a gitfs
  mount path on this VM, claim it and return `:answered`.

  * `name == \"git\"` (remote orch / HTTPS) is **async**: spawn under
    `AgentOS.SidecarTaskSupervisor`, return immediately, then answer via
    `egress_host_call_respond/3` or fail the handle. Host opts come from
    `attach_git/2` (`connections`/`policies`, or legacy origins/auth, plus
    transport) — never from the guest body.
    Body may include `args.mount` / top-level `mount` to demux to the engine
    for that path (R65); empty mount uses the sole engine or the first attached.
    **At most one remote Task runs per mount** — further remotes for the same
    mount enqueue so import+apply cannot interleave on that Port. Distinct mounts
    may run in parallel (separate engines).
  * Mount-path host_calls (gitfs type-4) stay **synchronous** so single-writer
    Port ordering is preserved.
  * `host_call_close` for name `\"git\"` cancels the inflight Task (or drops a
    queued remote) without double-responding — mirrors sidecar cancel (R100).
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
                  git_engines: %{},
                  git_connections: [],
                  git_policies: [],
                  git_allowed_origins: [],
                  git_auth: nil,
                  git_transport: nil,
                  git_tasks: %{},
                  git_task_refs: %{},
                  git_remote_queue: %{}
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
    # D25/D30: when git is attached, answer pending mount/"git" host_calls so
    # guest exec can progress without a separate ControlPlane.egress_next pump.
    # Non-git events are stashed on egress_pending (see drain_git_relay/2).
    state = drain_git_relay(state, 64)
    reply = tick_n(state.nif, n)
    state = drain_git_relay(state, 64)
    {:reply, reply, touch(state)}
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
    case ensure_git_remote_quiescent(state) do
      :ok -> {:reply, Nif.snapshot(state.nif), state}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_call({:snapshot, :incremental}, _from, state) do
    case ensure_git_remote_quiescent(state) do
      {:error, _} = err ->
        {:reply, err, state}

      :ok ->
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
  end

  def handle_call({:snapshot, mode}, _from, state) do
    {:reply, {:error, "snapshot mode must be :full or :incremental, got #{inspect(mode)}"}, state}
  end

  def handle_call(:snapshot_base, _from, state) do
    {:reply, state.snapshot_base, state}
  end

  def handle_call(:commit_layer, _from, state) do
    reply =
      case ensure_git_remote_quiescent(state) do
        {:error, _} = err ->
          err

        :ok ->
          case Nif.commit_layer(state.nif) do
            {:ok, {tar, digest}} -> {:ok, %{tar: tar, digest: digest}}
            {:error, _reason} = err -> err
          end
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

  def handle_call({:detach_git, opts}, _from, state) do
    {:reply, :ok, touch(do_detach_git(state, opts))}
  end

  def handle_call({:try_answer_git_host_call, event}, _from, state) do
    case answer_git_event(state, event) do
      {:answered, state2} -> {:reply, :answered, touch(state2)}
      :unclaimed -> {:reply, :unclaimed, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:info, _from, state) do
    tasks = state.git_tasks || %{}
    queue_map = state.git_remote_queue || %{}
    queued = queue_map |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    mounts = git_mount_paths(state)
    primary = List.first(mounts)

    connections = state.git_connections || []
    # Refs only — never surface auth / tokens via info.
    connection_refs =
      Enum.map(connections, fn
        %{ref: ref} when is_binary(ref) -> ref
        %{"ref" => ref} when is_binary(ref) -> ref
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    {:reply,
     %{
       id: state.id,
       booted_at: state.booted_at,
       idle_ms: now_ms() - state.last_active_ms,
       git_attached: mounts != [],
       # Compat: primary/first mount path (multi-mount: see git_mounts).
       git_mount_path: primary,
       git_mounts: mounts,
       git_engine_count: length(mounts),
       # Running Task + queued remotes (per-mount single-writer honesty).
       git_inflight: map_size(tasks) + queued,
       git_remote_running: map_size(tasks),
       git_remote_queued: queued,
       # PR11 connections (refs only) + legacy flat allowlist.
       git_connection_refs: connection_refs,
       git_connection_count: length(connections),
       git_policy_count: length(state.git_policies || []),
       git_allowed_origins: state.git_allowed_origins || []
     }, state}
  end

  def handle_call(:status, _from, state) do
    {:reply, Nif.status(state.nif), state}
  end

  def handle_call(:egress_next, _from, state) do
    case state.egress_pending do
      [event | rest] ->
        {:reply, {:ok, event}, %{state | egress_pending: rest}}

      [] ->
        {:reply, Nif.relay_next(state.nif), state}
    end
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
    mount_path = Keyword.get(opts, :mount_path, "/workspace/repo")
    engines = state.git_engines || %{}

    # K21: one engine per mount path. Same path while live fails closed (R66).
    # Distinct paths are allowed (R63 multi-mount).
    case Map.get(engines, mount_path) do
      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          {:error, :git_already_attached}
        else
          # Half-dead entry for this path — clear then attach.
          state = do_detach_git(state, mount_path: mount_path)
          do_attach_git_new(state, opts, mount_path)
        end

      _ ->
        do_attach_git_new(state, opts, mount_path)
    end
  end

  defp do_attach_git_new(state, opts, mount_path) do
    connections = git_connections_from_opts(opts)
    policies = git_policies_from_opts(opts)
    # Legacy flat allowlist/auth only when connections empty (product uses connections).
    {allowed, auth} =
      if connections == [] do
        {git_allowed_origins_from_opts(opts), Keyword.get(opts, :auth)}
      else
        {[], nil}
      end

    transport = Keyword.get(opts, :transport)
    identity = Keyword.get(opts, :identity) || Keyword.get(opts, :git_identity)
    require_approval = Keyword.get(opts, :require_approval, false) == true
    on_push_approval = Keyword.get(opts, :on_push_approval)
    push_approval = Keyword.get(opts, :push_approval, false) == true
    # D20: per-mount cone prefixes (JS git.sparse / engine sparseCone).
    sparse_cone = git_sparse_cone_from_opts(opts)

    # Unlinked start + monitor so engine crash does not kill the VM actor.
    # D16/D18: durable_dir / durable_id / root → re-openable worktree; temp otherwise.
    engine_opts =
      [
        executable: Keyword.get(opts, :executable),
        root: Keyword.get(opts, :root),
        durable_dir: Keyword.get(opts, :durable_dir),
        durable_id: Keyword.get(opts, :durable_id),
        durable: Keyword.get(opts, :durable),
        mount_path: mount_path,
        identity: identity
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case AgentOS.GitEngine.start(engine_opts) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        read_only = Keyword.get(opts, :read_only, false)

        case Nif.mount(state.nif, mount_path, read_only) do
          :ok ->
            engines =
              Map.put(state.git_engines || %{}, mount_path, %{
                pid: pid,
                mon: ref,
                sparse_cone: sparse_cone
              })

            # Latest attach refreshes shared host policy (connections/policies/legacy/transport).
            {:ok,
             %{
               state
               | git_engines: engines,
                 git_connections: connections,
                 git_policies: policies,
                 git_allowed_origins: allowed,
                 git_auth: auth,
                 git_transport: transport,
                 git_require_approval: require_approval,
                 git_on_push_approval: on_push_approval,
                 git_push_approval: push_approval
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

  # D20: normalize cone prefixes — strip slashes, drop empties (JS parity).
  defp git_sparse_cone_from_opts(opts) do
    raw = Keyword.get(opts, :sparse_cone, Keyword.get(opts, :git_sparse_cone, []))

    case raw do
      list when is_list(list) ->
        list
        |> Enum.filter(&is_binary/1)
        |> Enum.map(fn p ->
          p
          |> String.trim()
          |> String.trim_leading("/")
          |> String.trim_trailing("/")
        end)
        |> Enum.reject(&(&1 == ""))

      _ ->
        []
    end
  end

  # PR11: normalize ConnectionDefinition-shaped maps (atom or string keys).
  # Invalid entries are dropped (fail closed for that ref; never invent secrets).
  defp git_connections_from_opts(opts) do
    case Keyword.get(opts, :connections, []) do
      list when is_list(list) ->
        list
        |> Enum.map(&normalize_git_connection/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp normalize_git_connection(%{} = entry) do
    ref = Map.get(entry, :ref) || Map.get(entry, "ref")
    auth = Map.get(entry, :auth) || Map.get(entry, "auth")
    origins = Map.get(entry, :origins) || Map.get(entry, "origins") || []
    spec = Map.get(entry, :spec) || Map.get(entry, "spec")

    if is_binary(ref) and ref != "" and is_map(auth) and is_list(origins) and
         Enum.all?(origins, &is_binary/1) do
      conn = %{
        ref: ref,
        auth: normalize_git_auth(auth),
        origins: origins
      }

      case normalize_git_connection_spec(spec) do
        nil -> conn
        normalized -> Map.put(conn, :spec, normalized)
      end
    else
      nil
    end
  end

  defp normalize_git_connection(_), do: nil

  # Known auth field names only — never String.to_atom on untrusted input.
  @git_auth_string_keys %{
    "kind" => :kind,
    "token" => :token,
    "name" => :name,
    "value" => :value,
    "username" => :username,
    "password" => :password,
    "header" => :header
  }

  @git_auth_kinds %{
    "none" => :none,
    "bearer" => :bearer,
    "header" => :header,
    "basic" => :basic,
    "query" => :query,
    none: :none,
    bearer: :bearer,
    header: :header,
    basic: :basic,
    query: :query
  }

  defp normalize_git_auth(%{} = auth) do
    auth
    |> Enum.reduce(%{}, fn
      {k, v}, acc when is_atom(k) ->
        Map.put(acc, k, v)

      {k, v}, acc when is_binary(k) ->
        case Map.get(@git_auth_string_keys, k) do
          nil -> acc
          atom_key -> Map.put(acc, atom_key, v)
        end

      {_k, _v}, acc ->
        acc
    end)
    |> then(fn m ->
      case Map.get(m, :kind) do
        nil -> m
        kind -> Map.put(m, :kind, Map.get(@git_auth_kinds, kind, kind))
      end
    end)
  end

  defp normalize_git_connection_spec(nil), do: nil

  defp normalize_git_connection_spec(%{} = spec) do
    url = Map.get(spec, :url) || Map.get(spec, "url")
    base = Map.get(spec, :baseUrl) || Map.get(spec, "baseUrl") || Map.get(spec, :base_url)

    out = %{}
    out = if is_binary(url) and url != "", do: Map.put(out, :url, url), else: out
    out = if is_binary(base) and base != "", do: Map.put(out, :baseUrl, base), else: out
    if out == %{}, do: nil, else: out
  end

  defp normalize_git_connection_spec(_), do: nil

  # Push policy rules: [%{pattern:, action:}] (+ optional owner).
  defp git_policies_from_opts(opts) do
    rules =
      Keyword.get(opts, :policies, Keyword.get(opts, :connection_policies, []))

    case rules do
      list when is_list(list) ->
        list
        |> Enum.map(&normalize_git_policy/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp normalize_git_policy(%{} = rule) do
    pattern = Map.get(rule, :pattern) || Map.get(rule, "pattern")
    action = Map.get(rule, :action) || Map.get(rule, "action")
    owner = Map.get(rule, :owner) || Map.get(rule, "owner")

    with true <- is_binary(pattern) and pattern != "",
         {:ok, action_atom} <- normalize_policy_action(action) do
      base = %{pattern: pattern, action: action_atom}

      case normalize_policy_owner(owner) do
        nil -> base
        o -> Map.put(base, :owner, o)
      end
    else
      _ -> nil
    end
  end

  defp normalize_git_policy({pattern, action}) when is_binary(pattern),
    do: normalize_git_policy(%{pattern: pattern, action: action})

  defp normalize_git_policy({owner, pattern, action}) when is_binary(pattern),
    do: normalize_git_policy(%{owner: owner, pattern: pattern, action: action})

  defp normalize_git_policy(_), do: nil

  defp normalize_policy_action(action) when action in [:approve, :require_approval, :block],
    do: {:ok, action}

  defp normalize_policy_action("approve"), do: {:ok, :approve}
  defp normalize_policy_action("require_approval"), do: {:ok, :require_approval}
  defp normalize_policy_action("block"), do: {:ok, :block}
  defp normalize_policy_action(_), do: :error

  defp normalize_policy_owner(nil), do: nil
  defp normalize_policy_owner(:org), do: :org
  defp normalize_policy_owner(:user), do: :user
  defp normalize_policy_owner("org"), do: :org
  defp normalize_policy_owner("user"), do: :user
  defp normalize_policy_owner(_), do: nil

  defp git_allowed_origins_from_opts(opts) do
    case Keyword.get(opts, :allowed_origins, Keyword.get(opts, :allow_origins, [])) do
      list when is_list(list) ->
        list

      :any ->
        # Test-only escape hatch (SmartHttp still requires injected transport).
        # Mix is unavailable in releases — treat missing Mix as non-test.
        if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) and Mix.env() == :test do
          :any
        else
          []
        end

      _ ->
        []
    end
  end

  defp do_detach_git(state, opts) when is_list(opts) do
    case Keyword.get(opts, :mount_path) do
      path when is_binary(path) ->
        do_detach_git_one(state, path)

      _ ->
        # Detach all mounts (including half-dead map entries).
        paths = Map.keys(state.git_engines || %{})

        state =
          Enum.reduce(paths, state, fn path, acc ->
            do_detach_git_one(acc, path)
          end)

        state = cancel_git_tasks_all(state)

        %{
          state
          | git_engines: %{},
            git_connections: [],
            git_policies: [],
            git_allowed_origins: [],
            git_auth: nil,
            git_transport: nil,
            git_require_approval: false,
            git_on_push_approval: nil,
            git_push_approval: false,
            git_remote_queue: %{}
        }
    end
  end

  defp do_detach_git_one(state, path) when is_binary(path) do
    engines = state.git_engines || %{}

    case Map.pop(engines, path) do
      {nil, _} ->
        state

      {%{pid: pid, mon: mon}, rest} ->
        state = cancel_git_tasks_for_mount(state, path)
        if is_reference(mon), do: Process.demonitor(mon, [:flush])
        _ = Nif.unmount(state.nif, path)
        if is_pid(pid) and Process.alive?(pid), do: _ = AgentOS.GitEngine.stop(pid)

        queue = Map.delete(state.git_remote_queue || %{}, path)
        %{state | git_engines: rest, git_remote_queue: queue}
    end
  end

  defp git_mount_paths(state) do
    (state.git_engines || %{})
    |> Enum.filter(fn {_path, meta} ->
      pid = Map.get(meta, :pid)
      is_pid(pid) and Process.alive?(pid)
    end)
    |> Enum.map(fn {path, _} -> path end)
    |> Enum.sort()
  end

  defp git_engine_pid(state, path) when is_binary(path) do
    case Map.get(state.git_engines || %{}, path) do
      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: :error

      _ ->
        :error
    end
  end

  defp git_default_mount(state) do
    case git_mount_paths(state) do
      [only] -> only
      [first | _] -> first
      [] -> nil
    end
  end

  defp git_engine_for_mount_name(state, name) when is_binary(name) do
    case git_engine_pid(state, name) do
      {:ok, pid} -> {:ok, pid, name}
      :error -> :error
    end
  end

  # R65: extract mount from body JSON (`args.mount` or top-level `mount`).
  defp mount_from_git_body(body) when is_binary(body) do
    case safe_json_decode_mount(body) do
      mount when is_binary(mount) and mount != "" -> {:ok, mount}
      _ -> :default
    end
  end

  defp safe_json_decode_mount(bin) do
    # Prefer OTP :json when present; fall back to a small regex for mount only
    # so demux works on OTP 26 (where :json may be unavailable).
    mount =
      try do
        term = :json.decode(bin)
        map = json_keys_to_string(term)

        if is_map(map) do
          top = Map.get(map, "mount")
          args = Map.get(map, "args")

          cond do
            is_binary(top) and String.trim(top) != "" ->
              String.trim(top)

            is_map(args) ->
              m = Map.get(args, "mount")
              if is_binary(m) and String.trim(m) != "", do: String.trim(m), else: nil

            true ->
              nil
          end
        else
          nil
        end
      rescue
        _ -> nil
      end

    mount || regex_mount_from_body(bin)
  end

  # Best-effort: "mount":"/path" at top-level or under args (OTP 26 without :json).
  defp regex_mount_from_body(bin) when is_binary(bin) do
    # Prefer args.mount (more specific) then top-level mount.
    patterns = [
      ~r/"args"\s*:\s*\{[^}]*"mount"\s*:\s*"([^"]+)"/s,
      ~r/"mount"\s*:\s*"([^"]+)"/
    ]

    Enum.find_value(patterns, fn re ->
      case Regex.run(re, bin) do
        [_, m] when is_binary(m) and m != "" -> m
        _ -> nil
      end
    end)
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

  # Resolve engine for a remote host_call body.
  defp resolve_git_remote_engine(state, body) do
    mounts = git_mount_paths(state)

    case mounts do
      [] ->
        {:error, :no_engine}

      _ ->
        case mount_from_git_body(body) do
          {:ok, mount} ->
            case git_engine_pid(state, mount) do
              {:ok, pid} ->
                {:ok, pid, mount}

              :error ->
                {:error, {:unknown_mount, mount}}
            end

          :default ->
            case git_default_mount(state) do
              nil ->
                {:error, :no_engine}

              mount ->
                case git_engine_pid(state, mount) do
                  {:ok, pid} -> {:ok, pid, mount}
                  :error -> {:error, :no_engine}
                end
            end
        end
    end
  end

  # D19: BEAM-owned git remote inflight (running Task + per-mount queue) must
  # block snapshot/commit just like kernel host_call egress. Guest remotes already
  # pin `mc_inflight_egress` via the open host handle; this second gate covers the
  # async orch bookkeeping so a silent mid-clone snapshot is impossible even when
  # the handle is synthetic (tests / early answer) or the NIF path is bypassed.
  defp ensure_git_remote_quiescent(state) do
    tasks = state.git_tasks || %{}
    queue_map = state.git_remote_queue || %{}
    queued = queue_map |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
    n = map_size(tasks) + queued

    if n > 0 do
      {:error,
       "cannot snapshot: #{n} git remote host_call operation(s) in flight; quiesce first"}
    else
      :ok
    end
  end

  # Fail outstanding remote handles and kill tasks so they cannot double-respond.
  defp cancel_git_tasks_all(state) do
    tasks = state.git_tasks || %{}
    queue_map = state.git_remote_queue || %{}

    Enum.each(tasks, fn {handle, meta} ->
      task = task_of_meta(meta)
      if is_reference(task.ref), do: Process.demonitor(task.ref, [:flush])
      Task.shutdown(task, :brutal_kill)
      _ = Nif.relay_host_call_fail(state.nif, handle)
    end)

    Enum.each(queue_map, fn {_mount, queue} ->
      Enum.each(queue, fn {handle, _body} ->
        _ = Nif.relay_host_call_fail(state.nif, handle)
      end)
    end)

    %{state | git_tasks: %{}, git_task_refs: %{}, git_remote_queue: %{}}
  end

  defp cancel_git_tasks_for_mount(state, mount) when is_binary(mount) do
    tasks = state.git_tasks || %{}
    queue_map = state.git_remote_queue || %{}

    {keep, drop} =
      Enum.split_with(tasks, fn {_handle, meta} -> mount_of_meta(meta) != mount end)

    Enum.each(drop, fn {handle, meta} ->
      task = task_of_meta(meta)
      if is_reference(task.ref), do: Process.demonitor(task.ref, [:flush])
      Task.shutdown(task, :brutal_kill)
      _ = Nif.relay_host_call_fail(state.nif, handle)
    end)

    refs =
      Enum.reduce(drop, state.git_task_refs || %{}, fn {_handle, meta}, acc ->
        Map.delete(acc, task_of_meta(meta).ref)
      end)

    queue = Map.get(queue_map, mount, [])

    Enum.each(queue, fn {handle, _body} ->
      _ = Nif.relay_host_call_fail(state.nif, handle)
    end)

    %{
      state
      | git_tasks: Map.new(keep),
        git_task_refs: refs,
        git_remote_queue: Map.delete(queue_map, mount)
    }
  end

  defp task_of_meta(%{task: task}), do: task
  defp task_of_meta(task), do: task

  defp mount_of_meta(%{mount: mount}), do: mount
  defp mount_of_meta(_), do: nil

  # R100: cancel one inflight/queued remote by handle (host_call_close).
  # Mirrors sidecar: kill Task, drop queue entry; do not double-respond.
  defp cancel_git_handle(state, handle) when is_integer(handle) do
    tasks = state.git_tasks || %{}
    queue_map = state.git_remote_queue || %{}

    case Map.pop(tasks, handle) do
      {nil, _tasks} ->
        new_queue =
          Map.new(queue_map, fn {mount, queue} ->
            {mount, Enum.reject(queue, fn {h, _body} -> h == handle end)}
          end)

        %{state | git_remote_queue: new_queue}

      {meta, rest} ->
        task = task_of_meta(meta)
        mount = mount_of_meta(meta)
        if is_reference(task.ref), do: Process.demonitor(task.ref, [:flush])
        Task.shutdown(task, :brutal_kill)
        refs = Map.delete(state.git_task_refs || %{}, task.ref)
        state = %{state | git_tasks: rest, git_task_refs: refs}
        maybe_start_next_git_remote(state, mount)
    end
  end

  # Host-owned opts for GitEngine.handle_host_call / Orchestrator.
  # Product (PR11): connections + policies. Legacy flat allowlist/auth only
  # when connections empty so fixtures keep working during orch migration.
  # Per-mount `:sparse_cone` is added by `git_host_opts_for_mount/2` (D20).
  defp git_host_opts(state) do
    connections = state.git_connections || []
    policies = state.git_policies || []

    opts =
      if connections != [] do
        # Product path: origins/auth live on matching connection — do not require
        # a separate allowed_origins. Pass connections (and policies when set).
        [connections: connections]
        |> then(fn o ->
          if policies != [], do: Keyword.put(o, :policies, policies), else: o
        end)
      else
        # Legacy: flat allowlist + optional flat auth.
        [allowed_origins: state.git_allowed_origins || []]
        |> then(fn o ->
          case state.git_auth do
            nil -> o
            auth -> Keyword.put(o, :auth, auth)
          end
        end)
        |> then(fn o ->
          # Policies still useful for push gating even on legacy origin path.
          if policies != [], do: Keyword.put(o, :policies, policies), else: o
        end)
      end

    opts =
      case state.git_transport do
        fun when is_function(fun, 2) -> Keyword.put(opts, :transport, fun)
        _ -> opts
      end

    opts =
      if state.git_require_approval == true do
        Keyword.put(opts, :require_approval, true)
      else
        opts
      end

    opts =
      case state.git_on_push_approval do
        fun when is_function(fun) -> Keyword.put(opts, :on_push_approval, fun)
        _ -> opts
      end

    if state.git_push_approval == true do
      Keyword.put(opts, :push_approval, true)
    else
      opts
    end
  end

  # Shared policy opts + per-mount sparse cone for remote orch (D20).
  defp git_host_opts_for_mount(state, mount) when is_binary(mount) do
    opts = git_host_opts(state)

    case Map.get(state.git_engines || %{}, mount) do
      %{sparse_cone: cone} when is_list(cone) and cone != [] ->
        Keyword.put(opts, :sparse_cone, cone)

      _ ->
        opts
    end
  end

  defp git_host_opts_for_mount(state, _mount), do: git_host_opts(state)

  # R100: guest closed the host_call handle — cancel Task / drop queue.
  defp answer_git_event(
         state,
         %{kind: :host_call_close, handle: handle, name: name}
       )
       when is_integer(handle) and is_binary(name) do
    cond do
      name == "git" ->
        {:answered, cancel_git_handle(state, handle)}

      match?({:ok, _, _}, git_engine_for_mount_name(state, name)) ->
        # Mount ops are sync; nothing to cancel, but claim the close.
        {:answered, state}

      true ->
        :unclaimed
    end
  end

  # Remote orch (`name == "git"`) is async so HTTPS cannot freeze the VM actor.
  # Mount-path host_calls stay sync (single-writer Port ordering).
  defp answer_git_event(
         state,
         %{kind: :host_call, handle: handle, name: name, body: body}
       )
       when is_integer(handle) and is_binary(name) and is_binary(body) do
    engines = state.git_engines || %{}

    cond do
      engines == %{} ->
        :unclaimed

      name == "git" ->
        answer_git_remote_async(state, handle, body)

      true ->
        case git_engine_for_mount_name(state, name) do
          {:ok, pid, mount} ->
            answer_git_mount_sync(state, pid, handle, name, body, mount)

          :error ->
            :unclaimed
        end
    end
  end

  defp answer_git_event(_state, _event), do: :unclaimed

  # Auto-answer git host_calls queued on the NIF relay (guest mount ops + remotes).
  # Called from tick so ControlPlane.exec/run product paths drain without a
  # separate egress pump. Unclaimed events (HTTP, tool_approval, …) are stashed
  # on `egress_pending` so egress_next still delivers them.
  defp drain_git_relay(state, 0), do: state

  defp drain_git_relay(state, limit) when is_integer(limit) and limit > 0 do
    engines = state.git_engines || %{}

    if engines == %{} and (state.git_tasks || %{}) == %{} do
      state
    else
      case Nif.relay_next(state.nif) do
        {:ok, nil} ->
          state

        {:ok, event} when is_map(event) ->
          case answer_git_event(state, event) do
            {:answered, state2} ->
              drain_git_relay(state2, limit - 1)

            :unclaimed ->
              pending = (state.egress_pending || []) ++ [event]
              %{state | egress_pending: pending}

            {:error, _reason} ->
              # Fail closed on this event; leave the rest for the next tick.
              state
          end

        {:error, _reason} ->
          state
      end
    end
  end

  defp drain_git_relay(state, _), do: state

  # Per-mount single-writer remote queue (R63/R64).
  defp answer_git_remote_async(state, handle, body) do
    tasks = state.git_tasks || %{}
    queue_map = state.git_remote_queue || %{}

    already? =
      Map.has_key?(tasks, handle) or
        Enum.any?(queue_map, fn {_m, q} -> Enum.any?(q, fn {h, _} -> h == handle end) end)

    if already? do
      {:answered, state}
    else
      case resolve_git_remote_engine(state, body) do
        {:ok, pid, mount} ->
          running_for_mount? =
            Enum.any?(tasks, fn {_h, meta} -> mount_of_meta(meta) == mount end)

          if running_for_mount? do
            queue = Map.get(queue_map, mount, [])
            new_queue = queue ++ [{handle, body}]
            # D36: alert when per-mount remote queue exceeds 32.
            _ = AgentOS.Git.Metrics.observe_queue_depth(mount, length(new_queue))

            {:answered,
             %{state | git_remote_queue: Map.put(queue_map, mount, new_queue)}}
          else
            {:answered, start_git_remote_task(state, pid, handle, body, mount)}
          end

        {:error, :no_engine} ->
          _ = Nif.relay_host_call_fail(state.nif, handle)
          {:answered, state}

        {:error, {:unknown_mount, _mount}} ->
          # Fail closed with a stable JSON response (not a raw NIF fail).
          json =
            ~s({"ok":false,"code":1,"stdout":"","stderr":"git: unknown mount\\n"})

          _ = Nif.relay_host_call_respond(state.nif, handle, json)
          {:answered, state}
      end
    end
  end

  defp start_git_remote_task(state, pid, handle, body, mount) do
    orch_opts = git_host_opts_for_mount(state, mount)

    # async_nolink → owner receives {ref, result} then DOWN; NIF answer stays on Vm.
    task =
      Task.Supervisor.async_nolink(AgentOS.SidecarTaskSupervisor, fn ->
        result = AgentOS.GitEngine.handle_host_call(pid, "git", body, orch_opts)
        {handle, result}
      end)

    meta = %{task: task, mount: mount}

    %{
      state
      | git_tasks: Map.put(state.git_tasks || %{}, handle, meta),
        git_task_refs: Map.put(state.git_task_refs || %{}, task.ref, handle)
    }
  end

  # After a remote Task for `mount` finishes, start the next queued for that mount.
  defp maybe_start_next_git_remote(state, nil) do
    # Drain all mounts that have idle engines with queued work.
    (state.git_remote_queue || %{})
    |> Map.keys()
    |> Enum.reduce(state, fn m, acc -> maybe_start_next_git_remote(acc, m) end)
  end

  defp maybe_start_next_git_remote(state, mount) when is_binary(mount) do
    tasks = state.git_tasks || %{}
    queue_map = state.git_remote_queue || %{}
    queue = Map.get(queue_map, mount, [])

    running? = Enum.any?(tasks, fn {_h, meta} -> mount_of_meta(meta) == mount end)

    cond do
      running? ->
        state

      queue == [] ->
        state

      true ->
        case git_engine_pid(state, mount) do
          {:ok, pid} ->
            [{handle, body} | rest] = queue
            state = %{state | git_remote_queue: Map.put(queue_map, mount, rest)}
            start_git_remote_task(state, pid, handle, body, mount)

          :error ->
            Enum.each(queue, fn {handle, _body} ->
              _ = Nif.relay_host_call_fail(state.nif, handle)
            end)

            %{state | git_remote_queue: Map.delete(queue_map, mount)}
        end
    end
  end

  defp answer_git_mount_sync(state, pid, handle, name, body, mount) do
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
        {:answered, do_detach_git(state, mount_path: mount)}

      {:error, _reason} ->
        _ = Nif.relay_host_call_fail(state.nif, handle)
        {:answered, state}
    end
  end

  defp finish_git_task(state, ref, handle, result) do
    tasks = state.git_tasks || %{}
    meta = Map.get(tasks, handle)
    mount = mount_of_meta(meta)
    tasks = Map.delete(tasks, handle)
    refs = Map.delete(state.git_task_refs || %{}, ref)
    state = %{state | git_tasks: tasks, git_task_refs: refs}

    engine_live? =
      is_binary(mount) and match?({:ok, _}, git_engine_pid(state, mount))

    # Drop result if engine was detached while the task ran (handle already failed).
    state =
      if not engine_live? do
        state
      else
        case result do
          {:ok, bin} when is_binary(bin) ->
            _ = Nif.relay_host_call_respond(state.nif, handle, bin)
            state

          {:error, :eio} ->
            _ = Nif.relay_host_call_fail(state.nif, handle)
            do_detach_git(state, mount_path: mount)

          {:error, _reason} ->
            _ = Nif.relay_host_call_fail(state.nif, handle)
            state

          _other ->
            _ = Nif.relay_host_call_fail(state.nif, handle)
            state
        end
      end

    maybe_start_next_git_remote(state, mount)
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

  def handle_info({:DOWN, mon, :process, pid, _reason}, state)
      when is_reference(mon) and is_pid(pid) do
    # Match git-engine Port death by monitor ref.
    case Enum.find(state.git_engines || %{}, fn {_path, meta} ->
           Map.get(meta, :mon) == mon and Map.get(meta, :pid) == pid
         end) do
      {path, _} ->
        {:noreply, touch(do_detach_git(state, mount_path: path))}

      nil ->
        handle_git_task_down(state, mon)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_git_task_down(%{git_task_refs: refs} = state, ref)
       when is_reference(ref) and is_map(refs) do
    case Map.pop(refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {handle, next_refs} ->
        meta = Map.get(state.git_tasks || %{}, handle)
        mount = mount_of_meta(meta)
        tasks = Map.delete(state.git_tasks || %{}, handle)

        if is_binary(mount) and match?({:ok, _}, git_engine_pid(state, mount)) do
          _ = Nif.relay_host_call_fail(state.nif, handle)
        end

        state = %{state | git_tasks: tasks, git_task_refs: next_refs}
        {:noreply, touch(maybe_start_next_git_remote(state, mount))}
    end
  end

  defp handle_git_task_down(state, _ref), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = do_detach_git(state, [])
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
