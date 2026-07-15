defmodule AgentOS.SidecarsTest do
  use ExUnit.Case, async: false

  alias AgentOS.Contracts.Sidecar
  alias AgentOS.Sidecars

  defp id, do: {"sidecar-test", Integer.to_string(System.unique_integer([:positive]))}

  defp grant(guest \\ true) do
    %{
      kind: "test.echo",
      version: 1,
      contract_digest: "test-echo-v1",
      guest: guest,
      max_instances: 2,
      fork: Sidecar.sidecar_fork_omit(),
      config: <<>>
    }
  end

  test "a VM scope owns grants, instances, calls, and an omit-with-warning fork barrier" do
    vm_id = id()
    assert {:ok, _scope} = Sidecars.attach_vm(vm_id, self(), %{"echo" => grant()})

    assert {:ok, instance} =
             Sidecars.create(vm_id, %{
               grant: "echo",
               kind: "test.echo",
               body: "metadata",
               idempotency_key: "create-1",
               timeout_ms: 1_000
             })

    request = %{
      id: instance.id,
      generation: instance.generation,
      grant: "echo",
      kind: "test.echo",
      operation: "echo",
      body: "hello",
      timeout_ms: 1_000
    }

    assert {:ok, "hello"} = Sidecars.invoke(vm_id, request, guest: true)
    assert {:ok, [warning]} = Sidecars.begin_fork(vm_id)
    assert warning.code == Sidecar.sidecar_warning_fork_omitted()
    assert {:error, :sidecar_closing} = Sidecars.invoke(vm_id, request)
    assert :ok = Sidecars.end_fork(vm_id)
    assert {:ok, "hello"} = Sidecars.invoke(vm_id, request)
    assert :ok = Sidecars.close_vm(vm_id)
  end

  test "guest invocation is checked again at the host-owned grant" do
    vm_id = id()
    assert {:ok, _scope} = Sidecars.attach_vm(vm_id, self(), %{"private" => grant(false)})

    assert {:ok, instance} =
             Sidecars.create(vm_id, %{
               grant: "private",
               kind: "test.echo",
               body: <<>>,
               idempotency_key: "create-private",
               timeout_ms: 1_000
             })

    request = %{
      id: instance.id,
      generation: instance.generation,
      grant: "private",
      kind: "test.echo",
      operation: "echo",
      body: "secret",
      timeout_ms: 1_000
    }

    assert {:error, :sidecar_permission_denied} = Sidecars.invoke(vm_id, request, guest: true)
    assert {:ok, "secret"} = Sidecars.invoke(vm_id, request)
    assert :ok = Sidecars.close_vm(vm_id)
  end

  test "an idempotency key cannot be reused for different create content" do
    vm_id = id()
    assert {:ok, _scope} = Sidecars.attach_vm(vm_id, self(), %{"echo" => grant()})

    base = %{
      grant: "echo",
      kind: "test.echo",
      body: "one",
      idempotency_key: "same-key",
      timeout_ms: 1_000
    }

    assert {:ok, first} = Sidecars.create(vm_id, base)
    assert {:ok, same} = Sidecars.create(vm_id, base)
    assert same.id == first.id
    assert {:error, :sidecar_idempotency_conflict} = Sidecars.create(vm_id, %{base | body: "two"})
    assert :ok = Sidecars.close_vm(vm_id)
  end

  test "provider limits apply across grants of the same kind" do
    vm_id = id()
    assert {:ok, _scope} = Sidecars.attach_vm(vm_id, self(), %{"left" => grant(), "right" => grant()})

    for {name, key} <- [{"left", "left-1"}, {"right", "right-1"}] do
      assert {:ok, _instance} =
               Sidecars.create(vm_id, %{
                 grant: name,
                 kind: "test.echo",
                 body: <<>>,
                 idempotency_key: key,
                 timeout_ms: 1_000
               })
    end

    assert {:error, :sidecar_limit} =
             Sidecars.create(vm_id, %{
               grant: "right",
               kind: "test.echo",
               body: <<>>,
               idempotency_key: "right-2",
               timeout_ms: 1_000
             })

    assert :ok = Sidecars.close_vm(vm_id)
  end

  test "clone grants are rejected until providers can produce independent state" do
    vm_id = id()
    clone = %{grant() | fork: Sidecar.sidecar_fork_clone()}
    assert {:error, :sidecar_unsupported_fork_policy} = Sidecars.attach_vm(vm_id, self(), %{"echo" => clone})
  end

  test "lease renewal must leave time for a missed heartbeat" do
    vm_id = id()

    assert {:error, :sidecar_invalid_request} =
             Sidecars.attach_vm(vm_id, self(), %{"echo" => grant()},
               lease_ttl_ms: 100,
               renew_ms: 60
             )
  end

  test "a rejected provider binding is rolled back and leaves no pending create intent" do
    vm_id = id()
    pending = AgentOS.Sidecars.Journal.Memory.pending()
    assert {:ok, _scope} = Sidecars.attach_vm(vm_id, self(), %{"echo" => grant()})

    assert {:error, :sidecar_limit} =
             Sidecars.create(vm_id, %{
               grant: "echo",
               kind: "test.echo",
               body: "oversized-metadata",
               idempotency_key: "bad-provider-binding",
               timeout_ms: 1_000
             })

    assert AgentOS.Sidecars.Journal.Memory.pending() == pending
    assert :ok = Sidecars.close_vm(vm_id)
  end

  test "fork admission waits for active calls and lease renewal keeps live instances current" do
    vm_id = id()

    assert {:ok, _scope} =
             Sidecars.attach_vm(vm_id, self(), %{"echo" => grant()},
               lease_ttl_ms: 100,
               renew_ms: 20
             )

    assert {:ok, instance} =
             Sidecars.create(vm_id, %{
               grant: "echo",
               kind: "test.echo",
               body: <<>>,
               idempotency_key: "lease",
               timeout_ms: 1_000
             })

    started_ref = make_ref()

    request = %{
      id: instance.id,
      generation: instance.generation,
      grant: "echo",
      kind: "test.echo",
      operation: "wait",
      body: :erlang.term_to_binary({self(), started_ref, "done"}),
      timeout_ms: 1_000
    }

    call = Task.async(fn -> Sidecars.invoke(vm_id, request) end)
    assert_receive {^started_ref, :sidecar_call_started}, 1_000
    started = System.monotonic_time(:millisecond)
    assert {:ok, [_warning]} = Sidecars.begin_fork(vm_id)
    assert System.monotonic_time(:millisecond) - started >= 20
    assert {:ok, "done"} = Task.await(call)
    assert :ok = Sidecars.end_fork(vm_id)

    Process.sleep(110)
    assert {:ok, renewed} = Sidecars.retrieve(vm_id, instance.id)
    assert renewed.expires_at_ms > instance.expires_at_ms
    assert :ok = Sidecars.close_vm(vm_id)
  end

  test "scope replacement waits for the old owner boundary to terminate" do
    vm_id = id()
    assert {:ok, old} = Sidecars.attach_vm(vm_id, self(), %{"echo" => grant()})
    owner = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, replacement} = Sidecars.attach_vm(vm_id, owner, %{"echo" => grant()})
    refute replacement == old
    assert AgentOS.Sidecars.Scope.owner(replacement) == owner
    Process.exit(owner, :kill)
  end

  test "a fork barrier belongs to its acquiring process and reopens when that process exits" do
    vm_id = id()
    assert {:ok, _scope} = Sidecars.attach_vm(vm_id, self(), %{"echo" => grant()})
    test = self()

    forker =
      spawn(fn ->
        send(test, {:fork_barrier, Sidecars.begin_fork(vm_id)})
        Process.sleep(:infinity)
      end)

    assert_receive {:fork_barrier, {:ok, []}}, 1_000
    assert {:error, :sidecar_closing} = Sidecars.list(vm_id)
    assert {:error, :sidecar_permission_denied} = Sidecars.end_fork(vm_id)

    monitor = Process.monitor(forker)
    Process.exit(forker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^forker, :killed}, 1_000
    assert [] = await_open_scope(vm_id, 50)
    assert :ok = Sidecars.close_vm(vm_id)
  end

  test "memory journal removes completed ids from its deterministic pending order" do
    assert {:ok, first} =
             AgentOS.Sidecars.Journal.Memory.append(%{
               op: :create,
               id: "sc_abcdefghijkl",
               tag: "first"
             })

    assert {:ok, second} =
             AgentOS.Sidecars.Journal.Memory.append(%{
               op: :delete,
               id: "sc_mnopqrstuvwx",
               tag: "second"
             })

    assert [first_entry, second_entry] = AgentOS.Sidecars.Journal.Memory.pending()
    assert {first_entry.journal_id, first_entry.id, first_entry.tag} ==
             {first, "sc_abcdefghijkl", "first"}

    assert {second_entry.journal_id, second_entry.id, second_entry.tag} ==
             {second, "sc_mnopqrstuvwx", "second"}

    assert :ok = AgentOS.Sidecars.Journal.Memory.complete(first, %{})
    assert Enum.map(AgentOS.Sidecars.Journal.Memory.pending(), & &1.tag) == ["second"]
    assert :ok = AgentOS.Sidecars.Journal.Memory.complete(second, %{})
  end

  defp await_open_scope(vm_id, attempts) do
    case Sidecars.list(vm_id) do
      items when is_list(items) -> items
      {:error, :sidecar_closing} when attempts > 0 ->
        Process.sleep(10)
        await_open_scope(vm_id, attempts - 1)
      other -> flunk("sidecar scope did not reopen: #{inspect(other)}")
    end
  end
end
