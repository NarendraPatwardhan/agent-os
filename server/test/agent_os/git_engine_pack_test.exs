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

  # D20: orch sparse_cone → Port sparse-set after clone.apply (JS sparseCone parity).
  @tag timeout: 60_000
  test "D20 BEAM orch clone with sparse_cone writes sparse-checkout and keeps root README" do
    path = engine_path()
    root =
      Path.join(
        System.tmp_dir!(),
        "pack-sparse-" <> Integer.to_string(System.unique_integer([:positive]))
      )

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
               allowed_origins: [@fixture_origin],
               sparse_cone: ["src", "/docs/"]
             )

    assert json =~ "\"ok\":true" or json =~ ~s("ok":true), "sparse clone failed: #{json}"
    # Root files always in cone template (/*); fixture only has README.
    assert {:ok, "hello\n"} = File.read(Path.join(root, "README"))

    sc = Path.join(root, ".git/info/sparse-checkout")
    assert File.regular?(sc), "sparse-set must write sparse-checkout"
    body = File.read!(sc)
    assert body =~ "/*"
    assert body =~ "!/*/"
    assert body =~ "/src/"
    assert body =~ "/src/**"
    assert body =~ "/docs/"
    assert body =~ "/docs/**"

    # Alias key git_sparse_cone also accepted (normalize slashes).
    :ok = GitEngine.stop(pid)
  after
    :ok
  end

  # D13 / M7 v1: multi-path tree + depth=1 + sparse_cone → out-of-cone not on worktree.
  @tag timeout: 60_000
  test "D13 monorepo multi-path clone+sparse keeps cone paths only on worktree" do
    path = engine_path()
    src_root =
      Path.join(
        System.tmp_dir!(),
        "mono-src-" <> Integer.to_string(System.unique_integer([:positive]))
      )
    dst_root =
      Path.join(
        System.tmp_dir!(),
        "mono-dst-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(src_root)
    File.mkdir_p!(dst_root)

    assert {:ok, src} = GitEngine.start(executable: path, root: src_root)
    assert {:ok, _} = GitEngine.run(src, %{"op" => "init"})

    assert {:ok, _} =
             GitEngine.run(src, %{
               "op" => "write",
               "args" => %{"path" => "src/in.txt", "content" => "in-cone\n"}
             })

    assert {:ok, _} =
             GitEngine.run(src, %{
               "op" => "write",
               "args" => %{"path" => "other/out.txt", "content" => "out-of-cone\n"}
             })

    assert {:ok, _} = GitEngine.run(src, %{"op" => "add", "args" => %{"path" => "src/in.txt"}})
    assert {:ok, _} = GitEngine.run(src, %{"op" => "add", "args" => %{"path" => "other/out.txt"}})

    assert {:ok, c} =
             GitEngine.run(src, %{
               "op" => "commit",
               "args" => %{
                 "message" => "monorepo multi-path",
                 "name" => "Mono",
                 "email" => "mono@test",
                 "when_unix" => 1_700_000_400
               }
             })

    assert c["ok"] == true or (is_binary(Map.get(c, "raw")) and c["raw"] =~ "\"ok\":true"),
           "D13 commit failed: #{inspect(c)}"

    assert {:ok, rev} = GitEngine.run(src, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})
    tip = (rev["stdout"] || "") |> String.trim() |> String.split(~r/\s+/) |> hd()
    assert Regex.match?(~r/^[0-9a-fA-F]{40}$/, tip), "D13 bad tip: #{inspect(rev)}"

    assert {:ok, pack} = GitEngine.pack_build(src, [tip])
    assert match?(<<"PACK", _::binary>>, pack)
    :ok = GitEngine.stop(src)

    {:ok, depth_agent} = Agent.start_link(fn -> nil end)

    transport = fn
      :list_refs, {_url, _opts} ->
        {:ok, [%{name: "refs/heads/main", hash: tip}]}

      :fetch_packs, {_url, _want, _have, opts} ->
        Agent.update(depth_agent, fn _ -> Keyword.get(opts, :depth) end)
        {:ok, pack}
    end

    assert {:ok, dst} = GitEngine.start(executable: path, root: dst_root)

    assert {:ok, json} =
             Orchestrator.run(
               dst,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               transport: transport,
               allowed_origins: [@fixture_origin],
               sparse_cone: ["src"]
             )

    assert json =~ "\"ok\":true" or json =~ ~s("ok":true), "D13 sparse clone failed: #{json}"

    # Product default depth=1 (R35 / M7).
    assert Agent.get(depth_agent, & &1) == 1

    # In-cone present; out-of-cone removed from worktree by sparse-set checkout.
    assert {:ok, "in-cone\n"} = File.read(Path.join(dst_root, "src/in.txt"))
    refute File.exists?(Path.join(dst_root, "other/out.txt")),
           "D13 out-of-cone other/out.txt must not remain on worktree"
    refute File.dir?(Path.join(dst_root, "other")),
           "D13 out-of-cone other/ dir must not remain on worktree"

    sc = Path.join(dst_root, ".git/info/sparse-checkout")
    assert File.regular?(sc), "D13 sparse-set must write sparse-checkout"
    body = File.read!(sc)
    assert body =~ "/src/"
    assert body =~ "/src/**"

    Agent.stop(depth_agent)
    :ok = GitEngine.stop(dst)
  end

  # D11: multi-chunk import_pack (chunk size < pack size) must still checkout.
  @tag timeout: 60_000
  test "multi-chunk import_pack of minimal.pack yields worktree README" do
    path = engine_path()
    root =
      Path.join(
        System.tmp_dir!(),
        "pack-multi-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    pack = read_pack!()
    tip = tip_hash!()
    # 191-byte pack with 64-byte chunks → ≥3 import_pack frames + final.
    chunk = 64
    assert byte_size(pack) > chunk

    assert {:ok, pid} = GitEngine.start(executable: path, root: root)
    assert {:ok, init} = GitEngine.run(pid, %{"op" => "init"})
    assert init["ok"] == true or (is_binary(Map.get(init, "raw")) and init["raw"] =~ "\"ok\":true")

    size = byte_size(pack)
    chunks =
      for off <- 0..(size - 1)//chunk do
        take = min(chunk, size - off)
        {binary_part(pack, off, take), off + take >= size}
      end

    assert length(chunks) >= 3

    Enum.each(chunks, fn {part, final?} ->
      assert :ok = GitEngine.import_pack(pid, part, final: final?)
    end)

    assert {:ok, refs} =
             GitEngine.run(pid, %{
               "op" => "refs.import",
               "args" => %{"name" => @ref_name, "hash" => tip}
             })

    assert refs["ok"] == true or (is_binary(Map.get(refs, "raw")) and refs["raw"] =~ "\"ok\":true")

    assert {:ok, clone} =
             GitEngine.run(pid, %{"op" => "clone.apply", "args" => %{"head" => @ref_name}})

    assert clone["ok"] == true or (is_binary(Map.get(clone, "raw")) and clone["raw"] =~ "\"ok\":true")
    assert {:ok, "hello\n"} = File.read(Path.join(root, "README"))

    :ok = GitEngine.stop(pid)
  end

  # D11: orch apply_pack streams fixture pack in small chunks (import_chunk_bytes).
  @tag timeout: 60_000
  test "BEAM orch clone multi-chunk import via import_chunk_bytes" do
    path = engine_path()
    root =
      Path.join(
        System.tmp_dir!(),
        "pack-orch-multi-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    pack = read_pack!()
    tip = tip_hash!()
    assert byte_size(pack) > 64

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
               allowed_origins: [@fixture_origin],
               import_chunk_bytes: 64
             )

    assert json =~ "\"ok\":true" or json =~ ~s("ok":true), "multi-chunk orch clone failed: #{json}"
    assert {:ok, "hello\n"} = File.read(Path.join(root, "README"))

    :ok = GitEngine.stop(pid)
  end

  # D11: file pack_source path (stream-to-temp shape) imports in chunks.
  @tag timeout: 60_000
  test "BEAM orch clone from file pack_source with multi-chunk import" do
    path = engine_path()
    root =
      Path.join(
        System.tmp_dir!(),
        "pack-file-src-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    pack = read_pack!()
    tip = tip_hash!()

    # Simulate product stream: preamble + pack on disk.
    pack_path =
      Path.join(
        System.tmp_dir!(),
        "stream-pack-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    preamble = "0008NAK\n"
    File.write!(pack_path, preamble <> pack)
    offset = byte_size(preamble)

    transport = fn
      :list_refs, {_url, _opts} ->
        {:ok, [%{name: @ref_name, hash: tip}]}

      :fetch_packs, {_url, _want, _have, _opts} ->
        {:ok, {:file, pack_path, offset}}
    end

    assert {:ok, pid} = GitEngine.start(executable: path, root: root)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               transport: transport,
               allowed_origins: [@fixture_origin],
               import_chunk_bytes: 64
             )

    assert json =~ "\"ok\":true" or json =~ ~s("ok":true), "file pack_source clone failed: #{json}"
    assert {:ok, "hello\n"} = File.read(Path.join(root, "README"))
    # Orchestrator cleanup_pack_source must remove the temp file.
    refute File.regular?(pack_path)

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

  @tag timeout: 60_000
  test "pack_build from committed tip yields non-empty PACK magic" do
    path = engine_path()
    root =
      Path.join(
        System.tmp_dir!(),
        "pack-build-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    assert {:ok, pid} = GitEngine.start(executable: path, root: root)
    assert {:ok, _} = GitEngine.run(pid, %{"op" => "init"})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "a.txt", "content" => "packme\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "a.txt"}})

    assert {:ok, c} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{
                 "message" => "m",
                 "name" => "T",
                 "email" => "t@t",
                 "when_unix" => 1_700_000_200
               }
             })

    assert c["ok"] == true or (is_binary(Map.get(c, "raw")) and c["raw"] =~ "\"ok\":true"),
           "commit failed: #{inspect(c)}"

    assert {:ok, rev} = GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})
    stdout = rev["stdout"] || ""
    tip = stdout |> String.trim() |> String.split(~r/\s+/) |> hd()
    assert Regex.match?(~r/^[0-9a-fA-F]{40}$/, tip), "bad HEAD: #{inspect(rev)}"

    assert {:ok, pack} = GitEngine.pack_build(pid, [tip])
    assert byte_size(pack) > 0
    assert match?(<<"PACK", _::binary>>, pack)

    # Empty oids fail closed.
    assert {:error, :no_oids} = GitEngine.pack_build(pid, [])

    # Export file exists under agentos path.
    assert File.regular?(Path.join(root, ".git/agentos/push.pack"))

    :ok = GitEngine.stop(pid)
  end
end
