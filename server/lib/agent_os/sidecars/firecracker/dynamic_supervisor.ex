defmodule AgentOS.Sidecars.Firecracker.DynamicSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(opts) do
    max_children = Keyword.fetch!(opts, :max_children)
    DynamicSupervisor.start_link(__MODULE__, max_children, name: __MODULE__)
  end

  @impl true
  def init(max_children) do
    DynamicSupervisor.init(strategy: :one_for_one, max_children: max_children)
  end
end
