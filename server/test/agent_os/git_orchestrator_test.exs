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
  # Agent records last push for assertions (R44–R46).
  defp fixture_transport(pack \\ <<>>, push_agent \\ nil) do
    refs = [%{name: "refs/heads/main", hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]

    fn
      :list_refs, {_url, _opts} ->
        {:ok, refs}

      :fetch_packs, {_url, _want, _have, _opts} ->
        {:ok, pack}

      :push_packs, {url, commands, pack_bin, _opts} ->
        if is_pid(push_agent) do
          Agent.update(push_agent, fn _ ->
            %{url: url, commands: commands, pack: pack_bin, pack_len: byte_size(pack_bin)}
          end)
        end

        {:ok, %{ok: true, message: "ok"}}
    end
  end

  defp orch_opts(pack \\ <<>>, push_agent \\ nil) do
    [
      transport: fixture_transport(pack, push_agent),
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

  # ── R34 pull = fetch + local FF ────────────────────────────────────────────

  @tag timeout: 60_000
  test "pull after successful clone of minimal.pack is already up to date" do
    path = engine_path()
    pack_path = Path.expand("../fixtures/git/minimal.pack", __DIR__)
    tip_path = Path.expand("../fixtures/git/minimal.tip", __DIR__)

    if not (File.regular?(pack_path) and File.regular?(tip_path)) do
      IO.puts(:stderr, "skipping pull FF test: minimal.pack fixture missing")
    else
      pack = File.read!(pack_path)
      tip = File.read!(tip_path) |> String.trim()
      root = Path.join(System.tmp_dir!(), "orch-pull-" <> Integer.to_string(System.unique_integer([:positive])))
      File.mkdir_p!(root)

      try do
        assert {:ok, pid} = GitEngine.start(executable: path, root: root)

        refs = [%{name: "refs/heads/main", hash: tip}]

        transport = fn
          :list_refs, {_url, _opts} -> {:ok, refs}
          :fetch_packs, {_url, _want, _have, _opts} -> {:ok, pack}
        end

        opts = [transport: transport, allowed_origins: [@fixture_origin]]

        assert {:ok, clone_json} =
                 Orchestrator.run(
                   pid,
                   ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
                   opts
                 )

        assert clone_json =~ "\"ok\":true" or clone_json =~ ~s("ok":true)
        assert clone_json =~ "cloned"

        assert {:ok, pull_json} =
                 Orchestrator.run(
                   pid,
                   ~s({"op":"pull","args":{"url":"#{@fixture_url}"}}),
                   opts
                 )

        assert pull_json =~ "\"ok\":true" or pull_json =~ ~s("ok":true)
        assert pull_json =~ "Already up to date" or pull_json =~ "Fast-forward"
        refute pull_json =~ "not fast-forward"

        # Plain fetch still reports fetched (no FF step)
        assert {:ok, fetch_json} =
                 Orchestrator.run(
                   pid,
                   ~s({"op":"fetch","args":{"url":"#{@fixture_url}"}}),
                   opts
                 )

        assert fetch_json =~ "fetched"
        :ok = GitEngine.stop(pid)
      after
        File.rm_rf(root)
      end
    end
  end

  # ── R44–R47 server push (pack.build + receive-pack fixture) ────────────────

  @tag timeout: 30_000
  test "push read_only: true still rejects" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"push","args":{"url":"#{@fixture_url}"}}),
               orch_opts() ++ [read_only: true]
             )

    assert is_binary(json)
    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    refute json =~ "\"ok\":true"
    assert json =~ "read-only"
    assert json =~ "\"code\":1" or json =~ ~s("code":1)

    # host_call demux path also fails closed when RO
    assert {:ok, json2} =
             GitEngine.handle_host_call(
               pid,
               "git",
               ~s({"op":"push","args":{"url":"#{@fixture_url}"}}),
               orch_opts() ++ [read_only: true]
             )

    assert json2 =~ "\"ok\":false" or json2 =~ ~s("ok":false)
    refute json2 =~ "\"ok\":true"
    assert json2 =~ "read-only"

    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 60_000
  test "push with local commit builds PACK and posts via fixture transport" do
    path = engine_path()
    root =
      Path.join(
        System.tmp_dir!(),
        "orch-push-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    assert {:ok, pid} = GitEngine.start(executable: path, root: root)

    assert {:ok, init} = GitEngine.run(pid, %{"op" => "init"})
    assert init["ok"] == true or (is_binary(Map.get(init, "raw")) and init["raw"] =~ "\"ok\":true")

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "p.txt", "content" => "pushme\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "p.txt"}})

    assert {:ok, commit} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{
                 "message" => "c",
                 "name" => "P",
                 "email" => "p@p",
                 "when_unix" => 1_700_000_100
               }
             })

    assert commit["ok"] == true or
             (is_binary(Map.get(commit, "raw")) and commit["raw"] =~ "\"ok\":true"),
           "commit failed: #{inspect(commit)}"

    {:ok, push_agent} = Agent.start_link(fn -> nil end)

    # Lease: remote has no tip yet (create).
    zero = "0000000000000000000000000000000000000000"

    transport = fn
      :list_refs, {_url, _opts} ->
        {:ok, [%{name: "refs/heads/master", hash: zero}]}

      :fetch_packs, _ ->
        flunk("push must not call fetch_packs")

      :push_packs, {url, commands, pack_bin, _opts} ->
        Agent.update(push_agent, fn _ ->
          %{url: url, commands: commands, pack: pack_bin, pack_len: byte_size(pack_bin)}
        end)

        {:ok, %{ok: true, message: "ok"}}
    end

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"push","args":{"url":"#{@fixture_url}"}}),
               transport: transport,
               allowed_origins: [@fixture_origin]
             )

    assert json =~ "\"ok\":true" or json =~ ~s("ok":true), "push failed: #{json}"
    assert json =~ "pushed"
    refute json =~ "not supported"

    recorded = Agent.get(push_agent, & &1)
    assert is_map(recorded), "push_packs not invoked"
    assert recorded.url == @fixture_url
    assert recorded.pack_len > 0
    assert match?(<<"PACK", _::binary>>, recorded.pack)
    assert is_list(recorded.commands) and recorded.commands != []

    # push.complete should have written remote-tracking.
    assert {:ok, rev} =
             GitEngine.run(pid, %{
               "op" => "rev-parse",
               "args" => %{"rev" => "refs/remotes/origin/master"}
             })

    stdout = rev["stdout"] || Map.get(rev, "raw") || ""
    assert is_binary(stdout) and stdout != ""

    Agent.stop(push_agent)
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "push origin not allowlisted fails before dial" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)
    dialed = :atomics.new(1, signed: false)

    transport = fn
      :list_refs, _ ->
        :atomics.put(dialed, 1, 1)
        {:ok, []}

      :push_packs, _ ->
        :atomics.put(dialed, 1, 1)
        {:ok, %{ok: true, message: "ok"}}
    end

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"push","args":{"url":"#{@fixture_url}"}}),
               transport: transport,
               allowed_origins: ["https://other.example"]
             )

    assert json =~ "not allowlisted"
    assert :atomics.get(dialed, 1) == 0
    :ok = GitEngine.stop(pid)
  end

  test "parse_receive_status maps unpack/ng failures" do
    assert %{ok: true} = SmartHttp.parse_receive_status("000eunpack ok\n0017ok refs/heads/main\n0000")
    assert %{ok: false, message: msg} = SmartHttp.parse_receive_status("unpack error bad\n")
    assert msg =~ "unpack"
    assert %{ok: false, message: ng} = SmartHttp.parse_receive_status("ng refs/heads/main non-fast-forward\n")
    assert ng =~ "ng "
  end

  # ── R43 Auth kinds (header injection, no network) ─────────────────────────

  test "auth_headers injects bearer, header, basic; never embeds secrets in URL helpers" do
    assert [] = SmartHttp.auth_headers(%{kind: :none})
    assert [] = SmartHttp.auth_headers(nil)

    assert [{"authorization", "Bearer tok-xyz"}] =
             SmartHttp.auth_headers(%{kind: :bearer, token: "tok-xyz"})

    assert [{"x-api-key", "secret-key"}] =
             SmartHttp.auth_headers(%{kind: :header, name: "X-Api-Key", value: "secret-key"})

    basic = SmartHttp.auth_headers(%{kind: :basic, username: "alice", password: "s3cr3t"})
    assert [{"authorization", value}] = basic
    assert String.starts_with?(value, "Basic ")
    decoded = value |> String.replace_prefix("Basic ", "") |> Base.decode64!()
    assert decoded == "alice:s3cr3t"

    # String keys / kinds (connection-catalog style)
    assert [{"authorization", "Bearer t2"}] =
             SmartHttp.auth_headers(%{"kind" => "bearer", "token" => "t2"})

    assert [{"authorization", "Basic " <> _}] =
             SmartHttp.auth_headers(%{"kind" => "basic", "username" => "u", "password" => "p"})

    # Unknown kind → no headers (do not invent)
    assert [] = SmartHttp.auth_headers(%{kind: :query, name: "t", value: "v"})
  end

  # ── R40 BEAM pack cache (download-key; credentials never in key) ───────────

  test "upload_pack_cache_key is stable and excludes credentials" do
    alias AgentOS.Git.PackCache

    k1 =
      PackCache.upload_pack_cache_key(
        "https://example.com/r.git",
        ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"],
        [],
        1
      )

    k2 =
      PackCache.upload_pack_cache_key(
        "https://example.com/r.git",
        # reverse order → same key after sort
        ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
        [],
        1
      )

    assert k1 == k2
    assert k1 =~ "upload-pack:v1:"
    assert k1 =~ "https://example.com/r.git"
    assert k1 =~ ":d1"
    secret = "s3cr3t-bearer-token"
    refute k1 =~ secret
    refute k1 =~ "Authorization"
    refute k1 =~ "Bearer"
  end

  @tag timeout: 60_000
  test "second clone with pack_cache does not call fetch_packs twice" do
    alias AgentOS.Git.PackCache

    path = engine_path()
    pack = minimal_pack_bytes()
    assert byte_size(pack) > 0

    {:ok, cache} = PackCache.start_link()
    fetch_count = :atomics.new(1, signed: false)

    tip = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    transport = fn
      :list_refs, {_url, _opts} ->
        {:ok, [%{name: "refs/heads/main", hash: tip}]}

      :fetch_packs, {_url, _want, _have, _opts} ->
        :atomics.add(fetch_count, 1, 1)
        {:ok, pack}

      :push_packs, _ ->
        flunk("clone must not push")
    end

    # Auth must not affect cache key — same secret on both clones.
    secret = "s3cr3t-bearer-token"

    opts = [
      transport: transport,
      allowed_origins: [@fixture_origin],
      pack_cache: cache,
      auth: %{kind: :bearer, token: secret}
    ]

    root1 =
      Path.join(
        System.tmp_dir!(),
        "orch-cache1-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    root2 =
      Path.join(
        System.tmp_dir!(),
        "orch-cache2-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root1)
    File.mkdir_p!(root2)

    try do
      assert {:ok, pid1} = GitEngine.start(executable: path, root: root1)

      assert {:ok, json1} =
               Orchestrator.run(
                 pid1,
                 ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
                 opts
               )

      # Import of 0-object pack may fail; transport count is what we assert.
      assert is_binary(json1)
      assert :atomics.get(fetch_count, 1) == 1

      pack_key =
        PackCache.upload_pack_cache_key(
          @fixture_url,
          [tip],
          [],
          1
        )

      dig = PackCache.get_by_key(cache, pack_key)
      assert is_binary(dig), "pack cache key miss after first clone: #{pack_key}"
      refute pack_key =~ secret
      refute dig =~ secret
      assert PackCache.get(cache, dig) == pack

      assert {:ok, pid2} = GitEngine.start(executable: path, root: root2)

      assert {:ok, json2} =
               Orchestrator.run(
                 pid2,
                 ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
                 opts
               )

      assert is_binary(json2)
      assert :atomics.get(fetch_count, 1) == 1,
             "second clone must hit pack cache (fetch_packs stays 1)"

      :ok = GitEngine.stop(pid1)
      :ok = GitEngine.stop(pid2)
    after
      PackCache.stop(cache)
      File.rm_rf(root1)
      File.rm_rf(root2)
    end
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

  # ── R31 push approval ──────────────────────────────────────────────────────

  @tag timeout: 30_000
  test "R31 require_approval without fun rejects push (fail closed)" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    dialed = :atomics.new(1, signed: false)

    transport = fn
      :list_refs, _ ->
        :atomics.put(dialed, 1, 1)
        {:ok, [%{name: "refs/heads/master", hash: "0000000000000000000000000000000000000000"}]}

      :push_packs, _ ->
        :atomics.put(dialed, 1, 1)
        {:ok, %{ok: true, message: "ok"}}
    end

    # Seed a commit so push.prepare has commands (else fails earlier).
    assert {:ok, _} = GitEngine.run(pid, %{"op" => "init"})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "p.txt", "content" => "p\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "p.txt"}})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{
                 "message" => "c",
                 "name" => "P",
                 "email" => "p@p",
                 "when_unix" => 1_700_000_200
               }
             })

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"push","args":{"url":"#{@fixture_url}"}}),
               transport: transport,
               allowed_origins: [@fixture_origin],
               require_approval: true
             )

    assert json =~ "requires approval"
    # Lease list_refs may run before approval; receive-pack must not.
    refute json =~ "pushed"
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 60_000
  test "R31 on_push_approval true allows push" do
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
                 "message" => "c",
                 "name" => "P",
                 "email" => "p@p",
                 "when_unix" => 1_700_000_201
               }
             })

    zero = "0000000000000000000000000000000000000000"
    approved? = :atomics.new(1, signed: false)

    transport = fn
      :list_refs, _ ->
        {:ok, [%{name: "refs/heads/master", hash: zero}]}

      :push_packs, _ ->
        {:ok, %{ok: true, message: "ok"}}
    end

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"push","args":{"url":"#{@fixture_url}"}}),
               transport: transport,
               allowed_origins: [@fixture_origin],
               require_approval: true,
               on_push_approval: fn ctx ->
                 :atomics.put(approved?, 1, 1)
                 assert is_map(ctx)
                 assert is_binary(ctx.url)
                 true
               end
             )

    assert json =~ "pushed" or json =~ "\"ok\":true"
    assert :atomics.get(approved?, 1) == 1
    :ok = GitEngine.stop(pid)
  end

  # ── R66 second attach fail-closed ──────────────────────────────────────────

  @tag timeout: 120_000
  test "R66 second attach_git fails closed without leaking Port" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      IO.puts(:stderr, "skipping R66 attach test: kernel/posix runfiles missing")
    else
      id = {"git-k21", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}

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
                   allowed_origins: [@fixture_origin]
                 )

        info1 = AgentOS.ControlPlane.info(id)
        assert info1.git_attached == true

        # Second attach must not open another Port.
        assert {:error, :git_already_attached} =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   allowed_origins: [@fixture_origin]
                 )

        # First attachment still live.
        info2 = AgentOS.ControlPlane.info(id)
        assert info2.git_attached == true

        # Detach then re-attach works.
        assert :ok = AgentOS.ControlPlane.detach_git(id)
        assert AgentOS.ControlPlane.info(id).git_attached == false

        assert :ok =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   allowed_origins: [@fixture_origin]
                 )

        assert AgentOS.ControlPlane.info(id).git_attached == true
        assert :ok = AgentOS.ControlPlane.detach_git(id)
      after
        AgentOS.ControlPlane.dispose(id)
      end
    end
  end

  # ── R5 attach path detaches on engine death ────────────────────────────────

  @tag timeout: 120_000
  test "R5 Process.exit engine → attach path detaches" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      IO.puts(:stderr, "skipping R5 attach detach test: kernel/posix runfiles missing")
    else
      id = {"git-eio", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}

      try do
        assert {:ok, _vm} =
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
                   allowed_origins: [@fixture_origin]
                 )

        vm = AgentOS.ControlPlane.whereis(id)
        st = :sys.get_state(vm)
        eng = st.git_engine
        assert is_pid(eng) and Process.alive?(eng)

        Process.exit(eng, :kill)

        assert_eventually(fn ->
          AgentOS.ControlPlane.info(id).git_attached == false
        end)
      after
        AgentOS.ControlPlane.dispose(id)
      end
    end
  end

  # ── R100 host_call_close cancels inflight remote ───────────────────────────

  @tag timeout: 120_000
  test "R100 host_call_close cancels queued/inflight git remote" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      IO.puts(:stderr, "skipping R100 close test: kernel/posix runfiles missing")
    else
      id = {"git-close", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}
      pack = File.read!(Path.expand("../fixtures/git/minimal.pack", __DIR__))
      tip = File.read!(Path.expand("../fixtures/git/minimal.tip", __DIR__)) |> String.trim()
      gate = :atomics.new(1, signed: false)

      transport = fn
        :list_refs, _ ->
          # Hold until close so Task is still running.
          for _ <- 1..50, :atomics.get(gate, 1) == 0, do: Process.sleep(20)
          {:ok, [%{name: "refs/heads/main", hash: tip}]}

        :fetch_packs, _ ->
          {:ok, pack}
      end

      try do
        assert {:ok, _} =
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

        open_ev = %{
          kind: :host_call,
          handle: 9_201,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}"}})
        }

        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, open_ev)
        Process.sleep(30)
        assert AgentOS.ControlPlane.info(id).git_inflight >= 1

        close_ev = %{kind: :host_call_close, handle: 9_201, name: "git"}
        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, close_ev)

        # Release transport in case Task was past list_refs.
        :atomics.put(gate, 1, 1)

        assert_eventually(fn ->
          AgentOS.ControlPlane.info(id).git_inflight == 0
        end)

        assert :ok = AgentOS.ControlPlane.detach_git(id)
      after
        AgentOS.ControlPlane.dispose(id)
      end
    end
  end

  # ── R85 metrics ────────────────────────────────────────────────────────────

  @tag timeout: 30_000
  test "R85 metrics counters tick on orch clone deny" do
    AgentOS.Git.Metrics.reset()
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    assert {:ok, _json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               transport: fixture_transport(),
               allowed_origins: ["https://other.example"]
             )

    snap = AgentOS.Git.Metrics.snapshot()
    assert snap.clone_error >= 1
    :ok = GitEngine.stop(pid)
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
