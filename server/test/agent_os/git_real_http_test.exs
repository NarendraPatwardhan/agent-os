defmodule AgentOS.Git.RealHttpTest do
  @moduledoc """
  D27/D28 — real smart-HTTP e2e against system `git-http-backend`.

  Product path only: BEAM `AgentOS.Git.SmartHttp` + `Orchestrator` (no
  `:transport` fixture). Server infrastructure may use system git.
  """
  use ExUnit.Case, async: false

  alias AgentOS.Git.Orchestrator
  alias AgentOS.Git.SmartHttp
  alias AgentOS.GitEngine

  @moduletag :git_engine

  setup_all do
    Code.require_file(Path.expand("../support/git_http_backend.exs", __DIR__))
    :ok
  end

  setup do
    unless AgentOS.GitHttpBackend.available?() do
      flunk("D27/D28 require system git + git-http-backend on PATH/standard paths")
    end

    engine =
      System.get_env("AGENTOS_GIT_ENGINE") ||
        runfile_git_engine() ||
        flunk("AGENTOS_GIT_ENGINE not set and runfiles missing git-engine")

    {:ok, engine_path: engine}
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

  defp decode_json!(bin) do
    case AgentOS.GitEngine.Jason_like.decode(bin) do
      {:ok, map} when is_map(map) -> map
      _ -> flunk("invalid json: #{inspect(bin)}")
    end
  end

  # Explicit root is treated as durable (survives GitEngine.stop). Wipe first so
  # leftover .git from a prior mix run cannot trip "repository already open".
  defp fresh_engine_root!(prefix) when is_binary(prefix) do
    root =
      Path.join(
        System.tmp_dir!(),
        prefix <>
          "-" <>
          Integer.to_string(System.unique_integer([:positive])) <>
          "-" <>
          Integer.to_string(System.system_time(:nanosecond))
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  # ── D27: real HTTP clone/fetch ────────────────────────────────────────────

  @tag timeout: 120_000
  test "real HTTP clone via product SmartHttp + git-http-backend", %{
    engine_path: engine_path
  } do
    srv =
      AgentOS.GitHttpBackend.start!(
        content: "hello from git-http-backend clone\n",
        file: "README.md",
        branch: "main"
      )

    try do
      assert {:ok, refs} =
               SmartHttp.list_refs(srv.url, allowed_origins: [srv.origin])

      assert Enum.any?(refs, fn r ->
               r.name in ["HEAD", "refs/heads/main"] and r.hash == srv.tip
             end),
             "list-refs missing main/HEAD tip: #{inspect(refs)}"

      assert {:ok, pack_src} =
               SmartHttp.fetch_packs(srv.url, [srv.tip], [],
                 allowed_origins: [srv.origin],
                 depth: 1
               )

      assert SmartHttp.pack_byte_size(pack_src) > 0
      assert {:ok, pack_bin} = SmartHttp.read_pack_source(pack_src)
      assert binary_part(pack_bin, 0, 4) == "PACK"
      SmartHttp.cleanup_pack_source(pack_src)

      root = fresh_engine_root!("real-http-clone")
      assert {:ok, pid} = GitEngine.start(executable: engine_path, root: root)

      try do
        assert {:ok, json} =
                 Orchestrator.run(
                   pid,
                   %{
                     "op" => "clone",
                     "args" => %{"url" => srv.url}
                   },
                   allowed_origins: [srv.origin]
                 )

        resp = decode_json!(json)
        assert resp["ok"] == true or resp["ok"] == "true", "clone failed: #{json}"
        assert to_string(resp["stdout"] || "") =~ "cloned"
        readme = Path.join(root, "README.md")
        assert File.regular?(readme), "clone did not materialize README.md under #{root}"
        assert File.read!(readme) =~ "hello from git-http-backend clone"

        assert {:ok, json_f} =
                 Orchestrator.run(
                   pid,
                   %{"op" => "fetch", "args" => %{"url" => srv.url}},
                   allowed_origins: [srv.origin]
                 )

        resp_f = decode_json!(json_f)
        assert resp_f["ok"] == true or resp_f["ok"] == "true", "fetch failed: #{json_f}"
        assert to_string(resp_f["stdout"] || "") =~ "fetched"
      after
        GitEngine.stop(pid)
        File.rm_rf(root)
      end
    after
      srv.stop.()
    end
  end

  # ── D28: real HTTP push ───────────────────────────────────────────────────

  @tag timeout: 120_000
  test "real HTTP push via product receive-pack + git-http-backend", %{
    engine_path: engine_path
  } do
    srv =
      AgentOS.GitHttpBackend.start!(
        content: "seed for push\n",
        file: "SEED.md",
        branch: "main"
      )

    try do
      root = fresh_engine_root!("real-http-push")
      assert {:ok, pid} = GitEngine.start(executable: engine_path, root: root)

      try do
        assert {:ok, json_c} =
                 Orchestrator.run(
                   pid,
                   %{"op" => "clone", "args" => %{"url" => srv.url}},
                   allowed_origins: [srv.origin]
                 )

        resp_c = decode_json!(json_c)
        assert resp_c["ok"] == true or resp_c["ok"] == "true", "pre-push clone: #{json_c}"

        assert {:ok, _} =
                 GitEngine.run(pid, %{
                   "op" => "write",
                   "args" => %{"path" => "pushed.txt", "content" => "from product push\n"}
                 })

        assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "pushed.txt"}})

        assert {:ok, _} =
                 GitEngine.run(pid, %{
                   "op" => "commit",
                   "args" => %{
                     "message" => "product push",
                     "name" => "Pusher",
                     "email" => "push@agent-os.test",
                     "when_unix" => 1_700_000_300
                   }
                 })

        tip_before = AgentOS.GitHttpBackend.rev_parse_ref(srv.bare, "refs/heads/main")

        assert {:ok, json_p} =
                 Orchestrator.run(
                   pid,
                   %{"op" => "push", "args" => %{"url" => srv.url}},
                   allowed_origins: [srv.origin]
                 )

        resp_p = decode_json!(json_p)
        assert resp_p["ok"] == true or resp_p["ok"] == "true", "push failed: #{json_p}"
        assert to_string(resp_p["stdout"] || "") =~ "pushed"

        tip_after = AgentOS.GitHttpBackend.rev_parse_ref(srv.bare, "refs/heads/main")
        assert tip_after != tip_before, "bare ref did not advance after push"
        assert tip_after != srv.tip

        root2 = fresh_engine_root!("real-http-push-verify")
        assert {:ok, pid2} = GitEngine.start(executable: engine_path, root: root2)

        try do
          assert {:ok, json2} =
                   Orchestrator.run(
                     pid2,
                     %{"op" => "clone", "args" => %{"url" => srv.url}},
                     allowed_origins: [srv.origin]
                   )

          resp2 = decode_json!(json2)
          assert resp2["ok"] == true or resp2["ok"] == "true", "verify clone: #{json2}"
          assert File.regular?(Path.join(root2, "pushed.txt"))
          assert File.read!(Path.join(root2, "pushed.txt")) =~ "from product push"
        after
          GitEngine.stop(pid2)
          File.rm_rf(root2)
        end
      after
        GitEngine.stop(pid)
        File.rm_rf(root)
      end
    after
      srv.stop.()
    end
  end

  @tag timeout: 60_000
  test "product SmartHttp.push_packs create branch on real receive-pack" do
    srv = AgentOS.GitHttpBackend.start!(branch: "main")

    try do
      zeros = String.duplicate("0", 40)
      pack = AgentOS.GitHttpBackend.pack_objects(srv.bare, [srv.tip])
      assert binary_part(pack, 0, 4) == "PACK"

      cmds = [
        %{old_hash: zeros, new_hash: srv.tip, name: "refs/heads/from-product"}
      ]

      assert {:ok, status} =
               SmartHttp.push_packs(srv.url, cmds, pack, allowed_origins: [srv.origin])

      assert status.ok == true, "receive-pack status: #{inspect(status)}"

      created = AgentOS.GitHttpBackend.rev_parse_ref(srv.bare, "refs/heads/from-product")
      assert created == srv.tip
    after
      srv.stop.()
    end
  end
end
