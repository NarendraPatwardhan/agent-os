defmodule AgentOS.GitEnginePackTest do
  @moduledoc """
  P0.3: real pack import → refs.import → clone.apply → worktree e2e.

  Requires a real native `git-engine` binary (`AGENTOS_GIT_ENGINE` absolute path).
  """
  use ExUnit.Case, async: false

  alias AgentOS.Git.Orchestrator
  alias AgentOS.GitEngine

  @moduletag :git_engine

  @fixture_dir Path.expand("../fixtures/git", __DIR__)
  @minimal_pack Path.join(@fixture_dir, "minimal.pack")
  @minimal_tip Path.join(@fixture_dir, "minimal.tip")
  @tip_hash "4451efc37195997f327c01ca7cef8173ccf67c6f"
  @ref_name "refs/heads/main"
  @fixture_url "https://example.com/demo.git"
  @fixture_origin "https://example.com"

  defp engine_path do
    System.get_env("AGENTOS_GIT_ENGINE") ||
      runfile_git_engine() ||
      flunk("AGENTOS_GIT_ENGINE not set and runfiles missing git-engine")
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

  defp read_pack! do
    assert File.regular?(@minimal_pack), "missing fixture #{@minimal_pack}"
    pack = File.read!(@minimal_pack)
    assert byte_size(pack) == 191
    assert match?(<<"PACK", _::binary>>, pack)
    pack
  end

  defp tip_hash! do
    tip = @minimal_tip |> File.read!() |> String.trim()
    assert tip == @tip_hash
    tip
  end

  defp engine_root(pid) do
    # Engine keeps root only internally; recover via :sys or run status path.
    # Port is started with a known tmp root when we pass :root.
    case :sys.get_state(pid) do
      %{root: root} when is_binary(root) -> root
      state when is_map(state) -> Map.get(state, :root) || flunk("no root in engine state")
      _ -> flunk("unexpected engine state")
    end
  end

  @tag timeout: 60_000
  test "import minimal.pack then refs.import + clone.apply yields worktree README" do
    path = engine_path()
    root = Path.join(System.tmp_dir!(), "pack-e2e-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(root)
    pack = read_pack!()
    tip = tip_hash!()

    assert {:ok, pid} = GitEngine.start(executable: path, root: root)
    assert engine_root(pid) == root

    assert {:ok, init} = GitEngine.run(pid, %{"op" => "init"})
    assert init["ok"] == true or (is_binary(Map.get(init, "raw")) and init["raw"] =~ "\"ok\":true")

    assert :ok = GitEngine.import_pack(pid, pack, final: true)

    # Pack must land under objects/pack (not objects/pack-*.pack).
    pack_files = Path.wildcard(Path.join(root, ".git/objects/pack/pack-*.pack"))
    assert pack_files != [], "expected pack under .git/objects/pack/, got: #{inspect(Path.wildcard(Path.join(root, ".git/objects/**/*")))}"

    assert {:ok, refs} =
             GitEngine.run(pid, %{
               "op" => "refs.import",
               "args" => %{"name" => @ref_name, "hash" => tip}
             })

    assert refs["ok"] == true or (is_binary(Map.get(refs, "raw")) and refs["raw"] =~ "\"ok\":true"),
           "refs.import failed: #{inspect(refs)}"

    assert {:ok, clone} =
             GitEngine.run(pid, %{"op" => "clone.apply", "args" => %{"head" => @ref_name}})

    assert clone["ok"] == true or (is_binary(Map.get(clone, "raw")) and clone["raw"] =~ "\"ok\":true"),
           "clone.apply failed: #{inspect(clone)}"

    assert {:ok, "hello\n"} = File.read(Path.join(root, "README"))

    assert {:ok, rev} = GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})
    stdout = rev["stdout"] || ""
    assert stdout =~ tip or (is_binary(Map.get(rev, "raw")) and rev["raw"] =~ String.slice(tip, 0, 8))

    :ok = GitEngine.stop(pid)
  after
    # best-effort cleanup
    :ok
  end

  @tag timeout: 60_000
  test "BEAM orch clone with real minimal.pack checks out worktree via fixture transport" do
    path = engine_path()
    root = Path.join(System.tmp_dir!(), "pack-orch-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(root)
    pack = read_pack!()
    tip = tip_hash!()

    transport = fn
      :list_refs, {_url, _opts} ->
        {:ok, [%{name: @ref_name, hash: tip}]}

      :fetch_packs, {_url, _want, _have, _opts} ->
        {:ok, pack}
    end

    assert {:ok, pid} = GitEngine.start(executable: path, root: root)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               transport: transport,
               allowed_origins: [@fixture_origin]
             )

    assert json =~ "\"ok\":true" or json =~ ~s("ok":true), "orch clone failed: #{json}"
    refute json =~ "empty pack"
    assert {:ok, "hello\n"} = File.read(Path.join(root, "README"))

    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 60_000
  test "empty pack and non-PACK body still fail closed (never ok:true)" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    empty_transport = fn
      :list_refs, _ -> {:ok, [%{name: @ref_name, hash: @tip_hash}]}
      :fetch_packs, _ -> {:ok, <<>>}
    end

    assert {:ok, empty_json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               transport: empty_transport,
               allowed_origins: [@fixture_origin]
             )

    assert empty_json =~ "\"ok\":false" or empty_json =~ ~s("ok":false)
    assert empty_json =~ "empty pack"
    refute empty_json =~ "cloned"

    # Non-PACK body is rejected by extract_pack on real http path; fixture that
    # returns garbage without PACK must not green as cloned either — orch still
    # requires non-empty, then import_pack may fail.
    junk_transport = fn
      :list_refs, _ -> {:ok, [%{name: @ref_name, hash: @tip_hash}]}
      :fetch_packs, _ -> {:ok, "not-a-pack-payload"}
    end

    assert {:ok, junk_json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               transport: junk_transport,
               allowed_origins: [@fixture_origin]
             )

    # Must not report success for junk pack body.
    refute junk_json =~ "\"ok\":true"
    refute junk_json =~ ~s("ok":true)

    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 60_000
  test "fetch.apply requires name+hash after pack import (no silent no-op)" do
    path = engine_path()
    root = Path.join(System.tmp_dir!(), "pack-fetch-" <> Integer.to_string(System.unique_integer([:positive])))
    File.mkdir_p!(root)
    pack = read_pack!()
    tip = tip_hash!()

    assert {:ok, pid} = GitEngine.start(executable: path, root: root)
    assert {:ok, _} = GitEngine.run(pid, %{"op" => "init"})
    assert :ok = GitEngine.import_pack(pid, pack, final: true)

    assert {:ok, refs} =
             GitEngine.run(pid, %{
               "op" => "refs.import",
               "args" => %{"name" => @ref_name, "hash" => tip}
             })

    assert refs["ok"] == true or (is_binary(Map.get(refs, "raw")) and refs["raw"] =~ "\"ok\":true")

    # Empty args must fail closed (P0.4).
    assert {:ok, bad} = GitEngine.run(pid, %{"op" => "fetch.apply", "args" => %{}})
    refute bad["ok"] == true

    assert {:ok, good} =
             GitEngine.run(pid, %{
               "op" => "fetch.apply",
               "args" => %{"name" => @ref_name, "hash" => tip, "remote" => "origin"}
             })

    assert good["ok"] == true or (is_binary(Map.get(good, "raw")) and good["raw"] =~ "\"ok\":true"),
           "fetch.apply failed: #{inspect(good)}"

    :ok = GitEngine.stop(pid)
  end
end
