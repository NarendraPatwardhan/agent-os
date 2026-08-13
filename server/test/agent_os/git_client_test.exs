defmodule AgentOS.Git.ClientTest do
  use ExUnit.Case, async: true

  alias AgentOS.Git.Client

  test "returns transport failures instead of raising" do
    assert {:error, _reason} = Client.status(self(), timeout: 1)
  end
end
