defmodule AgentOS.GitGuestAcceptanceTest do
  @moduledoc """
  Server-side guest git acceptance: CAP_NET remotes, deny path, Port kill-closed, gitfs ctl.

  Boots loom + kernel via attach_git; fixture smart-HTTP only (no external network).
  """
  use ExUnit.Case, async: false

  alias AgentOS.ControlPlane
  alias AgentOS.GitEngine

  @moduletag :git_engine
  @moduletag timeout: 180_000

  @fixture_url "https://example.com/demo.git"
  @fixture_origin "https://example.com"

  # CAP_NET clone path

  test "guest CAP_NET + /bin/git clone via attach_git fixture" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    loom = runfile_bytes("memcontainers/images/loom.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(loom) do
      flunk("requires kernel.wasm + loom.tar under bazel //server:mix_test runfiles")
    end

    id = unique_id("capnet-clone")
    pack = fixture_git_bytes!("minimal.pack")
    tip = fixture_git_bytes!("minimal.tip") |> String.trim()
    root = tmp_root("capnet")
    dials = :atomics.new(1, signed: false)

    transport = fn
      :list_refs, _ ->
        :atomics.add(dials, 1, 1)
        {:ok, [%{name: "refs/heads/main", hash: tip}]}

      :fetch_packs, _ ->
        :atomics.add(dials, 1, 1)
        {:ok, pack}
    end

    try do
      assert {:ok, _pid} =
               ControlPlane.create(id,
                 wasm: wasm,
                 base_image: loom,
                 deterministic: true,
                 workers: 0,
                 host_call: :relay
               )

      assert :ok =
               ControlPlane.attach_git(id,
                 executable: path,
                 root: root,
                 allowed_origins: [@fixture_origin],
                 transport: transport,
                 identity: %{name: "guest", email: "guest@example.com"}
               )

      # Full-tier guest: direct argv so CAP_NET host_call is exercised (not shell SPAWN only).
      assert {:ok, result} =
               ControlPlane.run(id, "git", ["clone", @fixture_url], timeout: 120_000)

      out = "#{result.stdout}\n#{result.stderr}"
      assert result.exit_code == 0, "git clone failed: #{inspect(result)}"
      assert out =~ "cloned" or out =~ "ok" or out =~ "\"ok\":true" or result.exit_code == 0

      assert :atomics.get(dials, 1) >= 2,
             "fixture transport must dial list-refs + fetch-packs (got #{:atomics.get(dials, 1)})"

      assert_eventually(fn ->
        case File.read(Path.join(root, "README")) do
          {:ok, "hello\n"} -> true
          _ -> false
        end
      end)

      assert {:ok, "hello\n"} = File.read(Path.join(root, "README"))
    after
      ControlPlane.dispose(id)
      File.rm_rf(root)
    end
  end

  # CAP_NET deny

  test "guest without CAP_NET: git clone fails closed and never dials" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    loom = runfile_bytes("memcontainers/images/loom.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(loom) do
      flunk("requires kernel.wasm + loom.tar under bazel //server:mix_test runfiles")
    end

    id = unique_id("capnet-deny")
    pack = fixture_git_bytes!("minimal.pack")
    tip = fixture_git_bytes!("minimal.tip") |> String.trim()
    root = tmp_root("capnet-deny")
    dials = :atomics.new(1, signed: false)

    transport = fn
      :list_refs, _ ->
        :atomics.add(dials, 1, 1)
        {:ok, [%{name: "refs/heads/main", hash: tip}]}

      :fetch_packs, _ ->
        :atomics.add(dials, 1, 1)
        {:ok, pack}
    end

    # tier_read_write = 2 → caps without CAP_NET / CAP_SPAWN (constants.ex tier_caps).
    contract = {AgentOS.Contracts.Constants.tier_read_write(), 256, 0}

    try do
      assert {:ok, _pid} =
               ControlPlane.create(id,
                 wasm: wasm,
                 base_image: loom,
                 deterministic: true,
                 workers: 0,
                 host_call: :relay,
                 contract: contract
               )

      assert :ok =
               ControlPlane.attach_git(id,
                 executable: path,
                 root: root,
                 allowed_origins: [@fixture_origin],
                 transport: transport
               )

      # Direct argv inherits boot-tier caps (no CAP_NET) — same as JS git_guest_e2e R3.
      assert {:ok, denied} =
               ControlPlane.run(id, "git", ["clone", @fixture_url], timeout: 60_000)

      msg = "#{denied.stderr}\n#{denied.stdout}"
      deny_marker =
        msg =~ "CAP_NET" or msg =~ "host_call" or msg =~ "EPERM" or msg =~ "Permission"

      assert deny_marker,
             "expected CAP_NET/host_call/EPERM marker, got: #{inspect(denied)}"

      assert denied.exit_code != 0 or msg =~ "host_call git failed",
             "git clone without CAP_NET must fail: #{inspect(denied)}"

      assert :atomics.get(dials, 1) == 0,
             "must not reach fixture transport (dials=#{:atomics.get(dials, 1)})"
    after
      ControlPlane.dispose(id)
      File.rm_rf(root)
    end
  end

  # ──: Port kill → guest-visible EIO ─────────────────────────────────────

  test "Port kill → next guest git op fails closed (EIO)" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    loom = runfile_bytes("memcontainers/images/loom.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(loom) do
      flunk("D29 requires kernel.wasm + loom.tar under bazel //server:mix_test runfiles")
    end

    id = unique_id("git-eio")
    root = tmp_root("git")

    try do
      assert {:ok, _pid} =
               ControlPlane.create(id,
                 wasm: wasm,
                 base_image: loom,
                 deterministic: true,
                 workers: 0,
                 host_call: :relay
               )

      assert :ok =
               ControlPlane.attach_git(id,
                 executable: path,
                 root: root,
                 identity: %{name: "D29", email: "d29@example.com"}
               )

      # Guest local porcelain works before kill (proves mount + Port live).
      # Control-channel cwd cannot target a host mount path (WouldBlock on mount
      # stat); shell `cd` runs under the tick pump that drains type-4 ops.
      assert {:ok, init} =
               ControlPlane.exec(id, "cd /workspace/repo && git init", timeout: 60_000)

      assert init.exit_code == 0, "pre-kill git init: #{inspect(init)}"

      # Kill the OS Port under the engine GenServer (not Process.exit of engine).
      vm = ControlPlane.whereis(id)
      st = :sys.get_state(vm)
      engines = st.git_engines || %{}
      assert map_size(engines) >= 1
      [{_mount, %{pid: eng}} | _] = Map.to_list(engines)
      eng_state = :sys.get_state(eng)
      port = Map.fetch!(eng_state, :port)
      assert is_port(port)
      true = Port.close(port)
      Process.sleep(50)
      _ = GitEngine.alive?(eng)

      # Next guest op must fail closed — host_call "git" or ctl via /bin/git.
      assert {:ok, after_kill} =
               ControlPlane.exec(id, "cd /workspace/repo && git status", timeout: 60_000)

      msg = "#{after_kill.stderr}\n#{after_kill.stdout}"
      failed? =
        after_kill.exit_code != 0 or
          msg =~ "EIO" or
          msg =~ "eio" or
          msg =~ "host_call" or
          msg =~ "failed" or
          msg =~ "I/O"

      assert failed?,
             "D29 expected guest-visible failure after Port kill, got: #{inspect(after_kill)}"

      # Engine Run path also reports :eio (unit surface still holds).
      result =
        try do
          GitEngine.run(eng, %{"op" => "status"})
        catch
          :exit, _ -> {:error, :eio}
        end

      assert match?({:error, :eio}, result) or match?({:error, _}, result)
    after
      ControlPlane.dispose(id)
      File.rm_rf(root)
    end
  end

  # ──: gitfs mount + ctl on booted guest ─────────────────────────────────

  test "booted guest gitfs mount + ctl via /bin/git (type-4)" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    loom = runfile_bytes("memcontainers/images/loom.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(loom) do
      flunk("D30 requires kernel.wasm + loom.tar under bazel //server:mix_test runfiles")
    end

    id = unique_id("git-gitfs")
    root = tmp_root("git")

    try do
      assert {:ok, _pid} =
               ControlPlane.create(id,
                 wasm: wasm,
                 base_image: loom,
                 deterministic: true,
                 workers: 0,
                 host_call: :relay
               )

      assert :ok =
               ControlPlane.attach_git(id,
                 executable: path,
                 root: root,
                 identity: %{name: "D30", email: "d30@example.com"}
               )

      assert {:ok, ver} = ControlPlane.run(id, "git", ["version"], timeout: 30_000)
      assert ver.exit_code == 0, "git version: #{inspect(ver)}"
      assert ver.stdout =~ "agentos-git" or ver.stdout =~ "git"

      # Guest ctl round-trips (type-4 mount host_calls answered on tick).
      # Shell `cd` (not control cwd) — mount paths WouldBlock on ctl cwd.
      assert {:ok, init} =
               ControlPlane.exec(id, "cd /workspace/repo && git init", timeout: 60_000)

      assert init.exit_code == 0, "git init (ctl/type-4): #{inspect(init)}"

      assert {:ok, status0} =
               ControlPlane.exec(id, "cd /workspace/repo && git status", timeout: 60_000)

      assert status0.exit_code == 0, "git status after init: #{inspect(status0)}"

      # Worktree on engine root + guest add (ctl). Commit needs name/email —
      # host identity inject is type-1 Run (K28); guest thin CLI omits them on
      # type-4, so commit is exercised host-side after guest add.
      assert :ok = File.write(Path.join(root, "hello-d30.txt"), "hello-d30\n")

      assert {:ok, add} =
               ControlPlane.exec(id, "cd /workspace/repo && git add hello-d30.txt",
                 timeout: 60_000
               )

      assert add.exit_code == 0, "git add: #{inspect(add)}"

      vm = ControlPlane.whereis(id)
      st = :sys.get_state(vm)
      [{mount, %{pid: eng}} | _] = Map.to_list(st.git_engines || %{})
      assert is_binary(mount)

      assert {:ok, commit} =
               GitEngine.run(eng, %{
                 "op" => "commit",
                 "args" => %{
                   "message" => "d30-e2e",
                   "name" => "D30",
                   "email" => "d30@example.com"
                 }
               })

      raw_c = Map.get(commit, "raw") || inspect(commit)
      assert commit["ok"] == true or to_string(raw_c) =~ "\"ok\":true",
             "host commit after guest add: #{inspect(commit)}"

      assert {:ok, status} =
               ControlPlane.exec(id, "cd /workspace/repo && git status", timeout: 60_000)

      assert status.exit_code == 0, "git status after commit: #{inspect(status)}"

      # Remotes via ctl must refuse (host_call only) — exercise type-4 ctl write.
      body = mount_write_body(".git/mc/ctl", ~s({"op":"fetch"}))
      assert {:ok, _wr} = GitEngine.mount_op(eng, body)
      assert {:ok, open_resp} = GitEngine.mount_op(eng, mount_open_body(".git/mc/ctl"))
      <<_st::little-signed-32, payload::binary>> = open_resp
      assert payload =~ "host_call" or payload =~ "remote",
             "ctl fetch must refuse remotes: #{payload}"
    after
      ControlPlane.dispose(id)
      File.rm_rf(root)
    end
  end

  # ──: client_token + generation race acceptance ─────────────────────────

  test "client_token echoed and generation advances (gitfs mount_op)" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    try do
      assert {:ok, _} = GitEngine.run(pid, %{"op" => "init"})

      # Baseline generation (decimal text).
      gen0 = read_generation!(pid)
      assert is_integer(gen0)

      token_a = "tok-d31-a-#{System.unique_integer([:positive])}"
      req_a =
        ~s({"op":"status","args":{"short":true,"client_token":"#{token_a}"}})

      assert {:ok, _} = GitEngine.mount_op(pid, mount_write_body(".git/mc/ctl", req_a))
      assert {:ok, open_a} = GitEngine.mount_op(pid, mount_open_body(".git/mc/ctl"))
      <<st_a::little-signed-32, payload_a::binary>> = open_a
      assert st_a == 0
      assert payload_a =~ token_a, "Response must echo client_token: #{payload_a}"
      assert payload_a =~ "client_token"
      # Prefer structured result.client_token when JSON decodes.
      case AgentOS.GitEngine.Jason_like.decode(payload_a) do
        {:ok, map} when is_map(map) ->
          result = Map.get(map, "result") || %{}
          assert Map.get(result, "client_token") == token_a or payload_a =~ token_a

        _ ->
          assert payload_a =~ token_a
      end

      gen1 = read_generation!(pid)
      assert gen1 == gen0 + 1, "generation must advance by 1 after ctl write (#{gen0}→#{gen1})"

      token_b = "tok-d31-b-#{System.unique_integer([:positive])}"
      req_b =
        ~s({"op":"status","args":{"client_token":"#{token_b}"}})

      assert {:ok, _} = GitEngine.mount_op(pid, mount_write_body(".git/mc/ctl", req_b))
      assert {:ok, open_b} = GitEngine.mount_op(pid, mount_open_body(".git/mc/ctl"))
      <<_st_b::little-signed-32, payload_b::binary>> = open_b
      assert payload_b =~ token_b
      refute payload_b =~ token_a, "stale token must not win: #{payload_b}"

      gen2 = read_generation!(pid)
      assert gen2 == gen1 + 1

      # Type-1 Run also echoes client_token (same ge_run_json path).
      assert {:ok, run_resp} =
               GitEngine.run(pid, %{
                 "op" => "status",
                 "args" => %{"client_token" => "run-token-d31"}
               })

      raw = Map.get(run_resp, "raw") || inspect(run_resp)
      assert to_string(raw) =~ "run-token-d31" or
               get_in(run_resp, ["result", "client_token"]) == "run-token-d31"
    after
      _ = GitEngine.stop(pid)
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp engine_path do
    env = System.get_env("AGENTOS_GIT_ENGINE")

    cond do
      is_binary(env) and env != "" and File.regular?(env) ->
        env

      true ->
        runfile_git_engine() || flunk("AGENTOS_GIT_ENGINE not set / not found")
    end
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

  defp runfile_bytes(rel) do
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

  defp fixture_git_bytes!(name) when is_binary(name) do
    candidates = [
      Path.expand("../fixtures/git/#{name}", __DIR__),
      Path.expand("test/fixtures/git/#{name}", File.cwd!()),
      System.get_env("TEST_SRCDIR") &&
        System.get_env("TEST_WORKSPACE") &&
        Path.join([
          System.get_env("TEST_SRCDIR"),
          System.get_env("TEST_WORKSPACE"),
          "server/test/fixtures/git",
          name
        ]),
      System.get_env("RUNFILES_DIR") &&
        Path.join([System.get_env("RUNFILES_DIR"), "_main/server/test/fixtures/git", name])
    ]

    case Enum.find(candidates, &(is_binary(&1) and File.regular?(&1))) do
      nil -> flunk("fixture git/#{name} not found")
      path -> File.read!(path)
    end
  end

  defp unique_id(prefix),
    do: {"git-accept", "#{prefix}-#{System.unique_integer([:positive])}"}

  defp tmp_root(tag) do
    root =
      Path.join(
        System.tmp_dir!(),
        "agentos-#{tag}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    root
  end

  defp assert_eventually(fun, attempts \\ 80) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(50)
        assert_eventually(fun, attempts - 1)
    end
  end

  defp mount_write_body(path, data) do
    op = 6
    path_bin = path
    data_bin = data

    <<op::little-32, byte_size(path_bin)::little-32, path_bin::binary, 0::little-32,
      data_bin::binary>>
  end

  defp mount_open_body(path) do
    path_bin = path
    <<0::little-32, byte_size(path_bin)::little-32, path_bin::binary, 0::little-32>>
  end

  defp read_generation!(pid) do
    assert {:ok, open} = GitEngine.mount_op(pid, mount_open_body(".git/mc/generation"))
    <<st::little-signed-32, payload::binary>> = open
    assert st == 0, "generation open failed status=#{st}"
    text = payload |> to_string() |> String.trim()
    {n, _} = Integer.parse(text)
    n
  end

end
