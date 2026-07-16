defmodule AgentOS.Sidecars.Provider do
  @moduledoc """
  Host-private implementation boundary for one or more sidecar kinds.

  Provider references never cross the AgentOS server boundary. Every callback receives the owning VM
  scope explicitly; implementations must not recover tenancy or authority from process globals.
  """

  @type context :: %{
          vm_id: AgentOS.Vm.id(),
          id: String.t(),
          grant: String.t(),
          kind: String.t(),
          version: pos_integer(),
          contract_digest: String.t(),
          grant_config: binary()
        }
  @type provider_ref :: term()

  @callback capabilities(keyword()) :: [map()]
  @callback create(context(), map(), keyword()) ::
              {:ok, provider_ref(), binary()} | {:error, term()}
  @callback inspect(context(), provider_ref(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback renew(context(), provider_ref(), integer(), keyword()) :: :ok | {:error, term()}
  @callback invoke(context(), provider_ref(), String.t(), binary(), keyword()) ::
              {:ok, binary()} | {:error, term()}
  @callback delete(context(), provider_ref(), keyword()) :: :ok | {:error, term()}
  @callback cancel(context(), provider_ref(), reference(), keyword()) :: :ok | {:error, term()}
  @callback reconcile(keyword()) :: :ok | {:error, term()}

  @optional_callbacks cancel: 4, reconcile: 1
end
