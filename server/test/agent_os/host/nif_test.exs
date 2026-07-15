defmodule AgentOS.Host.NifTest do
  use ExUnit.Case, async: true

  # Proves the Bazel-built libhost_nif.so STAGES into priv/ and LOADS at runtime (the @on_load
  # path), AND that the real Rust boot path runs end to end: it validates the wasm and returns
  # the host's `{:error, message}` for bogus bytes — no kernel.wasm needed. If the .so failed to
  # stage/load, the call would raise the `:nif_not_loaded` stub instead. (Booting a real kernel
  # + exec is the heavier integration step.)
  test "the Bazel-built NIF loads from priv/ and the real boot path rejects bogus wasm" do
    assert {:error, msg} = AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil)
    assert is_binary(msg)
    assert msg =~ "kernel.wasm"
  end

  test "boot validates the Elixir option surface before calling the raw NIF" do
    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil, layers: [:not_binary]) ==
             {:error, "layers must be a list of binaries"}

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, <<>>, layers: [<<>>]) ==
             {:error, "base_image and layers are mutually exclusive"}

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil, deterministic: :yes) ==
             {:error, "deterministic must be a boolean"}

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil, workers: -1) ==
             {:error, "workers must be nil or a non-negative integer"}

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil, contract: {:bad, 0, 0}) ==
             {:error, "contract must be nil or {tier, budget_mib, fuel}"}

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil, net: :open) ==
             {:error, "net must be :deny, :relay, :real, or {:real, connections}"}

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil,
             connections: [{"openai.org.main", {:bearer, "tok"}}]
           ) ==
             {:error, "connections require net: :real"}

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil,
             net: {:real, [{"openai.org.main", {:bearer, "tok"}}]},
             connections: [{"google.org.main", {:bearer, "tok"}}]
           ) ==
             {:error,
              "connections must be specified either in net: {:real, ...} or :connections, not both"}

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil, net: :real, connections: [:bad]) ==
             {:error,
              "connection must be {ref, auth}, {ref, auth, origins}, or %{ref: ref, auth: auth}"}

    # A secret connection whose origins can't be derived (an integration NOT in the curated registry, so
    # no `servers` to fall back to) is rejected — every secret connection must reach a known origin.
    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil,
             net: :real,
             connections: [{"uncurated.org.main", {:bearer, "tok"}}]
           ) ==
             {:error, ~s(invalid connection "uncurated.org.main": missing origin)}

    assert {:error, msg} =
             AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil,
               net: :real,
               connections: [{"openai.org.main", {:bearer, "tok"}, ["https://api.openai.com"]}]
             )

    assert msg =~ "kernel.wasm"

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil, host_call: :open) ==
             {:error, "host_call must be :deny, :relay, or :sidecar"}

    assert AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil, persist: :open) ==
             {:error, "persist must be :deny or :relay"}
  end

  test "restore validates the Elixir option surface before calling the raw NIF" do
    assert AgentOS.Host.Nif.restore(<<0, 1, 2, 3>>, <<>>, deterministic: :yes) ==
             {:error, "deterministic must be a boolean"}

    assert AgentOS.Host.Nif.restore(<<0, 1, 2, 3>>, <<>>, workers: -1) ==
             {:error, "workers must be nil or a non-negative integer"}

    assert AgentOS.Host.Nif.restore(<<0, 1, 2, 3>>, <<>>,
             connections: [{"openai.org.main", {:bearer, "tok"}}]
           ) ==
             {:error, "connections require net: :real"}

    assert AgentOS.Host.Nif.restore(<<0, 1, 2, 3>>, <<>>, persist: :open) ==
             {:error, "persist must be :deny or :relay"}
  end
end
