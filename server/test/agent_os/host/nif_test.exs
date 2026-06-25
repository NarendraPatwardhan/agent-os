defmodule AgentOS.Host.NifTest do
  use ExUnit.Case, async: true

  # Proves the Bazel-built libhost_nif.so STAGES into priv/ and LOADS at runtime (the @on_load
  # path), AND that the real Rust boot path runs end to end: it validates the wasm and returns
  # the host's `{:error, message}` for bogus bytes — no kernel.wasm needed. If the .so failed to
  # stage/load, the call would raise the `:nif_not_loaded` stub instead. (Booting a real kernel
  # + exec is the next, heavier integration step.)
  test "the Bazel-built NIF loads from priv/ and the real boot path rejects bogus wasm" do
    assert {:error, msg} = AgentOS.Host.Nif.boot(<<0, 1, 2, 3>>, nil)
    assert is_binary(msg)
    assert msg =~ "kernel.wasm"
  end
end
