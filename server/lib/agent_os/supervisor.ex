defmodule AgentOS.Supervisor do
  @moduledoc """
  The host-owned control-plane supervision tree.

  Add this supervisor to the consuming application's children list:

      children = [
        AgentOS.Supervisor
      ]

  It starts the two named processes the VM facade uses:

    * `AgentOS.VmRegistry` — a unique-key `Registry` mapping `{namespace, key}` to VM pid.
    * `AgentOS.VmSupervisor` — a `DynamicSupervisor` that starts VMs on demand and restarts
      them crash-only (`one_for_one`; each `AgentOS.Vm` is `restart: :transient`).

  This is the per-node core. The distribution layer, quota accounting, eviction, and
  Phoenix/wire edge belong in the host application around this supervisor.
  """

  use Supervisor

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: AgentOS.VmRegistry},
      {DynamicSupervisor, name: AgentOS.VmSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
