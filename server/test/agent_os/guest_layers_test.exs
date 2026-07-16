defmodule AgentOS.GuestLayersTest do
  use ExUnit.Case, async: true

  alias AgentOS.Contracts.Browser

  defp browser_grant(guest) do
    %{
      kind: Browser.browser_kind(),
      version: Browser.browser_version(),
      contract_digest: Browser.browser_contract_digest(),
      guest: guest
    }
  end

  test "deduplicates guest layers and preserves the base as the lowest layer" do
    assert {:ok, opts} =
             AgentOS.GuestLayers.compose(
               base_image: "base",
               sidecars: %{web: browser_grant(true), second: browser_grant(true)}
             )

    assert ["base", layer] = Keyword.fetch!(opts, :layers)
    assert is_binary(layer)
    assert :binary.match(layer, "bin/browser") != :nomatch
    refute Keyword.has_key?(opts, :base_image)
  end

  test "does not load layers for host-only grants or restores" do
    assert {:ok, opts} =
             AgentOS.GuestLayers.compose(base_image: "base", sidecars: [browser_grant(false)])

    assert Keyword.fetch!(opts, :base_image) == "base"
    refute Keyword.has_key?(opts, :layers)

    assert {:ok, restored} =
             AgentOS.GuestLayers.compose(snapshot: "snapshot", sidecars: [browser_grant(true)])

    assert Keyword.fetch!(restored, :snapshot) == "snapshot"
    refute Keyword.has_key?(restored, :layers)
  end

  test "leaves unregistered guest contracts to their own packaging" do
    assert {:ok, opts} =
             AgentOS.GuestLayers.compose(
               base_image: "base",
               sidecars: [
                 %{kind: "unknown", version: 1, contract_digest: "sha256:none", guest: true}
               ]
             )

    assert Keyword.fetch!(opts, :base_image) == "base"
    refute Keyword.has_key?(opts, :layers)
  end
end
