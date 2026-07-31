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
end
