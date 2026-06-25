defmodule AgentOS.Application do
  @moduledoc """
  The control-plane supervision tree. Two pieces today, both of which the VM facade
  (`AgentOS.ControlPlane`) addresses by name:

    * `AgentOS.VmRegistry` — a unique-key `Registry` mapping `{namespace, key}` → VM pid.
    * `AgentOS.VmSupervisor` — a `DynamicSupervisor` that starts VMs on demand and restarts
      them crash-only (`one_for_one`; each `AgentOS.Vm` is `restart: :transient`).

  This is the per-node core. The distribution layer (libcluster + Horde to place/fail-over VMs
  across nodes), the eviction sweeper, the quota accounting, and the wire/Phoenix edge are
  later additions to this tree (CONTROL_PLANE.md §7) — they slot in without changing the VM
  actor.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: AgentOS.VmRegistry},
      {DynamicSupervisor, name: AgentOS.VmSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: AgentOS.Supervisor)
  end
end
