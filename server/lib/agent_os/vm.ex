defmodule AgentOS.Vm do
  @moduledoc """
  One agent-os VM, owned by exactly one BEAM process — the **actor-per-VM** unit
  (CONTROL_PLANE.md §7), the OTP realization of mc-server's `run_actor`.

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
  one command at a time). Incremental exec + terminal streaming are a later refinement on top
  of `tick/2` + `take_output/1`.
  """

  use GenServer, restart: :transient

  alias AgentOS.Host.Nif

  @typedoc "A VM address: a tenancy namespace plus a within-namespace key."
  @type id :: {namespace :: String.t(), key :: String.t()}

  # A generous default tick ceiling for a single command. SQLite/typst compiles burn millions
  # of fuel slices; this bounds a runaway command rather than the common case.
  @default_max_ticks 5_000_000

  defstruct [:id, :nif, :booted_at, :last_active_ms]

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
  def exec(server, cmd, opts \\ []) when is_binary(cmd) do
    max_ticks = Keyword.get(opts, :max_ticks, @default_max_ticks)
    GenServer.call(server, {:exec, cmd, max_ticks}, Keyword.get(opts, :timeout, 60_000))
  end

  @doc "Feed terminal input bytes."
  @spec send_input(server(), binary()) :: :ok | {:error, Nif.reason()}
  def send_input(server, bytes) when is_binary(bytes),
    do: GenServer.call(server, {:send_input, bytes})

  @doc "Drive `n` bounded ticks (default 1): `:running`, `:exited`, or `{:error, reason}`."
  @spec tick(server(), pos_integer()) :: :running | :exited | {:error, Nif.reason()}
  def tick(server, n \\ 1) when n > 0, do: GenServer.call(server, {:tick, n})

  @doc "Drain the terminal output captured since the last drain."
  @spec take_output(server()) :: binary()
  def take_output(server), do: GenServer.call(server, :take_output)

  @doc "Snapshot the whole VM into a portable blob (refuses while egress is in flight)."
  @spec snapshot(server()) :: {:ok, binary()} | {:error, Nif.reason()}
  def snapshot(server), do: GenServer.call(server, :snapshot, 60_000)

  @doc "Liveness/age info."
  @spec info(server()) :: map()
  def info(server), do: GenServer.call(server, :info)

  @typep server :: pid() | {:via, module(), term()}

  @doc "The `:via` tuple addressing a VM by id through the registry."
  @spec via(id()) :: {:via, Registry, {module(), id()}}
  def via(id), do: {:via, Registry, {AgentOS.VmRegistry, id}}

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    wasm = Keyword.fetch!(opts, :wasm)

    result =
      case Keyword.get(opts, :snapshot) do
        nil -> Nif.boot(wasm, Keyword.get(opts, :base_image))
        snap -> Nif.restore(wasm, snap)
      end

    case result do
      {:ok, nif} ->
        now = now_ms()
        {:ok, %__MODULE__{id: Keyword.fetch!(opts, :id), nif: nif, booted_at: now, last_active_ms: now}}

      {:error, reason} ->
        # A boot/restore failure is a clean stop, so the caller sees `{:error, reason}` rather
        # than a mailbox for a VM that never came up.
        {:stop, {:vm_start_failed, reason}}
    end
  end

  @impl true
  def handle_call({:exec, cmd, max_ticks}, _from, state) do
    reply =
      case Nif.exec(state.nif, cmd, max_ticks) do
        {:ok, {exit_code, stdout, stderr}} ->
          {:ok, %{exit_code: exit_code, stdout: stdout, stderr: stderr}}

        {:error, _reason} = err ->
          err
      end

    {:reply, reply, touch(state)}
  end

  def handle_call({:send_input, bytes}, _from, state) do
    {:reply, Nif.send_input(state.nif, bytes), touch(state)}
  end

  def handle_call({:tick, n}, _from, state) do
    {:reply, tick_n(state.nif, n), touch(state)}
  end

  def handle_call(:take_output, _from, state) do
    {:reply, Nif.take_output(state.nif), state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, Nif.snapshot(state.nif), state}
  end

  def handle_call(:info, _from, state) do
    {:reply, %{id: state.id, booted_at: state.booted_at, idle_ms: now_ms() - state.last_active_ms},
     state}
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

  defp touch(state), do: %{state | last_active_ms: now_ms()}
  defp now_ms, do: System.monotonic_time(:millisecond)
end
