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

  @doc "Snapshot an existing VM."
  @spec snapshot(Vm.id()) :: {:ok, binary()} | {:error, :not_found}
  def snapshot(id), do: with_vm(id, &Vm.snapshot/1)

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
