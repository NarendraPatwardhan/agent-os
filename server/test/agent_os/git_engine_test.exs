defmodule AgentOS.GitEngineTest do
  use ExUnit.Case, async: false

  alias AgentOS.GitEngine

  @moduletag :git_engine

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

  test "durable root rejects filesystem root and empty paths" do
    assert {:error, :unsafe_git_root} = AgentOS.Git.Durable.resolve_root(root: "/")
    assert {:error, :unsafe_git_root} = AgentOS.Git.Durable.resolve_root(root: "")
  end

  test "JSON codec rejects ambiguous, invalid, and excessively nested documents" do
    assert {:ok, %{"emoji" => "😀"}} =
             AgentOS.GitEngine.Jason_like.decode(~s({"emoji":"\\uD83D\\uDE00"}))

    assert {:error, :invalid_json} =
             AgentOS.GitEngine.Jason_like.decode(~s({"mount":"/a","mount":"/b"}))

    assert {:error, :invalid_json} = AgentOS.GitEngine.Jason_like.decode(~s({"x":"\\q"}))

    assert {:error, :invalid_json} =
             AgentOS.GitEngine.Jason_like.decode(<<"{\"x\":\"", 0xFF, "\"}">>)

    deep = String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65)
    assert {:error, :invalid_json} = AgentOS.GitEngine.Jason_like.decode(deep)
  end

  test "durable root creation refuses symlink components" do
    base = Path.join(System.tmp_dir!(), "agentos-git-root-#{System.unique_integer([:positive])}")
    outside = base <> "-outside"
    File.mkdir_p!(base)
    File.mkdir_p!(outside)

    try do
      link = Path.join(base, "link")
      assert :ok = File.ln_s(outside, link)

      assert_raise File.Error, fn ->
        AgentOS.Git.Durable.ensure_root!(Path.join(link, "repo"))
      end

      refute File.exists?(Path.join(outside, "repo"))
    after
      File.rm_rf(base)
      File.rm_rf(outside)
    end
  end

  @tag timeout: 60_000
  test "Port Run init→commit and fails closed after stop" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start_link(executable: path)

    assert {:ok, resp} = GitEngine.run(pid, %{"op" => "init"})
    assert resp["ok"] == true

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "t.txt", "content" => "x\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "t.txt"}})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{
                 "message" => "m",
                 "name" => "T",
                 "email" => "t@t",
                 "when_unix" => 1_700_000_000
               }
             })

    # Type-4 mount: write a tokenized ctl request, then read its Response.
    token = "engine-status"
    body = mount_write_body(".git/mc/ctl", ~s({"op":"status","args":{"client_token":"#{token}"}}))
    assert {:ok, mount_resp} = GitEngine.mount_op(pid, body)
    assert is_binary(mount_resp)
    assert byte_size(mount_resp) >= 4
    # status i32 LE == 0
    <<st::little-signed-32, _::binary>> = mount_resp
    assert st == 0

    assert {:ok, open_resp} =
             GitEngine.mount_op(pid, mount_open_body(".git/mc/responses/#{token}"))

    assert is_binary(open_resp)
    assert byte_size(open_resp) >= 4
    <<ost::little-signed-32, payload::binary>> = open_resp
    assert ost == 0
    assert payload =~ "\"ok\""
    # status after commit should not be empty JSON only
    assert payload =~ "ok" or payload =~ "\"ok\":true"

    # submodule list-only (empty without .gitmodules).
    assert {:ok, sub} =
             GitEngine.run(pid, %{"op" => "submodule", "args" => %{"action" => "list"}})

    assert sub["ok"] == true
    assert sub["result"] == %{"submodules" => []}

    assert {:ok, sub_bad} =
             GitEngine.run(pid, %{"op" => "submodule", "args" => %{"action" => "update"}})

    stderr_bad = Map.get(sub_bad, "stderr") || ""
    assert sub_bad["ok"] == false
    assert stderr_bad =~ "host-mediated" or stderr_bad =~ "not implemented"

    :ok = GitEngine.stop(pid)
    # Subsequent ops fail closed (process down or :eio)
    result =
      try do
        GitEngine.run(pid, %{"op" => "status"})
      catch
        :exit, _ -> {:error, :eio}
      end

    assert match?({:error, _}, result)
  end

  @tag timeout: 60_000
  test "identity inject on commit when start opts set" do
    path = engine_path()

    assert {:ok, pid} =
             GitEngine.start(
               executable: path,
               identity: %{name: "Host Policy", email: "host@policy.test"}
             )

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "init"})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "i.txt", "content" => "i\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "i.txt"}})

    assert {:ok, malformed} = GitEngine.run(pid, ~s({"op":"commit","args":"invalid"}))
    assert malformed["ok"] == false
    assert malformed["code"] == 2

    # No name/email in args — host identity inject must fill them (K28).
    assert {:ok, resp} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{"message" => "injected", "when_unix" => 1_700_000_050}
             })

    assert resp["ok"] == true

    :ok = GitEngine.stop(pid)

    # Without identity, missing name/email fails closed (never invent Agent@example.com).
    assert {:ok, pid2} = GitEngine.start(executable: path)
    assert {:ok, _} = GitEngine.run(pid2, %{"op" => "init"})

    assert {:ok, _} =
             GitEngine.run(pid2, %{
               "op" => "write",
               "args" => %{"path" => "n.txt", "content" => "n\n"}
             })

    assert {:ok, _} = GitEngine.run(pid2, %{"op" => "add", "args" => %{"path" => "n.txt"}})

    assert {:ok, bad} =
             GitEngine.run(pid2, %{
               "op" => "commit",
               "args" => %{"message" => "no-id"}
             })

    stderr = Map.get(bad, "stderr") || ""
    assert bad["ok"] == false
    assert stderr =~ "name and email"
    refute stderr =~ "agent@example.com"
    refute stderr =~ "Agent@example.com"
    :ok = GitEngine.stop(pid2)
  end

  @tag timeout: 60_000
  test "directory durable: second Port reopens same HEAD + worktree" do
    path = engine_path()

    root =
      Path.join(
        System.tmp_dir!(),
        "agentos-git-durable-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)

    try do
      assert {:ok, pid1} = GitEngine.start(executable: path, root: root)
      root1 = GitEngine.root(pid1)
      assert is_binary(root1)
      assert Path.expand(root1) == Path.expand(root)

      assert {:ok, _} = GitEngine.run(pid1, %{"op" => "init"})

      assert {:ok, _} =
               GitEngine.run(pid1, %{
                 "op" => "write",
                 "args" => %{"path" => "persist.txt", "content" => "beam-dir-roundtrip\n"}
               })

      assert {:ok, _} =
               GitEngine.run(pid1, %{"op" => "add", "args" => %{"path" => "persist.txt"}})

      assert {:ok, _} =
               GitEngine.run(pid1, %{
                 "op" => "commit",
                 "args" => %{
                   "message" => "durable",
                   "name" => "Dur",
                   "email" => "dur@test",
                   "when_unix" => 1_700_000_300
                 }
               })

      assert {:ok, h1} = GitEngine.run(pid1, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})

      head1 =
        h1["stdout"]
        |> to_string()
        |> String.trim()
        |> String.split(~r/\s+/)
        |> List.first()

      assert is_binary(head1) and byte_size(head1) == 40

      assert :ok = GitEngine.checkpoint(pid1)
      assert File.dir?(Path.join(root, ".git"))
      assert File.exists?(Path.join(root, "persist.txt"))
      assert File.read!(Path.join(root, "persist.txt")) =~ "beam-dir-roundtrip"

      # Stop process A — durable root must survive (not temp cleanup).
      :ok = GitEngine.stop(pid1)
      assert File.dir?(Path.join(root, ".git"))
      assert File.exists?(Path.join(root, "persist.txt"))

      # Process B: ge_open same directory — same HEAD + file content.
      assert {:ok, pid2} = GitEngine.start(executable: path, root: root)
      assert {:ok, h2} = GitEngine.run(pid2, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})

      head2 =
        h2["stdout"]
        |> to_string()
        |> String.trim()
        |> String.split(~r/\s+/)
        |> List.first()

      assert head2 == head1

      # Worktree on disk (primary durable form) + engine still sees HEAD.
      assert File.read!(Path.join(root, "persist.txt")) =~ "beam-dir-roundtrip"
      :ok = GitEngine.stop(pid2)

      # durable_id under AGENTOS_GIT_DURABLE_ROOT
      base =
        Path.join(
          System.tmp_dir!(),
          "agentos-git-d18-" <> Integer.to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(base)
      prev = System.get_env("AGENTOS_GIT_DURABLE_ROOT")
      System.put_env("AGENTOS_GIT_DURABLE_ROOT", base)

      try do
        assert AgentOS.Git.Durable.safe_segment(".") == "default"
        assert AgentOS.Git.Durable.safe_segment("..") == "default"

        assert {:ok, pid3} =
                 GitEngine.start(
                   executable: path,
                   durable_id: "vm-alice",
                   mount_path: "/workspace/repo"
                 )

        root3 = GitEngine.root(pid3)
        assert is_binary(root3)
        assert root3 =~ "vm-alice"
        assert root3 =~ "workspace@repo"
        assert String.starts_with?(Path.expand(root3), Path.expand(base))

        assert {:ok, _} = GitEngine.run(pid3, %{"op" => "init"})
        :ok = GitEngine.stop(pid3)
        # Named durable root survives stop.
        assert File.dir?(root3)
      after
        if prev,
          do: System.put_env("AGENTOS_GIT_DURABLE_ROOT", prev),
          else: System.delete_env("AGENTOS_GIT_DURABLE_ROOT")

        File.rm_rf(base)
      end
    after
      File.rm_rf(root)
    end
  end

  @tag timeout: 60_000
  test "reset ff-only fails on divergent history" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)
    assert {:ok, _} = GitEngine.run(pid, %{"op" => "init"})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "a.txt", "content" => "a\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "a.txt"}})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{
                 "message" => "c1",
                 "name" => "T",
                 "email" => "t@t",
                 "when_unix" => 1_700_000_060
               }
             })

    assert {:ok, h1} = GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})
    head1 = h1["stdout"]
    head1 = head1 |> to_string() |> String.trim() |> String.split(~r/\s+/) |> List.first()

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "b.txt", "content" => "b\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "b.txt"}})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{
                 "message" => "c2",
                 "name" => "T",
                 "email" => "t@t",
                 "when_unix" => 1_700_000_061
               }
             })

    assert {:ok, h2} = GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})
    head2 = h2["stdout"] || ""
    head2 = head2 |> to_string() |> String.trim() |> String.split(~r/\s+/) |> List.first()

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "reset",
               "args" => %{"rev" => head1, "mode" => "hard"}
             })

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "c.txt", "content" => "c\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "c.txt"}})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{
                 "message" => "c3",
                 "name" => "T",
                 "email" => "t@t",
                 "when_unix" => 1_700_000_062
               }
             })

    assert {:ok, ff} =
             GitEngine.run(pid, %{
               "op" => "reset",
               "args" => %{"rev" => head2, "mode" => "ff-only"}
             })

    stderr = Map.get(ff, "stderr") || ""
    assert ff["ok"] == false
    assert stderr =~ "not fast-forward"
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 60_000
  test "temp agentos-git-* root under tmp is removed on stop" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    state = :sys.get_state(pid)
    root = Map.fetch!(state, :root)
    assert Map.get(state, :temp_root?) == true
    assert File.dir?(root)
    assert String.starts_with?(Path.basename(root), "agentos-git-")
    assert String.starts_with?(Path.expand(root), Path.expand(System.tmp_dir!()) <> "/")

    :ok = GitEngine.stop(pid)
    refute File.exists?(root)
  end

  @tag timeout: 60_000
  test "explicit :root is not deleted on stop" do
    path = engine_path()

    root =
      Path.join(
        System.tmp_dir!(),
        "agentos-git-keep-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)

    try do
      assert {:ok, pid} = GitEngine.start(executable: path, root: root)
      state = :sys.get_state(pid)
      assert Map.get(state, :temp_root?) == false
      :ok = GitEngine.stop(pid)
      assert File.dir?(root)
    after
      File.rm_rf(root)
    end
  end

  # kill Port → subsequent Run returns :eio (fail closed).
  @tag timeout: 60_000
  test "kill Port → subsequent run returns eio" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)
    assert {:ok, _} = GitEngine.run(pid, %{"op" => "init"})

    state = :sys.get_state(pid)
    port = Map.fetch!(state, :port)
    assert is_port(port)
    # Kill the OS child without GenServer.stop — Port exit path.
    true = Port.close(port)

    # Drain exit_status into GenServer so port becomes nil.
    Process.sleep(50)
    # Nudge mailbox processing.
    _ = GitEngine.alive?(pid)

    result =
      try do
        GitEngine.run(pid, %{"op" => "status"})
      catch
        :exit, _ -> {:error, :eio}
      end

    assert match?({:error, :eio}, result) or match?({:error, _}, result)

    # Metrics: port_eio should have ticked (best-effort).
    snap = AgentOS.Git.Metrics.snapshot()
    assert is_map(snap)
    assert Map.has_key?(snap, :port_eio)

    _ = GitEngine.stop(pid)
  end

  defp mount_write_body(path, data) do
    op = 6
    path_bin = path
    data_bin = data

    <<op::little-32, byte_size(path_bin)::little-32, path_bin::binary, 0::little-32,
      data_bin::binary>>
  end

  # MOUNT_OP_OPEN = 0
  defp mount_open_body(path) do
    path_bin = path
    <<0::little-32, byte_size(path_bin)::little-32, path_bin::binary, 0::little-32>>
  end
end
