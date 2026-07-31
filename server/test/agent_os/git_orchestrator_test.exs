defmodule AgentOS.Git.OrchestratorTest do
  use ExUnit.Case, async: false

  alias AgentOS.Git.Orchestrator
  alias AgentOS.Git.SmartHttp
  alias AgentOS.GitEngine

  @moduletag :git_engine

  @fixture_url "https://example.com/demo.git"
  @fixture_origin "https://example.com"

  defp engine_path do
    System.get_env("AGENTOS_GIT_ENGINE") ||
      runfile_git_engine() ||
      flunk("AGENTOS_GIT_ENGINE not set")
  end

  defp runfile_git_engine do
    rf = System.get_env("RUNFILES_DIR") || System.get_env("TEST_SRCDIR")

    candidates =
      [
        "memcontainers/lib/git-engine/git-engine",
        "_main/memcontainers/lib/git-engine/git-engine"
      ]
      |> Enum.flat_map(fn rel ->
        base = if rf, do: [Path.join(rf, rel), Path.join(rf, "_main/" <> rel)], else: []
        [rel | base]
      end)

    Enum.find(candidates, &File.regular?/1)
  end

  # Fixture transport: no real network (K16 BEAM orch + Port apply).
  # Prefer explicit allowed_origins matching the fixture URL (not :any).
  defp fixture_transport(pack \\ <<>>) do
    refs = [%{name: "refs/heads/main", hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]

    fn
      :list_refs, {_url, _opts} -> {:ok, refs}
      :fetch_packs, {_url, _want, _have, _opts} -> {:ok, pack}
    end
  end

  defp orch_opts(pack \\ <<>>) do
    [
      transport: fixture_transport(pack),
      allowed_origins: [@fixture_origin]
    ]
  end

  # Minimal git pack v2 with 0 objects + SHA-1 trailer (non-empty, has PACK magic).
  # Import may fail or succeed with no objects — used to prove empty-pack skip is gone.
  defp minimal_pack_bytes do
    header = "PACK" <> <<0, 0, 0, 2>> <> <<0, 0, 0, 0>>
    checksum = :crypto.hash(:sha, header)
    header <> checksum
  end

  # ── Origin / URL unit policy ───────────────────────────────────────────────

  test "request_origin accepts http(s) and rejects userinfo / bad scheme / no host" do
    assert {:ok, "https://example.com"} = SmartHttp.request_origin("https://example.com/repo.git")
    assert {:ok, "http://example.com"} = SmartHttp.request_origin("http://EXAMPLE.com:80/x")
    assert {:ok, "https://example.com:8443"} = SmartHttp.request_origin("https://example.com:8443/")

    assert :error = SmartHttp.request_origin("https://user:pass@example.com/repo.git")
    assert :error = SmartHttp.request_origin("git://example.com/repo.git")
    assert :error = SmartHttp.request_origin("ssh://git@example.com/repo.git")
    assert :error = SmartHttp.request_origin("not-a-url")
    assert :error = SmartHttp.request_origin("https:///no-host")
  end

  test "origin_allowed? fail-closed on empty list; matches canonical origin" do
    assert SmartHttp.origin_allowed?(["https://example.com"], "https://EXAMPLE.com/r.git")
    assert SmartHttp.origin_allowed?(["https://example.com:443"], "https://example.com/r.git")
    refute SmartHttp.origin_allowed?([], "https://example.com/r.git")
    refute SmartHttp.origin_allowed?(["https://other.com"], "https://example.com/r.git")
  end

  test "extract_pack requires PACK magic" do
    assert {:ok, <<"PACK", _::binary>>} = SmartHttp.extract_pack("pkt\nPACKdata")
    assert {:error, :no_pack_magic} = SmartHttp.extract_pack("no pack here")
    assert {:error, :no_pack_magic} = SmartHttp.extract_pack(<<>>)
  end

  # ── Orchestrator security gates ────────────────────────────────────────────

  @tag timeout: 30_000
  test "origin not allowlisted fails closed" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               transport: fixture_transport(),
               allowed_origins: ["https://other.example"]
             )

    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ "not allowlisted"
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "missing allowed_origins fails closed by default" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               transport: fixture_transport()
             )

    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ "not allowlisted"
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "empty allowed_origins fails closed" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               transport: fixture_transport(),
               allowed_origins: []
             )

    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ "not allowlisted"
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "bad scheme fails before transport dial" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    dialed = :atomics.new(1, signed: false)

    transport = fn
      :list_refs, _ ->
        :atomics.put(dialed, 1, 1)
        {:ok, []}

      :fetch_packs, _ ->
        :atomics.put(dialed, 1, 1)
        {:ok, <<>>}
    end

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"git://example.com/demo.git"}}),
               transport: transport,
               allowed_origins: ["https://example.com"]
             )

    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ "http(s)" or json =~ "credentials"
    assert :atomics.get(dialed, 1) == 0
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "userinfo URL fails closed" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"https://user:pass@example.com/demo.git"}}),
               transport: fixture_transport(),
               allowed_origins: [@fixture_origin]
             )

    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ "credentials" or json =~ "http(s)"
    :ok = GitEngine.stop(pid)
  end

  # ── Empty pack honesty (P0.2) ──────────────────────────────────────────────

  @tag timeout: 60_000
  test "empty pack after list_refs fails closed (not cloned)" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               orch_opts(<<>>)
             )

    assert is_binary(json)
    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ "empty pack"
    refute json =~ "cloned"
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 60_000
  test "BEAM orch clone with non-empty pack attempts apply (no empty-pack skip)" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    pack = minimal_pack_bytes()
    assert byte_size(pack) > 0
    assert match?(<< "PACK", _::binary >>, pack)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               orch_opts(pack)
             )

    assert is_binary(json)
    # 0-object pack may fail import or refs — must not be the empty-pack short-circuit.
    refute json =~ "empty pack"

    # host_call demux path also gates origins + empty pack
    assert {:ok, json2} =
             GitEngine.handle_host_call(
               pid,
               "git",
               ~s({"op":"fetch","args":{"url":"#{@fixture_url}"}}),
               orch_opts(<<>>)
             )

    assert is_binary(json2)
    assert json2 =~ "\"ok\":false" or json2 =~ ~s("ok":false)
    assert json2 =~ "empty pack"

    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "missing url fails closed with code 2" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(pid, ~s({"op":"clone","args":{}}), orch_opts())

    assert json =~ "\"code\":2" or json =~ "need args.url"
    :ok = GitEngine.stop(pid)
  end

  # ── P2.1 push fail-closed on server ────────────────────────────────────────

  @tag timeout: 30_000
  test "push always fails closed on server (fetch/clone only)" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"push","args":{"url":"#{@fixture_url}"}}),
               orch_opts()
             )

    assert is_binary(json)
    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    refute json =~ "\"ok\":true"
    assert json =~ "push not supported" or json =~ "fetch/clone only"
    assert json =~ "\"code\":1" or json =~ ~s("code":1)

    # host_call demux path also fails closed
    assert {:ok, json2} =
             GitEngine.handle_host_call(
               pid,
               "git",
               ~s({"op":"push","args":{"url":"#{@fixture_url}"}}),
               orch_opts()
             )

    assert json2 =~ "\"ok\":false" or json2 =~ ~s("ok":false)
    refute json2 =~ "\"ok\":true"
    assert json2 =~ "push not supported" or json2 =~ "fetch/clone only"

    :ok = GitEngine.stop(pid)
  end

  # ── P1.7 foundation: async git host_call via Vm ────────────────────────────

  @tag timeout: 120_000
  test "try_answer_git_host_call returns :answered without blocking on remote orch" do
    # Real kernel VM + attach_git with fixture transport (no network).
    # Proves P1.6: name "git" is claimed async (GenServer returns immediately).
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      # Residual: full guest CAP_NET e2e needs kernel/images + host_nif runfiles.
      IO.puts(:stderr, "skipping Vm async git test: kernel/posix runfiles missing")
    else
      id = {"git-async", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}
      pack = File.read!(Path.expand("../fixtures/git/minimal.pack", __DIR__))
      tip = File.read!(Path.expand("../fixtures/git/minimal.tip", __DIR__)) |> String.trim()

      transport = fn
        :list_refs, _ ->
          # Artificial delay so a sync path would freeze the GenServer call.
          Process.sleep(200)
          {:ok, [%{name: "refs/heads/main", hash: tip}]}

        :fetch_packs, _ ->
          {:ok, pack}
      end

      try do
        assert {:ok, _pid} =
                 AgentOS.ControlPlane.create(id,
                   wasm: wasm,
                   base_image: posix,
                   deterministic: true,
                   workers: 0,
                   host_call: :relay
                 )

        assert :ok =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   allowed_origins: [@fixture_origin],
                   transport: transport
                 )

        info0 = AgentOS.ControlPlane.info(id)
        assert info0.git_attached == true
        assert info0.git_allowed_origins == [@fixture_origin]

        event = %{
          kind: :host_call,
          handle: 9_001,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}"}})
        }

        # Must return promptly — not blocked on the 200ms fixture sleep.
        {usec, reply} =
          :timer.tc(fn ->
            AgentOS.Vm.try_answer_git_host_call(AgentOS.ControlPlane.whereis(id), event)
          end)

        assert reply == :answered
        assert usec < 150_000, "try_answer_git_host_call blocked (#{usec}µs); expected async"

        # Inflight task drains; allow NIF fail on synthetic handle.
        assert_eventually(fn ->
          AgentOS.ControlPlane.info(id).git_inflight == 0
        end)

        # Detach cancels any residual tasks cleanly.
        assert :ok = AgentOS.ControlPlane.detach_git(id)
        assert AgentOS.ControlPlane.info(id).git_attached == false
      after
        AgentOS.ControlPlane.dispose(id)
      end
    end
  end

  @tag timeout: 120_000
  test "concurrent remotes serialize: at most one running Task, second queues" do
    # Two overlapping name=="git" host_calls must not run Orchestrator concurrently
    # on the same VM (import+apply interleave risk). Queue holds the second until
    # the first Task completes.
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      IO.puts(:stderr, "skipping concurrent remote serialize test: kernel/posix runfiles missing")
    else
      id = {"git-serial", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}
      pack = File.read!(Path.expand("../fixtures/git/minimal.pack", __DIR__))
      tip = File.read!(Path.expand("../fixtures/git/minimal.tip", __DIR__)) |> String.trim()
      gate = :atomics.new(1, signed: false)
      max_concurrent = :atomics.new(1, signed: false)
      in_flight = :atomics.new(1, signed: false)

      transport = fn
        :list_refs, _ ->
          cur = :atomics.add_get(in_flight, 1, 1)
          # Track peak concurrent transport entry (proxy for concurrent orch).
          peak = :atomics.get(max_concurrent, 1)
          if cur > peak, do: :atomics.put(max_concurrent, 1, cur)
          # Hold first remote in transport so second can enqueue.
          if :atomics.get(gate, 1) == 0 do
            Process.sleep(150)
          end

          :atomics.sub(in_flight, 1, 1)
          {:ok, [%{name: "refs/heads/main", hash: tip}]}

        :fetch_packs, _ ->
          {:ok, pack}
      end

      try do
        assert {:ok, _pid} =
                 AgentOS.ControlPlane.create(id,
                   wasm: wasm,
                   base_image: posix,
                   deterministic: true,
                   workers: 0,
                   host_call: :relay
                 )

        assert :ok =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   allowed_origins: [@fixture_origin],
                   transport: transport
                 )

        vm = AgentOS.ControlPlane.whereis(id)

        e1 = %{
          kind: :host_call,
          handle: 9_101,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}"}})
        }

        e2 = %{
          kind: :host_call,
          handle: 9_102,
          name: "git",
          body: ~s({"op":"fetch","args":{"url":"#{@fixture_url}"}})
        }

        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, e1)
        # Second should enqueue while first Task is still running (or about to).
        Process.sleep(20)
        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, e2)

        info_mid = AgentOS.ControlPlane.info(id)
        # At most one remote Task running; second is queued or already finished.
        assert info_mid.git_remote_running <= 1
        assert info_mid.git_inflight >= 1

        # Release any hold and wait for both to drain.
        :atomics.put(gate, 1, 1)

        assert_eventually(fn ->
          AgentOS.ControlPlane.info(id).git_inflight == 0
        end)

        # Transport never overlapped (queue serialized orch entry).
        assert :atomics.get(max_concurrent, 1) <= 1

        assert :ok = AgentOS.ControlPlane.detach_git(id)
      after
        AgentOS.ControlPlane.dispose(id)
      end
    end
  end

  defp runfile_bytes(rel) do
    # __DIR__ is server/test/agent_os → repo root is ../../.. ; mix cwd is often server/.
    roots =
      [
        System.get_env("RUNFILES_DIR") && Path.join(System.get_env("RUNFILES_DIR"), "_main"),
        System.get_env("RUNFILES_DIR"),
        System.get_env("TEST_SRCDIR") && System.get_env("TEST_WORKSPACE") &&
          Path.join([System.get_env("TEST_SRCDIR"), System.get_env("TEST_WORKSPACE")]),
        System.get_env("TEST_SRCDIR") && Path.join(System.get_env("TEST_SRCDIR"), "_main"),
        Path.expand("../../../bazel-bin", __DIR__),
        Path.expand("../../bazel-bin", __DIR__),
        Path.expand("..", File.cwd!()),
        Path.expand("../bazel-bin", File.cwd!()),
        Path.expand("bazel-bin", File.cwd!())
      ]
      |> Enum.reject(&is_nil/1)

    case Enum.find_value(roots, fn root ->
           candidate = Path.join(root, rel)
           if File.regular?(candidate), do: candidate
         end) do
      nil -> nil
      file -> File.read!(file)
    end
  end

  defp assert_eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        assert_eventually(fun, attempts - 1)
    end
  end
end
