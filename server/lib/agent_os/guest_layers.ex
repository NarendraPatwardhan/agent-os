defmodule AgentOS.GuestLayers do
  @moduledoc """
  Resolves remote guest-enabled sidecar grants to server-owned filesystem layers.

  The registry is the only kind-aware edge. Composition is generic, contract-exact, deduplicated,
  and ordered by the registry rather than caller map order.
  """

  alias AgentOS.Contracts.Browser

  @layers [
    %{
      id: "browserctl",
      kind: Browser.browser_kind(),
      version: Browser.browser_version(),
      contract_digest: Browser.browser_contract_digest(),
      artifact: "browserctl.tar"
    }
  ]

  @spec compose(keyword()) :: {:ok, keyword()} | {:error, term()}
  def compose(opts) do
    if Keyword.get(opts, :snapshot) do
      {:ok, opts}
    else
      with {:ok, required} <- required(Keyword.get(opts, :sidecars) || []),
           {:ok, layers} <- read_layers(required) do
        {:ok, append_layers(opts, layers)}
      end
    end
  end

  @spec required(map() | list()) :: {:ok, [map()]} | {:error, term()}
  def required(grants) when is_map(grants), do: required(Map.values(grants))

  def required(grants) when is_list(grants) do
    requested =
      grants
      |> Enum.filter(&guest?/1)
      |> MapSet.new(&contract_key/1)

    {:ok, Enum.filter(@layers, &MapSet.member?(requested, contract_key(&1)))}
  end

  def required(_grants), do: {:error, :invalid_sidecar_grants}

  defp read_layers(required) do
    Enum.reduce_while(required, {:ok, []}, fn layer, {:ok, layers} ->
      path = Application.app_dir(:agent_os, Path.join("priv", layer.artifact))

      case File.read(path) do
        {:ok, bytes} -> {:cont, {:ok, [bytes | layers]}}
        {:error, reason} -> {:halt, {:error, {:guest_layer_unavailable, layer.id, reason}}}
      end
    end)
    |> case do
      {:ok, layers} -> {:ok, Enum.reverse(layers)}
      error -> error
    end
  end

  defp append_layers(opts, []), do: opts

  defp append_layers(opts, guest_layers) do
    case Keyword.pop(opts, :base_image) do
      {nil, opts} -> Keyword.update(opts, :layers, guest_layers, &(&1 ++ guest_layers))
      {base, opts} -> Keyword.put(opts, :layers, [base | guest_layers])
    end
  end

  defp guest?(grant) when is_map(grant),
    do: Map.get(grant, :guest, Map.get(grant, "guest", false)) == true

  defp guest?(_grant), do: false

  defp contract_key(value) do
    {
      Map.get(value, :kind, Map.get(value, "kind")),
      Map.get(value, :version, Map.get(value, "version")),
      Map.get(value, :contract_digest, Map.get(value, "contract_digest"))
    }
  end
end
