defmodule AgentOS.Git.ClientTest do
  use ExUnit.Case, async: true

  alias AgentOS.Git.Client

  test "returns transport failures instead of raising" do
    assert {:error, _reason} = Client.status(self(), timeout: 1)
  end

  test "checkout encodes an explicit force option" do
    assert {:error, _reason} = Client.checkout(self(), String.duplicate("a", 40), force: true)
  end
end
