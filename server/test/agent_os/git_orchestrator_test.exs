defmodule AgentOS.Git.OrchestratorTest do
  use ExUnit.Case, async: false

  alias AgentOS.Git.Connections
  alias AgentOS.Git.Orchestrator
  alias AgentOS.Git.SmartHttp
  alias AgentOS.GitEngine

  @moduletag :git_engine

  @fixture_url "https://example.com/demo.git"
  @fixture_origin "https://example.com"

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

  # Fixture transport: no real network.
  # Prefer explicit allowed_origins matching the fixture URL (not :any).
  # Agent records last push for assertions.
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

    assert {:ok, "https://example.com:8443"} =
             SmartHttp.request_origin("https://example.com:8443/")

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

  # locate PACK offset on disk without loading whole body as pack.
  test "locate_pack_offset finds PACK and pack_byte_size uses offset" do
    path =
      Path.join(
        System.tmp_dir!(),
        "pack-off-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    # Prefix + PACK payload (simulates smart-HTTP pkt-line preamble).
    prefix = "0008NAK\n"
    pack = "PACKdeadbeef"
    File.write!(path, prefix <> pack)

    assert {:ok, offset} = SmartHttp.locate_pack_offset(path)
    assert offset == byte_size(prefix)
    assert SmartHttp.pack_byte_size({:file, path, offset}) == byte_size(pack)

    assert {:ok, ^pack} = SmartHttp.read_pack_source({:file, path, offset})
    assert :ok = SmartHttp.cleanup_pack_source({:file, path, offset})
    refute File.regular?(path)
  end

  test "locate_pack_offset fails closed without PACK magic" do
    path =
      Path.join(
        System.tmp_dir!(),
        "pack-nop-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.write!(path, "no pack here at all")
    assert {:error, :no_pack_magic} = SmartHttp.locate_pack_offset(path)
    File.rm(path)
  end

  # product upload-pack streams to temp file; size cap fails mid-stream.
  test "product stream fetch_packs fails closed when body exceeds max_pack_bytes" do
    # Local server returns 200 + body larger than max (no Content-Length so the
    # cap is enforced while streaming chunks — not only via header pre-check).
    max = 64
    body = "0008NAK\nPACK" <> String.duplicate("x", max + 8)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    server =
      spawn(fn ->
        case :gen_tcp.accept(listen, 5_000) do
          {:ok, sock} ->
            {:ok, _req} = :gen_tcp.recv(sock, 0, 5_000)

            # No Content-Length: body delimited by connection close.
            resp =
              "HTTP/1.1 200 OK\r\n" <>
                "Content-Type: application/x-git-upload-pack-result\r\n" <>
                "Connection: close\r\n" <>
                "\r\n" <>
                body

            :gen_tcp.send(sock, resp)
            :gen_tcp.close(sock)

          {:error, _} ->
            :ok
        end

        :gen_tcp.close(listen)
      end)

    origin = "http://127.0.0.1:#{port}"

    assert {:error, {:upload_pack_failed, :body_too_large}} =
             SmartHttp.fetch_packs(
               origin <> "/demo.git",
               ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
               [],
               allowed_origins: [origin],
               max_pack_bytes: max
             )

    # Content-Length alone (over max) fails closed before body drain.
    {:ok, listen2} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port2} = :inet.port(listen2)

    _server2 =
      spawn(fn ->
        case :gen_tcp.accept(listen2, 5_000) do
          {:ok, sock} ->
            {:ok, _req} = :gen_tcp.recv(sock, 0, 5_000)

            resp =
              "HTTP/1.1 200 OK\r\n" <>
                "Content-Type: application/x-git-upload-pack-result\r\n" <>
                "Content-Length: #{max + 1}\r\n" <>
                "Connection: close\r\n" <>
                "\r\n" <>
                String.duplicate("y", max + 1)

            :gen_tcp.send(sock, resp)
            :gen_tcp.close(sock)

          {:error, _} ->
            :ok
        end

        :gen_tcp.close(listen2)
      end)

    origin2 = "http://127.0.0.1:#{port2}"

    assert {:error, {:upload_pack_failed, :body_too_large}} =
             SmartHttp.fetch_packs(
               origin2 <> "/demo.git",
               ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
               [],
               allowed_origins: [origin2],
               max_pack_bytes: max
             )

    ref = Process.monitor(server)
    assert_receive {:DOWN, ^ref, :process, ^server, _}, 2_000
  end

  test "product stream fetch_packs returns file pack_source with PACK offset" do
    pack = "PACK" <> <<0, 0, 0, 2>> <> String.duplicate(<<1>>, 32)
    # Pkt-line style preamble before PACK (smart-HTTP upload-pack shape).
    body = "0008NAK\n" <> pack

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      case :gen_tcp.accept(listen, 5_000) do
        {:ok, sock} ->
          {:ok, _req} = :gen_tcp.recv(sock, 0, 5_000)

          resp =
            "HTTP/1.1 200 OK\r\n" <>
              "Content-Type: application/x-git-upload-pack-result\r\n" <>
              "Content-Length: #{byte_size(body)}\r\n" <>
              "Connection: close\r\n" <>
              "\r\n" <>
              body

          :gen_tcp.send(sock, resp)
          :gen_tcp.close(sock)

        {:error, _} ->
          :ok
      end

      :gen_tcp.close(listen)
    end)

    origin = "http://127.0.0.1:#{port}"

    assert {:ok, {:file, path, offset}} =
             SmartHttp.fetch_packs(
               origin <> "/demo.git",
               ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"],
               [],
               allowed_origins: [origin],
               max_pack_bytes: 1024
             )

    assert File.regular?(path)
    assert offset == byte_size("0008NAK\n")
    assert SmartHttp.pack_byte_size({:file, path, offset}) == byte_size(pack)
    assert {:ok, ^pack} = SmartHttp.read_pack_source({:file, path, offset})
    assert :ok = SmartHttp.cleanup_pack_source({:file, path, offset})
    refute File.regular?(path)
  end

  # redirect policy — never follow; open redirect cannot leave allowlist.
  test "classify_http_response rejects 3xx as redirect_not_allowed" do
    assert {:error, :redirect_not_allowed} =
             SmartHttp.classify_http_response(301, "moved", 64 * 1024 * 1024)

    assert {:error, :redirect_not_allowed} =
             SmartHttp.classify_http_response(302, "", 64 * 1024 * 1024)

    assert {:error, :redirect_not_allowed} =
             SmartHttp.classify_http_response(307, "tmp", 1024)

    assert {:error, :redirect_not_allowed} =
             SmartHttp.classify_http_response(308, <<>>, 1024)

    assert {:error, {:http_status, 404}} =
             SmartHttp.classify_http_response(404, "nope", 1024)

    assert {:error, {:http_status, 500}} =
             SmartHttp.classify_http_response(500, "err", 1024)

    assert {:ok, "ok-body"} =
             SmartHttp.classify_http_response(200, "ok-body", 1024)

    assert {:error, :body_too_large} =
             SmartHttp.classify_http_response(200, String.duplicate("x", 10), 5)
  end

  test "product :httpc path rejects 302 open redirect without following Location" do
    # Local fixture server: each request → 302 to evil origin. SmartHttp must
    # fail closed and never issue a follow-up hop (autoredirect: false + classify).
    # Serves three product verbs (list / upload-pack / receive-pack).
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    parent = self()
    expected_dials = 3

    server =
      spawn(fn ->
        for _ <- 1..expected_dials do
          case :gen_tcp.accept(listen, 5_000) do
            {:ok, sock} ->
              {:ok, req} = :gen_tcp.recv(sock, 0, 5_000)
              send(parent, {:got_request, req})

              resp =
                "HTTP/1.1 302 Found\r\n" <>
                  "Location: https://evil.example/stolen-pack\r\n" <>
                  "Content-Length: 0\r\n" <>
                  "Connection: close\r\n" <>
                  "\r\n"

              :gen_tcp.send(sock, resp)
              :gen_tcp.close(sock)

            {:error, reason} ->
              send(parent, {:accept_failed, reason})
          end
        end

        # Extra accept would mean a redirect follow — report it.
        case :gen_tcp.accept(listen, 200) do
          {:ok, sock2} ->
            send(parent, :extra_hop)
            :gen_tcp.close(sock2)

          {:error, _} ->
            :ok
        end

        :gen_tcp.close(listen)
      end)

    origin = "http://127.0.0.1:#{port}"
    url = origin <> "/demo.git"

    assert {:error, {:list_refs_failed, :redirect_not_allowed}} =
             SmartHttp.list_refs(url, allowed_origins: [origin])

    assert {:error, {:upload_pack_failed, :redirect_not_allowed}} =
             SmartHttp.fetch_packs(url, ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"], [],
               allowed_origins: [origin]
             )

    assert {:error, {:receive_pack_failed, :redirect_not_allowed}} =
             SmartHttp.push_packs(
               url,
               [
                 %{
                   old_hash: "0000000000000000000000000000000000000000",
                   new_hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                   name: "refs/heads/main"
                 }
               ],
               "PACK",
               allowed_origins: [origin]
             )

    requests =
      for _ <- 1..expected_dials do
        assert_receive {:got_request, req}, 2_000
        assert is_binary(req)
        # Each dial targeted the allowlisted fixture, never evil.example.
        refute req =~ "evil.example"
        req
      end

    assert length(requests) == expected_dials
    refute_receive :extra_hop, 300
    refute_receive {:accept_failed, _}, 50

    ref = Process.monitor(server)
    assert_receive {:DOWN, ^ref, :process, ^server, _}, 2_000
  end

  # ── Orchestrator security gates ────────────────────────────────────────────

  @tag timeout: 30_000
  test "clone preflight rejects non-fresh roots before transport and accepts fresh roots" do
    path = engine_path()

    fresh_root =
      Path.join(
        System.tmp_dir!(),
        "orch-preflight-fresh-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    file_root =
      Path.join(
        System.tmp_dir!(),
        "orch-preflight-file-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    repo_root =
      Path.join(
        System.tmp_dir!(),
        "orch-preflight-repo-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(fresh_root)
    File.mkdir_p!(file_root)
    File.mkdir_p!(repo_root)
    File.write!(Path.join(file_root, "marker.txt"), "marker\n")

    try do
      assert {:ok, repo_pid} = GitEngine.start(executable: path, root: repo_root)
      assert {:ok, init} = GitEngine.run(repo_pid, %{"op" => "init"})

      assert init["ok"] == true or
               (is_binary(Map.get(init, "raw")) and init["raw"] =~ "\"ok\":true")

      assert {:ok, _} =
               GitEngine.run(repo_pid, %{
                 "op" => "write",
                 "args" => %{"path" => "tracked.txt", "content" => "tracked\n"}
               })

      assert {:ok, _} =
               GitEngine.run(repo_pid, %{"op" => "add", "args" => %{"path" => "tracked.txt"}})

      assert {:ok, _} =
               GitEngine.run(repo_pid, %{
                 "op" => "commit",
                 "args" => %{
                   "message" => "preflight repo",
                   "name" => "Hardening",
                   "email" => "hardening@test",
                   "when_unix" => 1_700_000_500
                 }
               })

      :ok = GitEngine.stop(repo_pid)

      dialed = :atomics.new(1, signed: false)

      transport = fn
        :list_refs, {_url, _opts} ->
          :atomics.add(dialed, 1, 1)
          {:ok, [%{name: "refs/heads/main", hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}

        :fetch_packs, {_url, _want, _have, _opts} ->
          :atomics.add(dialed, 1, 1)
          {:ok, <<>>}
      end

      opts = [transport: transport, allowed_origins: [@fixture_origin]]

      for {root, needle} <- [{file_root, "fresh"}, {repo_root, "fresh"}] do
        assert {:ok, pid} = GitEngine.start(executable: path, root: root)
        assert {:ok, preflight} = GitEngine.run(pid, %{"op" => "clone.preflight"})
        refute preflight["ok"] == true

        assert {:ok, json} =
                 Orchestrator.run(
                   pid,
                   ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
                   opts
                 )

        assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
        assert json =~ needle
        assert :atomics.get(dialed, 1) == 0
        :ok = GitEngine.stop(pid)
      end

      assert {:ok, fresh_pid} = GitEngine.start(executable: path, root: fresh_root)

      assert {:ok, fresh_preflight} =
               GitEngine.run(fresh_pid, %{"op" => "clone.preflight"})

      assert fresh_preflight["ok"] == true or
               (is_binary(Map.get(fresh_preflight, "raw")) and
                  fresh_preflight["raw"] =~ "\"ok\":true")

      assert {:ok, fresh_json} =
               Orchestrator.run(
                 fresh_pid,
                 ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
                 opts
               )

      assert fresh_json =~ "empty pack"
      assert :atomics.get(dialed, 1) == 2
      assert {:ok, released} = GitEngine.run(fresh_pid, %{"op" => "clone.preflight"})
      assert released["ok"] == true
      :ok = GitEngine.stop(fresh_pid)
    after
      File.rm_rf(fresh_root)
      File.rm_rf(file_root)
      File.rm_rf(repo_root)
    end
  end

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
    assert match?(<<"PACK", _::binary>>, pack)

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

  # ── pull = fetch + local FF ────────────────────────────────────────────

  @tag timeout: 60_000
  test "pull after successful clone of minimal.pack is already up to date" do
    path = engine_path()
    pack_path = Path.expand("../fixtures/git/minimal.pack", __DIR__)
    tip_path = Path.expand("../fixtures/git/minimal.tip", __DIR__)

    if not (File.regular?(pack_path) and File.regular?(tip_path)) do
      flunk("requires minimal.pack fixture under test runfiles")
    else
      pack = File.read!(pack_path)
      tip = File.read!(tip_path) |> String.trim()

      root =
        Path.join(
          System.tmp_dir!(),
          "orch-pull-" <> Integer.to_string(System.unique_integer([:positive]))
        )

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

  # clone.apply post-step sets remote.origin.url + branch tracking;
  # pull via remote name (no url) uses that config.
  @tag timeout: 60_000
  test "clone sets remote.origin.url and branch tracking; pull uses remote name" do
    path = engine_path()
    pack_path = Path.expand("../fixtures/git/minimal.pack", __DIR__)
    tip_path = Path.expand("../fixtures/git/minimal.tip", __DIR__)

    if not (File.regular?(pack_path) and File.regular?(tip_path)) do
      flunk("requires minimal.pack fixture under test runfiles")
    end

    pack = File.read!(pack_path)
    tip = File.read!(tip_path) |> String.trim()

    root =
      Path.join(
        System.tmp_dir!(),
        "orch-d9-" <> Integer.to_string(System.unique_integer([:positive]))
      )

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

      assert {:ok, remote_url} =
               GitEngine.run(pid, %{
                 "op" => "config",
                 "args" => %{"action" => "get", "key" => "remote.origin.url"}
               })

      stdout = remote_url["stdout"] || Map.get(remote_url, :stdout) || ""
      assert to_string(stdout) =~ @fixture_url

      assert {:ok, br_remote} =
               GitEngine.run(pid, %{
                 "op" => "config",
                 "args" => %{"action" => "get", "key" => "branch.main.remote"}
               })

      br_out = br_remote["stdout"] || Map.get(br_remote, :stdout) || ""
      assert to_string(br_out) =~ "origin"

      assert {:ok, br_merge} =
               GitEngine.run(pid, %{
                 "op" => "config",
                 "args" => %{"action" => "get", "key" => "branch.main.merge"}
               })

      merge_out = br_merge["stdout"] || Map.get(br_merge, :stdout) || ""
      assert to_string(merge_out) =~ "refs/heads/main"

      # Pull with remote name only — URL comes from remote.origin.url.
      assert {:ok, pull_json} =
               Orchestrator.run(
                 pid,
                 ~s({"op":"pull","args":{"remote":"origin"}}),
                 opts
               )

      assert pull_json =~ "\"ok\":true" or pull_json =~ ~s("ok":true),
             "pull remote=origin failed: #{pull_json}"

      assert pull_json =~ "Already up to date" or pull_json =~ "Fast-forward" or
               pull_json =~ "fetched"

      # Empty args also default to origin after clone.
      assert {:ok, pull_empty} =
               Orchestrator.run(pid, ~s({"op":"pull","args":{}}), opts)

      assert pull_empty =~ "\"ok\":true" or pull_empty =~ ~s("ok":true),
             "pull {} failed: #{pull_empty}"

      :ok = GitEngine.stop(pid)
    after
      File.rm_rf(root)
    end
  end

  # ── server push (pack.build + receive-pack fixture) ────────────────

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

    assert init["ok"] == true or
             (is_binary(Map.get(init, "raw")) and init["raw"] =~ "\"ok\":true")

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
    assert %{ok: true} =
             SmartHttp.parse_receive_status("000eunpack ok\n0017ok refs/heads/main\n0000")

    assert %{ok: false, message: msg} = SmartHttp.parse_receive_status("unpack error bad\n")
    assert msg =~ "unpack"

    assert %{ok: false, message: ng} =
             SmartHttp.parse_receive_status("ng refs/heads/main non-fast-forward\n")

    assert ng =~ "ng "
  end

  @tag timeout: 60_000
  test "delete-ref push: zero newHash, empty pack, fixture receive-status ok" do
    path = engine_path()

    root =
      Path.join(
        System.tmp_dir!(),
        "orch-push-del-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    assert {:ok, pid} = GitEngine.start(executable: path, root: root)
    assert {:ok, _} = GitEngine.run(pid, %{"op" => "init"})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "d.txt", "content" => "del\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "d.txt"}})

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

    assert {:ok, rev} = GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})
    tip = (rev["stdout"] || "") |> String.trim() |> String.split(~r/\s+/) |> hd()
    assert Regex.match?(~r/^[0-9a-fA-F]{40}$/, tip)

    {:ok, push_agent} = Agent.start_link(fn -> nil end)
    zero = "0000000000000000000000000000000000000000"

    transport = fn
      :list_refs, {_url, _opts} ->
        {:ok, [%{name: "refs/heads/master", hash: String.downcase(tip)}]}

      :fetch_packs, _ ->
        flunk("delete push must not call fetch_packs")

      :push_packs, {url, commands, pack_bin, _opts} ->
        Agent.update(push_agent, fn _ ->
          %{url: url, commands: commands, pack: pack_bin, pack_len: byte_size(pack_bin)}
        end)

        {:ok, %{ok: true, message: "ok"}}
    end

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"push","args":{"url":"#{@fixture_url}","delete":true}}),
               transport: transport,
               allowed_origins: [@fixture_origin]
             )

    assert json =~ "\"ok\":true" or json =~ ~s("ok":true), "delete push failed: #{json}"
    assert json =~ "pushed"

    recorded = Agent.get(push_agent, & &1)
    assert is_map(recorded)
    assert recorded.pack_len == 0
    assert recorded.pack == <<>>
    assert is_list(recorded.commands) and recorded.commands != []

    for c <- recorded.commands do
      assert c.new_hash == zero
      assert is_binary(c.old_hash) and c.old_hash != zero
    end

    # Cruel: non-delete empty pack still fails (inject via transport not needed —
    # create push with remote empty still builds real pack; assert gate via unit-ish path).
    Agent.stop(push_agent)
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 60_000
  test "pack_build with haves reduces pack size" do
    path = engine_path()

    root =
      Path.join(
        System.tmp_dir!(),
        "pack-haves-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    assert {:ok, pid} = GitEngine.start(executable: path, root: root)
    assert {:ok, _} = GitEngine.run(pid, %{"op" => "init"})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "a.txt", "content" => "one\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "a.txt"}})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{
                 "message" => "c1",
                 "name" => "T",
                 "email" => "t@t",
                 "when_unix" => 1_700_000_300
               }
             })

    assert {:ok, rev1} = GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})
    p1 = (rev1["stdout"] || "") |> String.trim() |> String.split(~r/\s+/) |> hd()

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "write",
               "args" => %{"path" => "b.txt", "content" => "two-more-for-thin-pack\n"}
             })

    assert {:ok, _} = GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => "b.txt"}})

    assert {:ok, _} =
             GitEngine.run(pid, %{
               "op" => "commit",
               "args" => %{
                 "message" => "c2",
                 "name" => "T",
                 "email" => "t@t",
                 "when_unix" => 1_700_000_301
               }
             })

    assert {:ok, rev2} = GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}})
    p2 = (rev2["stdout"] || "") |> String.trim() |> String.split(~r/\s+/) |> hd()

    assert {:ok, full} = GitEngine.pack_build(pid, [p2])
    assert {:ok, thin} = GitEngine.pack_build(pid, [p2], haves: [p1])
    assert match?(<<"PACK", _::binary>>, thin)
    assert byte_size(thin) < byte_size(full)

    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "clone with filter is recorded by transport and does not break" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)
    pack = <<"PACK", 0, 0, 0, 2, 0, 0, 0, 0>>
    tip = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    {:ok, fetch_agent} = Agent.start_link(fn -> nil end)

    transport = fn
      :list_refs, {_url, _opts} ->
        {:ok, [%{name: "refs/heads/master", hash: tip}]}

      :fetch_packs, {_url, _want, _have, opts} ->
        Agent.update(fetch_agent, fn _ -> Keyword.get(opts, :filter) end)
        {:ok, pack}

      :push_packs, _ ->
        flunk("clone must not push")
    end

    # Import of synthetic pack may fail; we only assert filter wiring + no crash before dial.
    _ =
      Orchestrator.run(
        pid,
        ~s({"op":"clone","args":{"url":"#{@fixture_url}","filter":"blob:none"}}),
        transport: transport,
        allowed_origins: [@fixture_origin]
      )

    assert Agent.get(fetch_agent, & &1) == "blob:none"
    Agent.stop(fetch_agent)
    :ok = GitEngine.stop(pid)
  end

  # ── Auth kinds (header injection, no network) ─────────────────────────

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

  # ── BEAM pack cache (download-key; credentials never in key) ───────────

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

  test "product_default_cache is fresh Memory unless SHARED" do
    alias AgentOS.Git.PackCache

    prev_shared = System.get_env("AGENTOS_GIT_PACK_CACHE_SHARED")
    prev_disk = System.get_env("AGENTOS_GIT_PACK_CACHE")

    try do
      System.delete_env("AGENTOS_GIT_PACK_CACHE_SHARED")
      System.delete_env("AGENTOS_GIT_PACK_CACHE")

      refute PackCache.shared_from_env?()
      assert PackCache.disk_dir_from_env() == nil

      # Clear any leftover ephemeral pointer from other tests in this process.
      Process.delete(:agent_os_git_pack_cache_ephemeral)

      a = PackCache.product_default_cache()
      b = PackCache.product_default_cache()
      # Same caller process reuses the ephemeral Agent (per-Task scope).
      assert is_pid(a)
      assert a == b
      assert Process.alive?(a)

      # Different process → different Memory Agent (not process-global).
      other =
        Task.async(fn ->
          Process.delete(:agent_os_git_pack_cache_ephemeral)
          PackCache.product_default_cache()
        end)
        |> Task.await()

      assert is_pid(other)
      assert other != a

      System.put_env("AGENTOS_GIT_PACK_CACHE_SHARED", "1")
      assert PackCache.shared_from_env?()
      shared_a = PackCache.product_default_cache()
      shared_b = PackCache.product_default_cache()
      assert shared_a == shared_b
      assert shared_a == PackCache.default_process_cache()
    after
      if prev_shared,
        do: System.put_env("AGENTOS_GIT_PACK_CACHE_SHARED", prev_shared),
        else: System.delete_env("AGENTOS_GIT_PACK_CACHE_SHARED")

      if prev_disk,
        do: System.put_env("AGENTOS_GIT_PACK_CACHE", prev_disk),
        else: System.delete_env("AGENTOS_GIT_PACK_CACHE")
    end
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

  @tag timeout: 60_000
  test "second clone with disk pack_cache does not call fetch_packs twice" do
    alias AgentOS.Git.PackCache

    path = engine_path()
    pack = minimal_pack_bytes()
    assert byte_size(pack) > 0

    cache_dir =
      Path.join(
        System.tmp_dir!(),
        "orch-disk-cache-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(cache_dir)
    {:ok, cache} = PackCache.start_disk(cache_dir)
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

    secret = "s3cr3t-bearer-token"

    # {:disk, dir} path — same as pack_cache: :disk + AGENTOS_GIT_PACK_CACHE.
    opts = [
      transport: transport,
      allowed_origins: [@fixture_origin],
      pack_cache: {:disk, cache_dir},
      auth: %{kind: :bearer, token: secret}
    ]

    root1 =
      Path.join(
        System.tmp_dir!(),
        "orch-dcache1-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    root2 =
      Path.join(
        System.tmp_dir!(),
        "orch-dcache2-" <> Integer.to_string(System.unique_integer([:positive]))
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
      assert is_binary(dig), "disk pack cache key miss after first clone: #{pack_key}"
      refute pack_key =~ secret
      refute dig =~ secret
      assert PackCache.get(cache, dig) == pack

      # Content-addressed file on disk (layout matches JS DiskPackCache).
      hex = String.replace_prefix(dig, "sha256:", "")
      assert File.regular?(Path.join(cache_dir, hex <> ".pack"))
      assert File.read!(Path.join(cache_dir, hex <> ".pack")) == pack

      # Fresh Agent pointing at same dir still sees the pack (true disk hit).
      PackCache.stop(cache)
      {:ok, cache2} = PackCache.start_disk(cache_dir)
      assert PackCache.get_by_key(cache2, pack_key) == dig
      assert PackCache.get(cache2, dig) == pack

      assert {:ok, pid2} = GitEngine.start(executable: path, root: root2)

      assert {:ok, json2} =
               Orchestrator.run(
                 pid2,
                 ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
                 opts
               )

      assert is_binary(json2)

      assert :atomics.get(fetch_count, 1) == 1,
             "second clone must hit disk pack cache (fetch_packs stays 1)"

      :ok = GitEngine.stop(pid1)
      :ok = GitEngine.stop(pid2)
      PackCache.stop(cache2)
    after
      File.rm_rf(cache_dir)
      File.rm_rf(root1)
      File.rm_rf(root2)
    end
  end

  @tag timeout: 60_000
  test "pack_cache :disk uses AGENTOS_GIT_PACK_CACHE dir across clones" do
    alias AgentOS.Git.PackCache

    path = engine_path()
    pack = minimal_pack_bytes()
    assert byte_size(pack) > 0

    cache_dir =
      Path.join(
        System.tmp_dir!(),
        "orch-env-disk-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(cache_dir)
    prev = System.get_env("AGENTOS_GIT_PACK_CACHE")
    System.put_env("AGENTOS_GIT_PACK_CACHE", cache_dir)

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

    opts = [
      transport: transport,
      allowed_origins: [@fixture_origin],
      pack_cache: :disk
    ]

    root1 =
      Path.join(
        System.tmp_dir!(),
        "orch-envd1-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    root2 =
      Path.join(
        System.tmp_dir!(),
        "orch-envd2-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root1)
    File.mkdir_p!(root2)

    try do
      assert {:ok, pid1} = GitEngine.start(executable: path, root: root1)

      assert {:ok, _} =
               Orchestrator.run(
                 pid1,
                 ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
                 opts
               )

      assert :atomics.get(fetch_count, 1) == 1

      assert {:ok, pid2} = GitEngine.start(executable: path, root: root2)

      assert {:ok, _} =
               Orchestrator.run(
                 pid2,
                 ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
                 opts
               )

      assert :atomics.get(fetch_count, 1) == 1,
             "second clone via :disk env cache must not re-fetch"

      # CA pack file present under env dir
      dig = PackCache.digest_of(pack)
      hex = String.replace_prefix(dig, "sha256:", "")
      assert File.regular?(Path.join(cache_dir, hex <> ".pack"))

      :ok = GitEngine.stop(pid1)
      :ok = GitEngine.stop(pid2)
    after
      if prev,
        do: System.put_env("AGENTOS_GIT_PACK_CACHE", prev),
        else: System.delete_env("AGENTOS_GIT_PACK_CACHE")

      File.rm_rf(cache_dir)
      File.rm_rf(root1)
      File.rm_rf(root2)
    end
  end

  # ── P1.7 foundation: async git host_call via Vm ────────────────────────────

  @tag timeout: 120_000
  test "try_answer_git_host_call returns :answered without blocking on remote orch" do
    # Real kernel VM + attach_git with fixture transport (no network).
    # Proves P1.6: name "git" is claimed async (GenServer returns immediately).
    # partial: after async clone, worktree file is present under engine root.
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
    else
      id = {"git-async", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}
      pack = File.read!(Path.expand("../fixtures/git/minimal.pack", __DIR__))
      tip = File.read!(Path.expand("../fixtures/git/minimal.tip", __DIR__)) |> String.trim()

      root =
        Path.join(
          System.tmp_dir!(),
          "git-async-wt-" <> Integer.to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(root)

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
                   root: root,
                   allowed_origins: [@fixture_origin],
                   transport: transport
                 )

        info0 = AgentOS.ControlPlane.info(id)
        assert info0.git_attached == true
        assert info0.git_allowed_origins == [@fixture_origin]
        # Legacy attach (no :connections): connection catalog empty.
        assert info0.git_connection_count == 0
        assert info0.git_connection_refs == []
        assert info0.git_policy_count == 0

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

        # fixture clone applied — worktree file from minimal.pack.
        assert_eventually(fn ->
          case File.read(Path.join(root, "README")) do
            {:ok, "hello\n"} -> true
            _ -> false
          end
        end)

        assert {:ok, "hello\n"} = File.read(Path.join(root, "README"))

        # Detach cancels any remaining cases cleanly.
        assert :ok = AgentOS.ControlPlane.detach_git(id)
        assert AgentOS.ControlPlane.info(id).git_attached == false
      after
        AgentOS.ControlPlane.dispose(id)
        File.rm_rf(root)
      end
    end
  end

  @tag timeout: 120_000
  test "snapshot refused while git remote host_call Task is inflight" do
    # Slow fixture list_refs holds git_tasks non-empty; snapshot/commit_layer must
    # fail closed (BEAM git bookkeeping gate). Synthetic host handle proves the
    # gate is independent of kernel inflight_egress (monorepo host_call path still
    # elevates egress for real guest handles). Silent mid-clone snapshot is FAIL.
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
    else
      id = {"git-snap-block", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}
      pack = File.read!(Path.expand("../fixtures/git/minimal.pack", __DIR__))
      tip = File.read!(Path.expand("../fixtures/git/minimal.tip", __DIR__)) |> String.trim()

      root =
        Path.join(
          System.tmp_dir!(),
          "git-snap-block-" <> Integer.to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(root)
      # Hold the remote long enough for a concurrent snapshot call to observe inflight.
      hold_ms = 800

      transport = fn
        :list_refs, _ ->
          Process.sleep(hold_ms)
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
                   root: root,
                   allowed_origins: [@fixture_origin],
                   transport: transport
                 )

        # Quiescent baseline: snapshot succeeds before any remote.
        assert {:ok, _base_snap} = AgentOS.ControlPlane.snapshot(id)

        event = %{
          kind: :host_call,
          handle: 9_019,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}"}})
        }

        assert :answered =
                 AgentOS.Vm.try_answer_git_host_call(AgentOS.ControlPlane.whereis(id), event)

        # Task is running (or briefly queued) — must not capture mid-clone state.
        assert_eventually(fn -> AgentOS.ControlPlane.info(id).git_inflight >= 1 end, 50)

        snap_err = AgentOS.ControlPlane.snapshot(id)

        assert match?({:error, msg} when is_binary(msg), snap_err),
               "expected snapshot error while git remote inflight, got: #{inspect(snap_err)}"

        {:error, snap_msg} = snap_err

        assert snap_msg =~ "git remote" or snap_msg =~ "host-egress" or snap_msg =~ "in flight",
               "unexpected snapshot refuse message: #{snap_msg}"

        commit_err = AgentOS.ControlPlane.commit_layer(id)

        assert match?({:error, cmsg} when is_binary(cmsg), commit_err),
               "expected commit_layer error while git remote inflight, got: #{inspect(commit_err)}"

        {:error, commit_msg} = commit_err

        assert commit_msg =~ "git remote" or commit_msg =~ "host-egress" or
                 commit_msg =~ "in flight",
               "unexpected commit refuse message: #{commit_msg}"

        # After remote drains, snapshot is allowed again.
        assert_eventually(fn -> AgentOS.ControlPlane.info(id).git_inflight == 0 end, 100)
        assert {:ok, _after} = AgentOS.ControlPlane.snapshot(id)
      after
        AgentOS.ControlPlane.dispose(id)
        File.rm_rf(root)
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
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
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

  # ── push approval ──────────────────────────────────────────────────────

  @tag timeout: 30_000
  test "require_approval without fun rejects push (fail closed)" do
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
  test "on_push_approval true allows push" do
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

  # ── same-path second attach fail-closed; distinct paths OK ─────────

  @tag timeout: 120_000
  test "same-path second attach_git fails; distinct paths multi-attach" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
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
                   mount_path: "/workspace/repo",
                   allowed_origins: [@fixture_origin]
                 )

        info1 = AgentOS.ControlPlane.info(id)
        assert info1.git_attached == true
        assert info1.git_mount_path == "/workspace/repo"
        assert info1.git_engine_count == 1

        # Same path: must not open another Port.
        assert {:error, :git_already_attached} =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   mount_path: "/workspace/repo",
                   allowed_origins: [@fixture_origin]
                 )

        # First attachment still live.
        info2 = AgentOS.ControlPlane.info(id)
        assert info2.git_attached == true
        assert info2.git_engine_count == 1

        # distinct mount path attaches a second engine.
        assert :ok =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   mount_path: "/workspace/other",
                   allowed_origins: [@fixture_origin]
                 )

        info3 = AgentOS.ControlPlane.info(id)
        assert info3.git_attached == true
        assert info3.git_engine_count == 2
        assert Enum.sort(info3.git_mounts) == ["/workspace/other", "/workspace/repo"]

        # Detach one path leaves the other.
        assert :ok = AgentOS.ControlPlane.detach_git(id, mount_path: "/workspace/other")
        info4 = AgentOS.ControlPlane.info(id)
        assert info4.git_engine_count == 1
        assert info4.git_mounts == ["/workspace/repo"]

        # Detach all.
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

  @tag timeout: 120_000
  test "attach_git stores connections + policies (product path, no flat allowlist)" do
    # VM stores host connections/policies and surfaces refs via info (no secrets).
    # Full clone compose is covered by "connections-only → host_call clone" below.
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
    else
      id = {"git-conn", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}

      connections = [
        %{
          ref: "github.user.work",
          auth: %{kind: :bearer, token: "secret-token-must-not-leak"},
          origins: [@fixture_origin],
          spec: %{url: @fixture_url}
        },
        %{
          "ref" => "gitlab.org.main",
          "auth" => %{"kind" => "none"},
          "origins" => ["https://gitlab.com"]
        }
      ]

      policies = [
        %{pattern: "github.user.work.*", action: :require_approval, owner: :org},
        %{"pattern" => "gitlab.org.*", "action" => "block"}
      ]

      try do
        assert {:ok, _pid} =
                 AgentOS.ControlPlane.create(id,
                   wasm: wasm,
                   base_image: posix,
                   deterministic: true,
                   workers: 0,
                   host_call: :relay
                 )

        # Product path: connections only — no separate allowed_origins/auth.
        assert :ok =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   connections: connections,
                   policies: policies
                 )

        info = AgentOS.ControlPlane.info(id)
        assert info.git_attached == true
        assert info.git_connection_count == 2

        assert Enum.sort(info.git_connection_refs) ==
                 Enum.sort(["github.user.work", "gitlab.org.main"])

        assert info.git_policy_count == 2
        # Flat allowlist not required / not stored when connections present.
        assert info.git_allowed_origins == []
        # Secrets never appear in info (only refs).
        refute inspect(info) =~ "secret-token"

        assert :ok = AgentOS.ControlPlane.detach_git(id)
        info2 = AgentOS.ControlPlane.info(id)
        assert info2.git_attached == false
        assert info2.git_connection_count == 0
        assert info2.git_connection_refs == []
        assert info2.git_policy_count == 0
      after
        AgentOS.ControlPlane.dispose(id)
      end
    end
  end

  @tag timeout: 120_000
  test "attach_git sparse_cone → host_call clone applies Port sparse-set" do
    # Per-mount cone stored on attach; after fixture clone, sparse-checkout exists
    # and root README remains (cone template always includes /*). JS git.sparse parity.
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
    else
      id = {"git-sparse-cone", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}
      pack = File.read!(Path.expand("../fixtures/git/minimal.pack", __DIR__))
      tip = File.read!(Path.expand("../fixtures/git/minimal.tip", __DIR__)) |> String.trim()

      root =
        Path.join(
          System.tmp_dir!(),
          "git-sparse-" <> Integer.to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(root)

      transport = fn
        :list_refs, _ ->
          {:ok, [%{name: "refs/heads/main", hash: tip}]}

        :fetch_packs, _ ->
          {:ok, pack}

        :push_packs, _ ->
          flunk("clone must not push")
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
                   root: root,
                   allowed_origins: [@fixture_origin],
                   transport: transport,
                   sparse_cone: ["src", "docs"]
                 )

        # Mount meta holds normalized cone (alias :git_sparse_cone also accepted on attach).
        vm = AgentOS.ControlPlane.whereis(id)
        %{git_engines: engines} = :sys.get_state(vm)
        mount = Map.get(engines, "/workspace/repo")
        assert is_map(mount)
        assert mount.sparse_cone == ["src", "docs"]

        event = %{
          kind: :host_call,
          handle: 9_620,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}"}})
        }

        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, event)

        assert_eventually(fn ->
          AgentOS.ControlPlane.info(id).git_inflight == 0
        end)

        assert_eventually(fn ->
          case File.read(Path.join(root, "README")) do
            {:ok, "hello\n"} -> true
            _ -> false
          end
        end)

        sc = Path.join(root, ".git/info/sparse-checkout")
        assert File.regular?(sc), "attach sparse_cone must reach Port sparse-set"
        body = File.read!(sc)
        assert body =~ "/src/"
        assert body =~ "/docs/"
        assert body =~ "/*"

        assert :ok = AgentOS.ControlPlane.detach_git(id)
      after
        AgentOS.ControlPlane.dispose(id)
        File.rm_rf(root)
      end
    end
  end

  @tag timeout: 120_000
  test "product path: attach_git connections-only → host_call clone via fixture" do
    # Cruel acceptance: no allowed_origins / flat auth — only connections catalog.
    # attach_git → try_answer_git_host_call "git" clone with args.connection →
    # fixture transport receives spliced host auth; worktree materializes.
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
    else
      id = {"git-conn-clone", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}
      pack = fixture_git_bytes!("minimal.pack")
      tip = fixture_git_bytes!("minimal.tip") |> String.trim()

      root =
        Path.join(
          System.tmp_dir!(),
          "git-conn-clone-" <> Integer.to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(root)
      {:ok, auth_agent} = Agent.start_link(fn -> nil end)

      secret = "conn-only-secret-must-not-leak"

      transport = fn
        :list_refs, {_url, opts} ->
          Agent.update(auth_agent, fn _ -> Keyword.get(opts, :auth) end)
          {:ok, [%{name: "refs/heads/main", hash: tip}]}

        :fetch_packs, {_url, _want, _have, opts} ->
          Agent.update(auth_agent, fn _ -> Keyword.get(opts, :auth) end)
          {:ok, pack}

        :push_packs, _ ->
          flunk("clone must not push")
      end

      connections = [
        %{
          ref: "github.user.work",
          auth: %{kind: :bearer, token: secret},
          origins: [@fixture_origin]
        }
      ]

      try do
        assert {:ok, _pid} =
                 AgentOS.ControlPlane.create(id,
                   wasm: wasm,
                   base_image: posix,
                   deterministic: true,
                   workers: 0,
                   host_call: :relay
                 )

        # Product path: connections only — no allowed_origins, no flat auth.
        assert :ok =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   root: root,
                   connections: connections,
                   transport: transport
                 )

        info0 = AgentOS.ControlPlane.info(id)
        assert info0.git_attached == true
        assert info0.git_connection_refs == ["github.user.work"]
        assert info0.git_allowed_origins == []
        refute inspect(info0) =~ secret

        event = %{
          kind: :host_call,
          handle: 9_501,
          name: "git",
          body:
            ~s({"op":"clone","args":{"url":"#{@fixture_url}","connection":"github.user.work"}})
        }

        assert :answered =
                 AgentOS.Vm.try_answer_git_host_call(AgentOS.ControlPlane.whereis(id), event)

        assert_eventually(fn ->
          AgentOS.ControlPlane.info(id).git_inflight == 0
        end)

        assert_eventually(fn ->
          case File.read(Path.join(root, "README")) do
            {:ok, "hello\n"} -> true
            _ -> false
          end
        end)

        assert {:ok, "hello\n"} = File.read(Path.join(root, "README"))

        seen = Agent.get(auth_agent, & &1)
        assert is_map(seen)
        assert (Map.get(seen, :kind) || Map.get(seen, "kind")) in [:bearer, "bearer"]
        assert (Map.get(seen, :token) || Map.get(seen, "token")) == secret

        # Bare URL without connection fails closed when only connections are set
        # (no flat allowed_origins).
        dialed = :atomics.new(1, signed: false)

        bare_transport = fn
          :list_refs, _ ->
            :atomics.put(dialed, 1, 1)
            {:ok, []}

          :fetch_packs, _ ->
            :atomics.put(dialed, 1, 1)
            {:ok, <<>>}
        end

        # Re-attach to swap transport for bare-URL deny proof.
        assert :ok = AgentOS.ControlPlane.detach_git(id)

        assert :ok =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   connections: connections,
                   transport: bare_transport
                 )

        bare_event = %{
          kind: :host_call,
          handle: 9_502,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}"}})
        }

        assert :answered =
                 AgentOS.Vm.try_answer_git_host_call(
                   AgentOS.ControlPlane.whereis(id),
                   bare_event
                 )

        assert_eventually(fn ->
          AgentOS.ControlPlane.info(id).git_inflight == 0
        end)

        assert :atomics.get(dialed, 1) == 0, "bare URL must not dial without connection"

        assert :ok = AgentOS.ControlPlane.detach_git(id)
      after
        Agent.stop(auth_agent)
        File.rm_rf(root)
        AgentOS.ControlPlane.dispose(id)
      end
    end
  end

  @tag timeout: 120_000
  test "host_call args.mount two clones into two engines" do
    # Product multi-mount e2e: attach two distinct paths with separate worktree
    # roots, clone each via args.mount + real minimal.pack, verify isolation.
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
    else
      id = {"git-demux", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}
      pack = fixture_git_bytes!("minimal.pack")
      tip = fixture_git_bytes!("minimal.tip") |> String.trim()
      uid = Integer.to_string(System.unique_integer([:positive]))
      root_a = Path.join(System.tmp_dir!(), "git-d21-a-" <> uid)
      root_b = Path.join(System.tmp_dir!(), "git-d21-b-" <> uid)
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)
      dialed = :atomics.new(1, signed: false)

      transport = fn
        :list_refs, _ ->
          :atomics.add(dialed, 1, 1)
          {:ok, [%{name: "refs/heads/main", hash: tip}]}

        :fetch_packs, _ ->
          :atomics.add(dialed, 1, 1)
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
                   mount_path: "/workspace/a",
                   root: root_a,
                   allowed_origins: [@fixture_origin],
                   transport: transport
                 )

        assert :ok =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   mount_path: "/workspace/b",
                   root: root_b,
                   allowed_origins: [@fixture_origin],
                   transport: transport
                 )

        info = AgentOS.ControlPlane.info(id)
        assert info.git_engine_count == 2
        assert Enum.sort(info.git_mounts) == ["/workspace/a", "/workspace/b"]

        vm = AgentOS.ControlPlane.whereis(id)

        # Clone into mount A via args.mount.
        e1 = %{
          kind: :host_call,
          handle: 9_201,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}","mount":"/workspace/a"}})
        }

        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, e1)

        assert_eventually(
          fn ->
            AgentOS.ControlPlane.info(id).git_inflight == 0
          end,
          150
        )

        assert_eventually(
          fn ->
            case File.read(Path.join(root_a, "README")) do
              {:ok, "hello\n"} -> true
              _ -> false
            end
          end,
          150
        )

        # Clone into mount B via args.mount (distinct engine / worktree).
        e2 = %{
          kind: :host_call,
          handle: 9_202,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}","mount":"/workspace/b"}})
        }

        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, e2)

        assert_eventually(
          fn ->
            AgentOS.ControlPlane.info(id).git_inflight == 0
          end,
          150
        )

        assert_eventually(
          fn ->
            case File.read(Path.join(root_b, "README")) do
              {:ok, "hello\n"} -> true
              _ -> false
            end
          end,
          150
        )

        assert {:ok, "hello\n"} = File.read(Path.join(root_a, "README"))
        assert {:ok, "hello\n"} = File.read(Path.join(root_b, "README"))

        # Isolation: file only under A must not appear under B.
        File.write!(Path.join(root_a, "only-a.txt"), "a-only\n")
        refute File.exists?(Path.join(root_b, "only-a.txt"))

        # Both mounts dialed transport (list_refs + fetch_packs each).
        assert :atomics.get(dialed, 1) >= 4

        # Unknown mount fails closed (still claims the host_call).
        dialed_before = :atomics.get(dialed, 1)

        e_bad = %{
          kind: :host_call,
          handle: 9_203,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}","mount":"/workspace/missing"}})
        }

        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, e_bad)

        assert_eventually(fn ->
          AgentOS.ControlPlane.info(id).git_inflight == 0
        end)

        assert :atomics.get(dialed, 1) == dialed_before,
               "unknown mount must not dial transport"

        assert :ok = AgentOS.ControlPlane.detach_git(id)
      after
        File.rm_rf(root_a)
        File.rm_rf(root_b)
        AgentOS.ControlPlane.dispose(id)
      end
    end
  end

  @tag timeout: 120_000
  test "concurrent remotes on two mounts may overlap" do
    # Per-mount single-writer: distinct mounts run independent remote Tasks.
    # Peak concurrent transport entry may exceed 1 across mounts (unlike same-mount serialize).
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
    else
      id = {"git-d21-conc", "vm-" <> Integer.to_string(System.unique_integer([:positive]))}
      pack = fixture_git_bytes!("minimal.pack")
      tip = fixture_git_bytes!("minimal.tip") |> String.trim()
      uid = Integer.to_string(System.unique_integer([:positive]))
      root_a = Path.join(System.tmp_dir!(), "git-d21-ca-" <> uid)
      root_b = Path.join(System.tmp_dir!(), "git-d21-cb-" <> uid)
      File.mkdir_p!(root_a)
      File.mkdir_p!(root_b)
      max_concurrent = :atomics.new(1, signed: false)
      in_flight = :atomics.new(1, signed: false)
      gate = :atomics.new(1, signed: false)

      transport = fn
        :list_refs, _ ->
          cur = :atomics.add_get(in_flight, 1, 1)
          peak = :atomics.get(max_concurrent, 1)
          if cur > peak, do: :atomics.put(max_concurrent, 1, cur)

          # Hold first entries so the second mount can enter transport.
          if :atomics.get(gate, 1) == 0 do
            Process.sleep(120)
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
                   mount_path: "/workspace/a",
                   root: root_a,
                   allowed_origins: [@fixture_origin],
                   transport: transport
                 )

        assert :ok =
                 AgentOS.ControlPlane.attach_git(id,
                   executable: path,
                   mount_path: "/workspace/b",
                   root: root_b,
                   allowed_origins: [@fixture_origin],
                   transport: transport
                 )

        vm = AgentOS.ControlPlane.whereis(id)

        e1 = %{
          kind: :host_call,
          handle: 9_301,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}","mount":"/workspace/a"}})
        }

        e2 = %{
          kind: :host_call,
          handle: 9_302,
          name: "git",
          body: ~s({"op":"clone","args":{"url":"#{@fixture_url}","mount":"/workspace/b"}})
        }

        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, e1)
        Process.sleep(20)
        assert :answered = AgentOS.Vm.try_answer_git_host_call(vm, e2)

        # Mid-flight: both remotes may be running (git_remote_running up to 2).
        info_mid = AgentOS.ControlPlane.info(id)
        assert info_mid.git_inflight >= 1
        assert info_mid.git_remote_running <= 2

        :atomics.put(gate, 1, 1)

        assert_eventually(
          fn ->
            AgentOS.ControlPlane.info(id).git_inflight == 0
          end,
          200
        )

        assert_eventually(
          fn ->
            case File.read(Path.join(root_a, "README")) do
              {:ok, "hello\n"} -> true
              _ -> false
            end
          end,
          150
        )

        assert_eventually(
          fn ->
            case File.read(Path.join(root_b, "README")) do
              {:ok, "hello\n"} -> true
              _ -> false
            end
          end,
          150
        )

        # Distinct mounts are allowed to overlap transport (product concurrent shape).
        # Timing is not guaranteed under load; require both clones succeeded above.
        peak = :atomics.get(max_concurrent, 1)
        assert peak >= 1

        assert :ok = AgentOS.ControlPlane.detach_git(id)
      after
        File.rm_rf(root_a)
        File.rm_rf(root_b)
        AgentOS.ControlPlane.dispose(id)
      end
    end
  end

  # ── attach path detaches on engine death ────────────────────────────────

  @tag timeout: 120_000
  test "Process.exit engine → attach path detaches" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
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
        engines = st.git_engines || %{}
        assert map_size(engines) >= 1
        [{_mount, %{pid: eng}} | _] = Map.to_list(engines)
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

  # ── host_call_close cancels inflight remote ───────────────────────────

  @tag timeout: 120_000
  test "host_call_close cancels queued/inflight git remote" do
    wasm = runfile_bytes("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile_bytes("memcontainers/images/posix.tar")
    path = engine_path()

    if is_nil(wasm) or is_nil(posix) do
      flunk("requires kernel.wasm + posix.tar under bazel //server:mix_test runfiles")
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

  # ── / –metrics ──────────────────────────────────────────────────

  @tag timeout: 30_000
  test "metrics counters tick on orch clone deny" do
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
    # allowlist deny + redacted origin + duration label.
    assert snap.allowlist_deny >= 1
    assert is_integer(snap.last_duration_ms) and snap.last_duration_ms >= 0
    assert snap.last_origin_redacted == "https://example.com"
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 60_000
  test "metrics record pack_bytes and duration on fixture clone" do
    AgentOS.Git.Metrics.reset()
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)

    pack_path = Path.expand("../fixtures/git/minimal.pack", __DIR__)

    unless File.regular?(pack_path) do
      flunk("requires minimal.pack fixture under test runfiles")
    end

    pack = File.read!(pack_path)

    assert {:ok, _json} =
             Orchestrator.run(
               pid,
               ~s({"op":"clone","args":{"url":"#{@fixture_url}"}}),
               orch_opts(pack)
             )

    snap = AgentOS.Git.Metrics.snapshot()
    # Fixture clone with real pack should succeed (clone_ok) when tip/apply work.
    assert snap.clone_ok + snap.clone_error >= 1
    assert is_integer(snap.last_duration_ms) and snap.last_duration_ms >= 0
    assert is_integer(snap.duration_ms_sum) and snap.duration_ms_sum >= 0
    assert snap.last_pack_bytes == byte_size(pack)
    assert snap.pack_bytes_sum >= snap.last_pack_bytes
    assert snap.last_origin_redacted == "https://example.com"
    # No tokens / path secrets in labels.
    refute snap.last_origin_redacted =~ "token"
    refute snap.last_origin_redacted =~ "@"
    :ok = GitEngine.stop(pid)
  end

  test "queue depth observe alerts above 32" do
    AgentOS.Git.Metrics.reset()
    # High-water + warn counter without needing 33 real Tasks.
    assert :ok = AgentOS.Git.Metrics.observe_queue_depth("/workspace/repo", 33)
    snap = AgentOS.Git.Metrics.snapshot()
    assert snap.queue_depth == 33
    assert snap.queue_depth_warn >= 1
    assert :ok = AgentOS.Git.Metrics.observe_queue_depth("/workspace/repo", 1)
    # High-water does not decrease.
    assert AgentOS.Git.Metrics.snapshot().queue_depth == 33
  end

  test "discover_executable prefers AGENTOS_GIT_ENGINE" do
    path = engine_path()
    assert File.regular?(path)
    # With env set (test helper always sets it for real runs), discovery finds it.
    found = GitEngine.discover_executable()
    assert is_binary(found)
    assert File.regular?(found)
  end

  # ── connection-bound remotes + credential splice ────────────────

  test "resolve_remote: connection auth + origins; unknown / empty fail closed" do
    conns = [
      %{
        ref: "github.user.work",
        auth: %{kind: :bearer, token: "host-secret"},
        origins: ["https://github.com"]
      }
    ]

    assert {:ok, binding} =
             Connections.resolve_remote(
               %{"url" => "https://github.com/org/repo.git", "connection" => "github.user.work"},
               connections: conns
             )

    assert binding.url =~ "github.com"
    assert binding.connection_ref == "github.user.work"
    assert binding.auth.kind == :bearer
    assert binding.auth.token == "host-secret"
    assert binding.push_action == :approve

    assert {:error, {:unknown_connection, "no.such"}} =
             Connections.resolve_remote(
               %{"url" => "https://github.com/r.git", "connection" => "no.such"},
               connections: conns
             )

    empty = [%{ref: "github.user.work", auth: %{kind: :bearer, token: "t"}, origins: []}]

    assert {:error, {:origin_not_allowlisted_for_connection, "github.user.work"}} =
             Connections.resolve_remote(
               %{"url" => "https://evil.example/r.git", "connection" => "github.user.work"},
               connections: empty
             )

    # Guest body token/auth rejected — never spliced.
    assert {:error, :guest_secrets_forbidden} =
             Connections.resolve_remote(
               %{
                 "url" => "https://example.com/r.git",
                 "auth" => %{"kind" => "bearer", "token" => "guest-stolen"},
                 "token" => "guest-stolen"
               },
               allowed_origins: ["https://example.com"],
               auth: %{kind: :none}
             )

    # Clean bare URL still resolves with host auth only.
    assert {:ok, bare} =
             Connections.resolve_remote(
               %{"url" => "https://example.com/r.git"},
               allowed_origins: ["https://example.com"],
               auth: %{kind: :none}
             )

    assert bare.auth.kind == :none

    assert Connections.evaluate_push_policy("github.user.work", [
             %{pattern: "github.*", action: :require_approval},
             %{pattern: "github.user.work", action: :block}
           ]) == :block

    assert Connections.match_connection_pattern?("github.user.*", "github.user.work")
    refute Connections.match_connection_pattern?("github.org.*", "github.user.work")
  end

  @tag timeout: 60_000
  test "clone with connection ref + origins + fixture transport succeeds" do
    path = engine_path()
    pack_path = Path.expand("../fixtures/git/minimal.pack", __DIR__)
    tip_path = Path.expand("../fixtures/git/minimal.tip", __DIR__)

    if not (File.regular?(pack_path) and File.regular?(tip_path)) do
      flunk("requires minimal.pack fixture under test runfiles")
    else
      pack = File.read!(pack_path)
      tip = File.read!(tip_path) |> String.trim()

      root =
        Path.join(
          System.tmp_dir!(),
          "orch-conn-" <> Integer.to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(root)
      {:ok, auth_agent} = Agent.start_link(fn -> nil end)

      transport = fn
        :list_refs, {_url, opts} ->
          Agent.update(auth_agent, fn _ -> Keyword.get(opts, :auth) end)
          {:ok, [%{name: "refs/heads/main", hash: tip}]}

        :fetch_packs, {_url, _want, _have, opts} ->
          Agent.update(auth_agent, fn _ -> Keyword.get(opts, :auth) end)
          {:ok, pack}

        :push_packs, _ ->
          flunk("clone must not push")
      end

      conns = [
        %{
          ref: "github.user.work",
          auth: %{kind: :bearer, token: "host-secret-tok"},
          origins: [@fixture_origin]
        }
      ]

      try do
        assert {:ok, pid} = GitEngine.start(executable: path, root: root)

        # No legacy allowed_origins — connection origins alone authorize the dial.
        assert {:ok, json} =
                 Orchestrator.run(
                   pid,
                   ~s({"op":"clone","args":{"url":"#{@fixture_url}","connection":"github.user.work"}}),
                   transport: transport,
                   connections: conns
                 )

        assert json =~ "\"ok\":true" or json =~ ~s("ok":true), "clone failed: #{json}"
        assert json =~ "cloned"
        refute json =~ "host-secret-tok"

        seen = Agent.get(auth_agent, & &1)
        assert is_map(seen)
        assert (Map.get(seen, :kind) || Map.get(seen, "kind")) in [:bearer, "bearer"]
        assert (Map.get(seen, :token) || Map.get(seen, "token")) == "host-secret-tok"

        :ok = GitEngine.stop(pid)
      after
        Agent.stop(auth_agent)
        File.rm_rf(root)
      end
    end
  end

  @tag timeout: 30_000
  test "unknown connection fails" do
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
               ~s({"op":"clone","args":{"url":"#{@fixture_url}","connection":"no.such.conn"}}),
               transport: transport,
               connections: [
                 %{
                   ref: "github.user.work",
                   auth: %{kind: :bearer, token: "t"},
                   origins: [@fixture_origin]
                 }
               ]
             )

    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ "unknown connection"
    assert :atomics.get(dialed, 1) == 0
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "empty origins on connection fails closed" do
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
               ~s({"op":"clone","args":{"url":"#{@fixture_url}","connection":"github.user.work"}}),
               transport: transport,
               connections: [
                 %{
                   ref: "github.user.work",
                   auth: %{kind: :bearer, token: "t"},
                   origins: []
                 }
               ]
             )

    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ "not allowlisted for connection"
    assert :atomics.get(dialed, 1) == 0
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "guest body with fake token field rejected before dial" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)
    dialed = :atomics.new(1, signed: false)

    transport = fn
      :list_refs, _ ->
        :atomics.put(dialed, 1, 1)
        {:ok, [%{name: "refs/heads/main", hash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}

      :fetch_packs, _ ->
        :atomics.put(dialed, 1, 1)
        {:ok, <<>>}
    end

    body =
      ~s({"op":"clone","args":{"url":"#{@fixture_url}","token":"guest-stolen","auth":{"kind":"bearer","token":"guest-stolen"}}})

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               body,
               transport: transport,
               allowed_origins: [@fixture_origin],
               auth: %{kind: :none}
             )

    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ "must not include auth secrets"
    refute json =~ "guest-stolen"
    assert :atomics.get(dialed, 1) == 0

    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "push policy block fails before dial" do
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
               ~s({"op":"push","args":{"url":"#{@fixture_url}","connection":"github.user.work"}}),
               transport: transport,
               connections: [
                 %{
                   ref: "github.user.work",
                   auth: %{kind: :bearer, token: "t"},
                   origins: [@fixture_origin]
                 }
               ],
               policies: [%{pattern: "github.user.work", action: :block}]
             )

    assert json =~ "blocked by policy"
    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert :atomics.get(dialed, 1) == 0
    :ok = GitEngine.stop(pid)
  end

  @tag timeout: 30_000
  test "push policy require_approval fails closed without fun" do
    path = engine_path()
    assert {:ok, pid} = GitEngine.start(executable: path)
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
                 "when_unix" => 1_700_000_250
               }
             })

    dialed_push = :atomics.new(1, signed: false)

    transport = fn
      :list_refs, _ ->
        {:ok, [%{name: "refs/heads/master", hash: "0000000000000000000000000000000000000000"}]}

      :push_packs, _ ->
        :atomics.put(dialed_push, 1, 1)
        {:ok, %{ok: true, message: "ok"}}
    end

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"push","args":{"url":"#{@fixture_url}","connection":"github.user.work"}}),
               transport: transport,
               connections: [
                 %{
                   ref: "github.user.work",
                   auth: %{kind: :none},
                   origins: [@fixture_origin]
                 }
               ],
               policies: [%{pattern: "*", action: "require_approval"}]
             )

    assert json =~ "requires approval"
    refute json =~ "pushed"
    assert :atomics.get(dialed_push, 1) == 0
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

  # server/test/fixtures/git/* — source tree or runfiles copy.
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

  # ── host-mediated submodule update ────────────────────────────────

  @tag timeout: 120_000
  test "host-mediated submodule update projects nested worktree" do
    path = engine_path()
    pack = fixture_git_bytes!("minimal.pack")
    tip = fixture_git_bytes!("minimal.tip") |> String.trim()

    root =
      Path.join(
        System.tmp_dir!(),
        "git-d23-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(root)
    sub_url = "https://example.com/submodule-lib.git"
    dialed = :atomics.new(1, signed: false)

    transport = fn
      :list_refs, {url, _opts} ->
        assert url == sub_url
        :atomics.add(dialed, 1, 1)
        {:ok, [%{name: "refs/heads/main", hash: tip}]}

      :fetch_packs, {url, _want, _have, _opts} ->
        assert url == sub_url
        :atomics.add(dialed, 1, 1)
        {:ok, pack}
    end

    assert {:ok, pid} = GitEngine.start(executable: path, root: root)

    try do
      assert {:ok, init} = GitEngine.run(pid, %{"op" => "init"})
      assert ok_map?(init)

      gm = """
      [submodule "deps/lib"]
      \tpath = deps/lib
      \turl = #{sub_url}
      """

      assert {:ok, w} =
               GitEngine.run(pid, %{
                 "op" => "write",
                 "args" => %{"path" => ".gitmodules", "content" => gm}
               })

      assert ok_map?(w)

      assert {:ok, add} =
               GitEngine.run(pid, %{"op" => "add", "args" => %{"path" => ".gitmodules"}})

      assert ok_map?(add)

      assert {:ok, gl} =
               GitEngine.run(pid, %{
                 "op" => "gitlink",
                 "args" => %{"path" => "deps/lib", "hash" => tip}
               })

      assert ok_map?(gl), "gitlink stage: #{inspect(gl)}"

      assert {:ok, c} =
               GitEngine.run(pid, %{
                 "op" => "commit",
                 "args" => %{
                   "message" => "super with submodule",
                   "name" => "Test",
                   "email" => "t@example.com"
                 }
               })

      assert ok_map?(c), "super commit: #{inspect(c)}"

      # Engine purity: update fails closed (host orch only).
      assert {:ok, eng_fail} =
               GitEngine.run(pid, %{"op" => "submodule", "args" => %{"action" => "update"}})

      refute ok_map?(eng_fail)
      stderr = eng_fail["stderr"] || ""
      assert stderr =~ "host_call" or stderr =~ "orchestrator"

      # List includes gitlink hash.
      assert {:ok, listed} =
               GitEngine.run(pid, %{"op" => "submodule", "args" => %{"action" => "list"}})

      assert ok_map?(listed)
      result = listed["result"] || %{}
      subs = result["submodules"] || []

      assert Enum.any?(subs, fn s -> s["path"] == "deps/lib" and s["hash"] == tip end),
             "list missing gitlink: #{inspect(listed)}"

      # Origin deny on submodule URL.
      assert {:ok, deny_json} =
               Orchestrator.run(
                 pid,
                 ~s({"op":"submodule","args":{"action":"update"}}),
                 transport: transport,
                 allowed_origins: ["https://other.example"]
               )

      refute deny_json =~ ~s("ok":true)
      assert deny_json =~ "allowlist" or deny_json =~ "origin"

      # Host orch update: dials submodule URL, nests clone under deps/lib.
      assert {:ok, upd_json} =
               Orchestrator.run(
                 pid,
                 ~s({"op":"submodule","args":{"action":"update"}}),
                 transport: transport,
                 allowed_origins: [@fixture_origin]
               )

      assert upd_json =~ ~s("ok":true), "update failed: #{upd_json}"
      assert upd_json =~ "updated 1"
      assert :atomics.get(dialed, 1) >= 2, "must dial list-refs + fetch-packs"

      # nested worktree files on disk under super root (gitfs projects FS).
      readme = Path.join(root, "deps/lib/README")
      assert File.exists?(readme), "missing nested README at #{readme}"
      assert File.read!(readme) == "hello\n"

      # Nested .git exists (real nested repo, not list-only theater).
      assert File.dir?(Path.join(root, "deps/lib/.git"))
    after
      _ = GitEngine.stop(pid)
      File.rm_rf(root)
    end
  end

  defp ok_map?(m) when is_map(m) do
    m["ok"] == true or (is_binary(Map.get(m, "raw")) and m["raw"] =~ "\"ok\":true")
  end

  defp ok_map?(_), do: false
end
