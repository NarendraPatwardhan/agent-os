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

  @tag timeout: 60_000
  test "Port Run init→commit and fails closed after stop" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start_link(executable: path)

    assert {:ok, resp} = GitEngine.run(pid, %{"op" => "init"})
    assert resp["ok"] == true or resp["ok"] == true or Map.get(resp, "raw", "") =~ "\"ok\":true"

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

    # Type-4 mount: write ctl status
    body = mount_write_body(".git/mc/ctl", ~s({"op":"status"}))
    assert {:ok, mount_resp} = GitEngine.mount_op(pid, body)
    assert is_binary(mount_resp)
    assert byte_size(mount_resp) >= 4

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
  test "R27/R29 identity inject on commit when start opts set" do
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

    # No name/email in args — host identity inject must fill them (K28).
    assert {:ok, resp} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{"message" => "injected", "when_unix" => 1_700_000_050}
             })

    assert resp["ok"] == true or Map.get(resp, "raw", "") =~ "\"ok\":true"

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

    raw = Map.get(bad, "raw") || inspect(bad)
    stderr = Map.get(bad, "stderr") || ""
    assert bad["ok"] == false or raw =~ "\"ok\":false"
    assert stderr =~ "name and email" or raw =~ "name and email"
    refute raw =~ "agent@example.com"
    refute raw =~ "Agent@example.com"
    :ok = GitEngine.stop(pid2)
  end

  @tag timeout: 60_000
  test "R34 reset ff-only fails on divergent history" do
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
    head1 = h1["stdout"] || Map.get(h1, "raw", "")
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

    raw = Map.get(ff, "raw") || inspect(ff)
    stderr = Map.get(ff, "stderr") || ""
    assert ff["ok"] == false or raw =~ "\"ok\":false"
    assert stderr =~ "not fast-forward" or raw =~ "not fast-forward"
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
    root = Path.join(System.tmp_dir!(), "agentos-git-keep-" <> Integer.to_string(System.unique_integer([:positive])))
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

  defp mount_write_body(path, data) do
    op = 6
    path_bin = path
    data_bin = data
    <<op::little-32, byte_size(path_bin)::little-32, path_bin::binary, 0::little-32,
      data_bin::binary>>
  end
end
