defmodule AgentOS.ControlPlaneTest do
  use ExUnit.Case, async: true

  alias AgentOS.ControlPlane

  # Exercises the OTP control-plane layer (the supervision tree + registry + facade) with REAL
  # processes and no mocks (B6) — and without a kernel.wasm, by covering the addressing/error
  # paths. Booting a real VM through the facade is the end-to-end step that needs the kernel +
  # image artifacts wired as test data.

  test "the supervision tree is up: registry + dynamic supervisor are running" do
    assert is_pid(Process.whereis(AgentOS.VmRegistry))
    assert is_pid(Process.whereis(AgentOS.VmSupervisor))
    assert is_list(ControlPlane.list())
  end

  test "addressing a VM that does not exist returns :not_found, never a crash" do
    id = {"test-ns", "does-not-exist"}

    assert ControlPlane.whereis(id) == nil
    assert ControlPlane.exec(id, "ls") == {:error, :not_found}
    assert ControlPlane.snapshot(id) == {:error, :not_found}
    assert ControlPlane.dispose(id) == {:error, :not_found}
  end
end
