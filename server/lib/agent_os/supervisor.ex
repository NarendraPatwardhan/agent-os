defmodule AgentOS.Supervisor do
  @moduledoc """
  The host-owned control-plane supervision tree.

  Add this supervisor to the consuming application's children list:

      children = [
        AgentOS.Supervisor
      ]

  It starts the VM owners and the transport-neutral sidecar lifecycle subsystem:

    * `AgentOS.VmRegistry` — a unique-key `Registry` mapping `{namespace, key}` to VM pid.
    * `AgentOS.VmSupervisor` — a `DynamicSupervisor` that starts VMs on demand and restarts
      them crash-only (`one_for_one`; each `AgentOS.Vm` is `restart: :transient`).

  This is the per-node core. The distribution layer, quota accounting, eviction, and
  Phoenix/wire edge belong in the host application around this supervisor.
  """

  use Supervisor
  require Logger

  @doc false
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    sidecar_opts = Keyword.get(opts, :sidecars, [])
    scope_limit = limit!(sidecar_opts, :max_scopes, 1_024)
    instance_limit = limit!(sidecar_opts, :max_instances, 4_096)
    firecracker_limit = limit!(sidecar_opts, :max_firecracker_instances, 64)

    {journal, journal_opts} =
      normalize_journal(Keyword.get(sidecar_opts, :journal, AgentOS.Sidecars.Journal.Memory))

    :persistent_term.put({AgentOS.Sidecars.Journal, :implementation}, journal)

    if journal == AgentOS.Sidecars.Journal.Memory do
      Logger.warning(
        "AgentOS sidecars are using the in-memory journal; configure a durable journal before relying on crash recovery"
      )
    end

    children = [
      {Registry, keys: :unique, name: AgentOS.VmRegistry},
      {DynamicSupervisor, name: AgentOS.VmSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: AgentOS.SidecarRegistry},
      {Task.Supervisor, name: AgentOS.SidecarTaskSupervisor},
      {DynamicSupervisor,
       name: AgentOS.SidecarScopeSupervisor, strategy: :one_for_one, max_children: scope_limit},
      {DynamicSupervisor,
       name: AgentOS.SidecarInstanceSupervisor,
       strategy: :one_for_one,
       max_children: instance_limit},
      {DynamicSupervisor,
       name: AgentOS.SidecarFirecrackerSupervisor,
       strategy: :one_for_one,
       max_children: firecracker_limit},
      {AgentOS.Sidecars.ProviderRegistry,
       providers: Keyword.get(sidecar_opts, :providers, []),
       placement: Keyword.get(sidecar_opts, :placement, AgentOS.Sidecars.Placement.Local),
       placement_opts: Keyword.get(sidecar_opts, :placement_opts, [])},
      {journal, journal_opts},
      {AgentOS.Sidecars.Egress, []},
      {AgentOS.Sidecars.Reconciler, sidecar_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp normalize_journal({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp normalize_journal(module) when is_atom(module), do: {module, []}

  defp limit!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, "sidecar #{key} must be a positive integer"
    end
  end
end
