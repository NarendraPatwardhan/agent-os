defmodule AgentOS.FirecrackerTest do
  use ExUnit.Case, async: false
  @moduletag :kvm

  alias AgentOS.Contracts.Runner
  alias AgentOS.Sidecars

  test "real KVM runner boots, exchanges generated frames, and is removed" do
    vm_id = {"kvm", Integer.to_string(System.unique_integer([:positive]))}

    grant = %{
      kind: Runner.runner_health_kind(),
      version: 1,
      contract_digest: Runner.runner_health_contract_digest(),
      guest: true,
      max_instances: 1,
      fork: AgentOS.Contracts.Sidecar.sidecar_fork_omit(),
      config: <<>>
    }

    assert {:ok, _scope} = Sidecars.attach_vm(vm_id, self(), %{"health" => grant})

    assert {:ok, instance} =
             Sidecars.create(vm_id, %{
               grant: "health",
               kind: Runner.runner_health_kind(),
               body: <<>>,
               idempotency_key: "kvm-health",
               timeout_ms: 20_000
             })

    assert {:ok, hello} = Runner.decode_runner_hello(instance.metadata)
    assert hello.agent == "agentos-health"
    assert hello.kind == Runner.runner_health_kind()
    assert hello.version == 1
    assert hello.contract_digest == Runner.runner_health_contract_digest()

    assert {:ok, "hello from kvm"} =
             Sidecars.invoke(vm_id, %{
               id: instance.id,
               generation: instance.generation,
               grant: "health",
               kind: Runner.runner_health_kind(),
               operation: "echo",
               body: "hello from kvm",
               timeout_ms: 5_000
             })

    instance_root = Path.join(Application.fetch_env!(:agent_os, :firecracker_test_root), instance.id)
    assert File.dir?(instance_root)
    assert :ok = Sidecars.close_vm(vm_id)
    refute File.exists?(instance_root)
  end
end
