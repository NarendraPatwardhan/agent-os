defmodule AgentOS.Sidecars.Placement do
  @moduledoc "Placement policy boundary between the portable server lifecycle and runner topology."

  @callback select(String.t(), map(), keyword()) ::
              {:ok, {module(), keyword()}} | {:error, term()}
end

defmodule AgentOS.Sidecars.Placement.Local do
  @moduledoc "Same-node placement used by the self-hosted reference server."
  @behaviour AgentOS.Sidecars.Placement

  @impl true
  def select(kind, _context, _opts), do: AgentOS.Sidecars.ProviderRegistry.lookup(kind, :local)
end
