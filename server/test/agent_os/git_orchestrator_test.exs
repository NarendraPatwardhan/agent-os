defmodule AgentOS.Git.OrchestratorTest do
  use ExUnit.Case, async: false

  alias AgentOS.Git.Orchestrator
  alias AgentOS.GitEngine

  @moduletag :git_engine

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
  defp fixture_transport do
    refs = [%{name: "refs/heads/main", hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]
    pack = <<>>

    fn
      :list_refs, {_url, _opts} -> {:ok, refs}
      :fetch_packs, {_url, _want, _have, _opts} -> {:ok, pack}
    end
  end

  @tag timeout: 60_000
  test "BEAM orch clone uses transport then Port apply (no C type-5 remote)" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"https://example.com/demo.git"}}),
               transport: fixture_transport()
             )

    assert is_binary(json)
    assert json =~ "\"ok\":true" or json =~ ~s("ok":true)
    assert json =~ "cloned"

    # host_call demux path
    assert {:ok, json2} =
             GitEngine.handle_host_call(
               pid,
               "git",
               ~s({"op":"fetch","args":{"url":"https://example.com/demo.git"}}),
               transport: fixture_transport()
             )

    assert is_binary(json2)

    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "missing url fails closed with code 2" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(pid, ~s({"op":"clone","args":{}}), transport: fixture_transport())

    assert json =~ "\"code\":2" or json =~ "need args.url"
    :ok = GitEngine.stop(pid)
  end
end
