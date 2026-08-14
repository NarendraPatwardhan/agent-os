defmodule AgentOS.Sidecars.Firecracker.InstanceSupervisor do
  @moduledoc false
  use Supervisor, restart: :temporary

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    context = Keyword.fetch!(opts, :context)
    request = Keyword.fetch!(opts, :request)

    children = [
      {AgentOS.Sidecars.Firecracker.Machine, opts},
      {AgentOS.Sidecars.Firecracker.RunnerConnection,
       id: id,
       kind: context.kind,
       version: context.version,
       contract_digest: context.contract_digest,
       init_body: request.body},
      {AgentOS.Sidecars.Firecracker.CgroupMeter, id: id}
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end
end
