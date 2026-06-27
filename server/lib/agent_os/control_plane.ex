defmodule AgentOS.ControlPlane do
  @moduledoc """
  The public facade over the VM population — address VMs by `{namespace, key}`, get-or-create,
  exec, snapshot, dispose, list. The OTP realization of mc-server's registry + REST surface
  (CONTROL_PLANE.md §2.1): `Registry` for addressing, `DynamicSupervisor` for start-on-demand
  and crash-only restart. The `namespace` is the tenancy boundary (and, later, the quota and
  eviction boundary).
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

  @doc "Feed terminal input bytes to an existing VM."
  @spec send_input(Vm.id(), binary()) :: :ok | {:error, term()}
  def send_input(id, bytes), do: with_vm(id, &Vm.send_input(&1, bytes))

  @doc "Drive one or more bounded ticks on an existing VM."
  @spec tick(Vm.id(), pos_integer()) :: :running | :exited | {:error, term()}
  def tick(id, n \\ 1), do: with_vm(id, &Vm.tick(&1, n))

  @doc "Drain terminal output captured since the last call."
  @spec take_output(Vm.id()) :: binary() | {:error, :not_found}
  def take_output(id), do: with_vm(id, &Vm.take_output/1)

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

  @doc "Snapshot an existing VM."
  @spec snapshot(Vm.id()) :: {:ok, binary()} | {:error, :not_found}
  def snapshot(id), do: with_vm(id, &Vm.snapshot/1)

  @doc "Serialize an existing VM's live CoW overlay into a content-addressed tar layer."
  @spec commit_layer(Vm.id(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit_layer(id, opts \\ []), do: with_vm(id, &Vm.commit_layer(&1, opts))

  @doc "Read a file from an existing VM through the host control channel."
  @spec read_file(Vm.id(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def read_file(id, path, opts \\ []), do: with_vm(id, &Vm.read_file(&1, path, opts))

  @doc "Write a file in an existing VM through the host control channel."
  @spec write_file(Vm.id(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write_file(id, path, data, opts \\ []), do: with_vm(id, &Vm.write_file(&1, path, data, opts))

  @doc "List a directory in an existing VM through the host control channel."
  @spec readdir(Vm.id(), String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def readdir(id, path, opts \\ []), do: with_vm(id, &Vm.readdir(&1, path, opts))

  @doc "Stat a path in an existing VM through the host control channel."
  @spec stat(Vm.id(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def stat(id, path, opts \\ []), do: with_vm(id, &Vm.stat(&1, path, opts))

  @doc "Create a directory in an existing VM through the host control channel."
  @spec mkdir(Vm.id(), String.t(), keyword()) :: :ok | {:error, term()}
  def mkdir(id, path, opts \\ []), do: with_vm(id, &Vm.mkdir(&1, path, opts))

  @doc "Remove a file or empty directory in an existing VM through the host control channel."
  @spec unlink(Vm.id(), String.t(), keyword()) :: :ok | {:error, term()}
  def unlink(id, path, opts \\ []), do: with_vm(id, &Vm.unlink(&1, path, opts))

  @doc "Create a symbolic link in an existing VM through the host control channel."
  @spec symlink(Vm.id(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def symlink(id, target, link, opts \\ []), do: with_vm(id, &Vm.symlink(&1, target, link, opts))

  @doc "Host status for an existing VM."
  @spec status(Vm.id()) :: {:ok, map()} | {:error, :not_found}
  def status(id), do: with_vm(id, &Vm.status/1)

  @doc "Drain the next outbound egress relay event for an existing VM."
  @spec egress_next(Vm.id(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def egress_next(id, opts \\ []), do: with_vm(id, &Vm.egress_next(&1, opts))

  @doc "Answer an HTTP egress relay event."
  @spec egress_http_respond(Vm.id(), integer(), non_neg_integer(), String.t(), [{String.t(), String.t()}], binary(), keyword()) ::
          :ok | {:error, term()}
  def egress_http_respond(id, handle, status, reason, headers, body, opts \\ []),
    do: with_vm(id, &Vm.egress_http_respond(&1, handle, status, reason, headers, body, opts))

  @doc "Fail an HTTP egress relay event."
  @spec egress_http_fail(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_http_fail(id, handle, opts \\ []), do: with_vm(id, &Vm.egress_http_fail(&1, handle, opts))

  @doc "Answer a host_call egress relay event."
  @spec egress_host_call_respond(Vm.id(), integer(), binary(), keyword()) :: :ok | {:error, term()}
  def egress_host_call_respond(id, handle, result, opts \\ []),
    do: with_vm(id, &Vm.egress_host_call_respond(&1, handle, result, opts))

  @doc "Fail a host_call egress relay event."
  @spec egress_host_call_fail(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_host_call_fail(id, handle, opts \\ []),
    do: with_vm(id, &Vm.egress_host_call_fail(&1, handle, opts))

  @doc "Mark a WebSocket egress relay as connected."
  @spec egress_ws_open(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_ws_open(id, handle, opts \\ []), do: with_vm(id, &Vm.egress_ws_open(&1, handle, opts))

  @doc "Fail a WebSocket egress relay connection."
  @spec egress_ws_fail(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_ws_fail(id, handle, opts \\ []), do: with_vm(id, &Vm.egress_ws_fail(&1, handle, opts))

  @doc "Push one received WebSocket message into an egress relay connection."
  @spec egress_ws_push(Vm.id(), integer(), binary(), keyword()) :: :ok | {:error, term()}
  def egress_ws_push(id, handle, data, opts \\ []),
    do: with_vm(id, &Vm.egress_ws_push(&1, handle, data, opts))

  @doc "Mark a WebSocket egress relay as closed by the peer."
  @spec egress_ws_close(Vm.id(), integer(), keyword()) :: :ok | {:error, term()}
  def egress_ws_close(id, handle, opts \\ []), do: with_vm(id, &Vm.egress_ws_close(&1, handle, opts))

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
