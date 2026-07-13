defmodule AgentOS.ControlPlane do
  @moduledoc """
  The public facade over the VM population — address VMs by `{namespace, key}`, get-or-create,
  exec, snapshot, dispose, list. `Registry` provides addressing and `DynamicSupervisor`
  provides start-on-demand and crash-only restart (SYSTEMS.md §13.1). The namespace is an
  address boundary; a deployment layer decides tenancy, quotas, and eviction policy.
  """

  alias AgentOS.Vm

  @registry AgentOS.VmRegistry
  @supervisor AgentOS.VmSupervisor

  @doc """
  Get-or-create the VM at `id`. `opts` are forwarded to `AgentOS.Vm` (`:wasm` required;
  `:base_image` or `:snapshot` optional). Idempotent: concurrent callers converge on one VM
  (the `:already_started` race is resolved in favor of the winner).
  """
  @spec create(Vm.id(), keyword()) :: {:ok, pid()} | {:error, term()}
  def create(id, opts) do
    case DynamicSupervisor.start_child(@supervisor, {Vm, Keyword.put(opts, :id, id)}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Create a VM only when `id` is unoccupied; unlike `create/2`, never converges on an existing VM."
  @spec create_new(Vm.id(), keyword()) :: {:ok, pid()} | {:error, :already_exists | term()}
  def create_new(id, opts) do
    case DynamicSupervisor.start_child(@supervisor, {Vm, Keyword.put(opts, :id, id)}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :already_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The pid of the VM at `id`, or `nil`."
  @spec whereis(Vm.id()) :: pid() | nil
  def whereis(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Run a command on an existing VM."
  @spec exec(Vm.id(), String.t(), keyword()) :: {:ok, map()} | {:error, :not_found}
  def exec(id, cmd, opts \\ []), do: with_vm(id, &Vm.exec(&1, cmd, opts))

  @doc "Query shell completions on an existing VM without executing input."
  @spec autocomplete(Vm.id(), String.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def autocomplete(id, source, cursor, opts \\ []),
    do: with_vm(id, &Vm.autocomplete(&1, source, cursor, opts))

  @doc "Feed terminal input bytes to an existing VM."
  @spec send_input(Vm.id(), binary()) :: :ok | {:error, term()}
  def send_input(id, bytes), do: with_vm(id, &Vm.send_input(&1, bytes))

  @doc "Drive one or more bounded ticks on an existing VM."
  @spec tick(Vm.id(), pos_integer()) :: :running | :exited | {:error, term()}
  def tick(id, n \\ 1), do: with_vm(id, &Vm.tick(&1, n))

  @doc "Drain terminal output captured since the last call."
  @spec take_output(Vm.id()) :: binary() | {:error, :not_found}
  def take_output(id), do: with_vm(id, &Vm.take_output/1)

  @doc "Terminal scrollback retained since `cursor`, plus the absolute total, for typed-socket resume."
  @spec shell_since(Vm.id(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def shell_since(id, cursor), do: with_vm(id, &Vm.shell_since(&1, cursor))

  @doc "Start a structured exec job on an existing VM."
  @spec exec_start(Vm.id(), String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def exec_start(id, cmd, opts \\ []), do: with_vm(id, &Vm.exec_start(&1, cmd, opts))

  @doc "Poll a structured exec job on an existing VM."
  @spec exec_poll(Vm.id(), integer(), keyword()) :: {:ok, nil | map()} | {:error, term()}
  def exec_poll(id, job, opts \\ []), do: with_vm(id, &Vm.exec_poll(&1, job, opts))

  @doc "Read stdout produced so far by a running structured exec job."
  @spec exec_stdout_peek(Vm.id(), integer(), keyword()) :: {:ok, binary()} | {:error, term()}
  def exec_stdout_peek(id, job, opts \\ []), do: with_vm(id, &Vm.exec_stdout_peek(&1, job, opts))

  @doc "Cancel a structured exec job on an existing VM."
  @spec exec_cancel(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def exec_cancel(id, job, opts \\ []), do: with_vm(id, &Vm.exec_cancel(&1, job, opts))

  @doc "Call a resident service as host control on an existing VM."
  @spec svc_call(Vm.id(), String.t(), binary(), keyword()) ::
          {:ok, {integer(), binary()}} | {:error, term()}
  def svc_call(id, service, request, opts \\ []),
    do: with_vm(id, &Vm.svc_call(&1, service, request, opts))

  @doc "Snapshot an existing VM."
  @spec snapshot(Vm.id(), keyword()) :: {:ok, binary()} | {:error, :not_found}
  def snapshot(id, opts \\ []), do: with_vm(id, &Vm.snapshot(&1, opts))

  @doc "Read the immutable full baseline that backs an existing VM's incremental snapshots."
  @spec snapshot_base(Vm.id()) :: binary() | {:error, :not_found}
  def snapshot_base(id), do: with_vm(id, &Vm.snapshot_base/1)

  @doc "Serialize an existing VM's live CoW overlay into a content-addressed tar layer."
  @spec commit_layer(Vm.id(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit_layer(id, opts \\ []), do: with_vm(id, &Vm.commit_layer(&1, opts))

  @doc "Read a file from an existing VM through the host control channel."
  @spec read_file(Vm.id(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(id, path, opts \\ []), do: with_vm(id, &Vm.read_file(&1, path, opts))

  @doc "Write a file in an existing VM through the host control channel."
  @spec write_file(Vm.id(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write_file(id, path, data, opts \\ []),
    do: with_vm(id, &Vm.write_file(&1, path, data, opts))

  @doc "List a directory in an existing VM through the host control channel."
  @spec readdir(Vm.id(), String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def readdir(id, path, opts \\ []), do: with_vm(id, &Vm.readdir(&1, path, opts))

  @doc "Stat a path in an existing VM through the host control channel."
  @spec stat(Vm.id(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stat(id, path, opts \\ []), do: with_vm(id, &Vm.stat(&1, path, opts))

  @doc "Read the target text of a symlink through the host control channel."
  @spec readlink(Vm.id(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def readlink(id, path, opts \\ []), do: with_vm(id, &Vm.readlink(&1, path, opts))

  @doc "Create a directory in an existing VM through the host control channel."
  @spec mkdir(Vm.id(), String.t(), keyword()) :: :ok | {:error, term()}
  def mkdir(id, path, opts \\ []), do: with_vm(id, &Vm.mkdir(&1, path, opts))

  @doc "Remove a file or empty directory in an existing VM through the host control channel."
  @spec unlink(Vm.id(), String.t(), keyword()) :: :ok | {:error, term()}
  def unlink(id, path, opts \\ []), do: with_vm(id, &Vm.unlink(&1, path, opts))

  @doc "Set POSIX permission bits in an existing VM through the host control channel."
  @spec chmod(Vm.id(), String.t(), non_neg_integer(), keyword()) :: :ok | {:error, term()}
  def chmod(id, path, mode, opts \\ []), do: with_vm(id, &Vm.chmod(&1, path, mode, opts))

  @doc "Create a symbolic link in an existing VM through the host control channel."
  @spec symlink(Vm.id(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def symlink(id, target, link, opts \\ []), do: with_vm(id, &Vm.symlink(&1, target, link, opts))

  @doc "Mount a host-call-backed filesystem driver in an existing VM."
  @spec mount(Vm.id(), String.t(), keyword()) :: :ok | {:error, term()}
  def mount(id, path, opts \\ []), do: with_vm(id, &Vm.mount(&1, path, opts))

  @doc "Unmount a host-backed filesystem driver in an existing VM."
  @spec unmount(Vm.id(), String.t(), keyword()) :: :ok | {:error, term()}
  def unmount(id, path, opts \\ []), do: with_vm(id, &Vm.unmount(&1, path, opts))

  @doc "Host status for an existing VM."
  @spec status(Vm.id()) :: {:ok, map()} | {:error, :not_found}
  def status(id), do: with_vm(id, &Vm.status/1)

  @doc "Drain the next outbound egress relay event for an existing VM."
  @spec egress_next(Vm.id(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def egress_next(id, opts \\ []), do: with_vm(id, &Vm.egress_next(&1, opts))

  @doc "Answer an HTTP egress relay event."
  @spec egress_http_respond(
          Vm.id(),
          integer(),
          non_neg_integer(),
          String.t(),
          [{String.t(), String.t()}],
          binary(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def egress_http_respond(id, handle, status, reason, headers, body, opts \\ []),
    do: with_vm(id, &Vm.egress_http_respond(&1, handle, status, reason, headers, body, opts))

  @doc "Fail an HTTP egress relay event."
  @spec egress_http_fail(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_http_fail(id, handle, opts \\ []),
    do: with_vm(id, &Vm.egress_http_fail(&1, handle, opts))

  @doc "Answer a host_call egress relay event."
  @spec egress_host_call_respond(Vm.id(), integer(), binary(), keyword()) ::
          :ok | {:error, term()}
  def egress_host_call_respond(id, handle, result, opts \\ []),
    do: with_vm(id, &Vm.egress_host_call_respond(&1, handle, result, opts))

  @doc "Answer a tool_approval egress relay event: allow or deny the parked destructive call."
  @spec egress_tool_approval_respond(Vm.id(), integer(), boolean(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def egress_tool_approval_respond(id, handle, allow, remember_session \\ false, opts \\ []),
    do: with_vm(id, &Vm.egress_tool_approval_respond(&1, handle, allow, remember_session, opts))

  @doc "Fail a host_call egress relay event."
  @spec egress_host_call_fail(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_host_call_fail(id, handle, opts \\ []),
    do: with_vm(id, &Vm.egress_host_call_fail(&1, handle, opts))

  @doc "Answer a persist egress relay event with raw async-persist body bytes."
  @spec egress_persist_respond(Vm.id(), integer(), binary(), keyword()) :: :ok | {:error, term()}
  def egress_persist_respond(id, handle, body, opts \\ []),
    do: with_vm(id, &Vm.egress_persist_respond(&1, handle, body, opts))

  @doc "Fail a persist egress relay event."
  @spec egress_persist_fail(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_persist_fail(id, handle, opts \\ []),
    do: with_vm(id, &Vm.egress_persist_fail(&1, handle, opts))

  @doc "Mark a WebSocket egress relay as connected."
  @spec egress_ws_open(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_ws_open(id, handle, opts \\ []),
    do: with_vm(id, &Vm.egress_ws_open(&1, handle, opts))

  @doc "Fail a WebSocket egress relay connection."
  @spec egress_ws_fail(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_ws_fail(id, handle, opts \\ []),
    do: with_vm(id, &Vm.egress_ws_fail(&1, handle, opts))

  @doc "Push one received WebSocket message into an egress relay connection."
  @spec egress_ws_push(Vm.id(), integer(), binary(), keyword()) :: :ok | {:error, term()}
  def egress_ws_push(id, handle, data, opts \\ []),
    do: with_vm(id, &Vm.egress_ws_push(&1, handle, data, opts))

  @doc "Mark a WebSocket egress relay as closed by the peer."
  @spec egress_ws_close(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_ws_close(id, handle, opts \\ []),
    do: with_vm(id, &Vm.egress_ws_close(&1, handle, opts))

  @doc "Liveness and age info for an existing VM."
  @spec info(Vm.id()) :: map() | {:error, :not_found}
  def info(id), do: with_vm(id, &Vm.info/1)

  @doc "Terminate and remove a VM (normal shutdown — no restart)."
  @spec dispose(Vm.id()) :: :ok | {:error, :not_found}
  def dispose(id) do
    case whereis(id) do
      nil -> {:error, :not_found}
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc "All live VM ids."
  @spec list() :: [Vm.id()]
  def list, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  defp with_vm(id, fun) do
    case whereis(id) do
      nil -> {:error, :not_found}
      pid -> fun.(pid)
    end
  end
end
