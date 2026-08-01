defmodule AgentOS.Git.OrchGoldenTest do
  @moduledoc """
  executable dual-host orch goldens shared with TS.

  Loads the same logical vectors as
  `memcontainers/lib/git-engine/testdata/orch/*.json`
  (fixture copies under `test/fixtures/git/orch/` for mix).
  """
  use ExUnit.Case, async: false

  alias AgentOS.Git.Orchestrator
  alias AgentOS.GitEngine

  @moduletag :git_engine

  @golden_names [
    "clone_success_steps.json",
    "clone_empty_pack_fail.json",
    "origin_denied.json",
    "origin_deny_prefix.json",
    "fetch_success_steps.json",
    "pull_ff_steps.json",
    "push_readonly.json",
    "push_success_steps.json",
    "shallow_clone_steps.json",
    "auth_deny_steps.json",
    "pull_not_ff_steps.json",
    "guest_secret_reject.json",
    "query_auth_reject.json"
  ]

  @response_schema "response_schema.json"
  @required_response_keys ["ok", "code", "stdout", "stderr"]

  @push_read_only "git: push rejected (read-only mount)"

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

  # Single source of truth: memcontainers/lib/git-engine/testdata/orch only.
  # Do not maintain a second copy under server/test/fixtures/git/orch.
  defp orch_dirs do
    rf = System.get_env("RUNFILES_DIR") || System.get_env("TEST_SRCDIR")
    env = System.get_env("AGENTOS_GIT_ORCH_GOLDEN_DIR")

    [
      env,
      # Runfiles (Bazel mix_test data → git-engine orch_algorithm_traces)
      rf && Path.join(rf, "memcontainers/lib/git-engine/testdata/orch"),
      rf && Path.join(rf, "_main/memcontainers/lib/git-engine/testdata/orch"),
      # Worktree relative to this test (server/test/agent_os → ../../../memcontainers/...)
      Path.expand("../../../memcontainers/lib/git-engine/testdata/orch", __DIR__),
      Path.expand("memcontainers/lib/git-engine/testdata/orch", File.cwd!()),
      # Cwd is often server/ under mix
      Path.expand("../memcontainers/lib/git-engine/testdata/orch", File.cwd!())
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.filter(&File.dir?/1)
  end

  defp find_golden!(name) do
    case Enum.find_value(orch_dirs(), fn dir ->
           path = Path.join(dir, name)
           if File.regular?(path), do: path
         end) do
      nil -> flunk("golden #{name} not found in #{inspect(orch_dirs())}")
      path -> path
    end
  end

  defp decode_json!(bin) do
    case safe_json(bin) do
      {:ok, map} when is_map(map) -> map
      _ -> flunk("invalid json")
    end
  end

  defp safe_json(bin) do
    case AgentOS.GitEngine.Jason_like.decode(bin) do
      {:ok, term} -> {:ok, term}
      _ -> :error
    end
  end

  defp load_pack(golden_path, fixture) do
    cond do
      is_binary(Map.get(fixture, "pack")) ->
        Map.get(fixture, "pack")

      is_binary(Map.get(fixture, "pack_from")) ->
        path = Path.expand(Map.get(fixture, "pack_from"), Path.dirname(golden_path))
        assert File.regular?(path), "missing pack #{path}"
        File.read!(path)

      true ->
        <<>>
    end
  end

  defp load_refs(golden_path, fixture) do
    for ref <- Map.get(fixture, "refs") || [] do
      name = Map.fetch!(ref, "name")

      hash =
        cond do
          is_binary(Map.get(ref, "hash")) and Map.get(ref, "hash") != "" ->
            Map.get(ref, "hash")

          is_binary(Map.get(ref, "hash_from")) ->
            path = Path.expand(Map.get(ref, "hash_from"), Path.dirname(golden_path))
            File.read!(path) |> String.trim()

          true ->
            flunk("ref #{name} missing hash")
        end

      %{name: name, hash: hash}
    end
  end

  defp fixture_transport(refs, pack) do
    fn
      :list_refs, {_url, _opts} -> {:ok, refs}
      :fetch_packs, {_url, _want, _have, _opts} -> {:ok, pack}
      :push_packs, {_url, _commands, _pack, _opts} -> {:ok, %{ok: true, message: "ok"}}
    end
  end

  defp run_setup(pid, fixture) do
    for step <- Map.get(fixture, "setup") || [] do
      op = Map.fetch!(step, "op")
      args = Map.get(step, "args") || %{}
      assert {:ok, _} = GitEngine.run(pid, %{"op" => op, "args" => args})
    end

    :ok
  end

  defp run_response_step(pid, golden_path, golden, step) do
    fixture = Map.fetch!(golden, "fixture")
    pack = load_pack(golden_path, fixture)
    refs = load_refs(golden_path, fixture)
    origins = Map.get(fixture, "allowed_origins") || []
    read_only = Map.get(fixture, "read_only") == true
    expect = Map.fetch!(step, "expect")

    req = %{
      "op" => Map.fetch!(step, "op"),
      "args" => Map.get(step, "args") || %{}
    }

    orch_opts = [
      transport: fixture_transport(refs, pack),
      allowed_origins: origins,
      read_only: read_only
    ]

    orch_opts =
      case Map.get(fixture, "connection") do
        %{"ref" => ref} = conn when is_binary(ref) ->
          auth = Map.get(conn, "auth") || %{}
          origins_c = Map.get(conn, "origins") || []

          Keyword.put(orch_opts, :connections, [
            %{
              ref: ref,
              auth: auth,
              origins: origins_c
            }
          ])

        _ ->
          orch_opts
      end

    assert {:ok, json} = Orchestrator.run(pid, req, orch_opts)

    resp = decode_json!(json)
    # ok must be JSON boolean true/false only (not string "true"/"false")
    ok = Map.get(resp, "ok")
    assert is_boolean(ok), "#{Map.get(step, "id")}: ok must be boolean, got #{inspect(ok)}: #{json}"
    expected_ok = Map.fetch!(expect, "ok")
    assert ok == expected_ok, "#{Map.get(step, "id")}: ok expected #{expected_ok}, body=#{json}"

    if Map.has_key?(expect, "code") do
      assert Map.get(resp, "code") == Map.get(expect, "code"),
             "code mismatch: #{json}"
    end

    stdout = to_string(Map.get(resp, "stdout") || "")
    stderr = to_string(Map.get(resp, "stderr") || "")

    for needle <- Map.get(expect, "stdout_contains") || [] do
      assert String.contains?(stdout, needle),
             "stdout missing #{inspect(needle)}: #{inspect(stdout)}"
    end

    for needle <- Map.get(expect, "stderr_contains") || [] do
      assert String.contains?(stderr, needle),
             "stderr missing #{inspect(needle)}: #{inspect(stderr)}"
    end

    for needle <- Map.get(expect, "stdout_not_contains") || [] do
      refute String.contains?(stdout, needle),
             "stdout must not contain #{inspect(needle)}: #{inspect(stdout)}"
    end

    for needle <- Map.get(expect, "stderr_not_contains") || [] do
      refute String.contains?(stderr, needle),
             "stderr must not contain #{inspect(needle)}: #{inspect(stderr)}"
    end

    :ok
  end

  for name <- @golden_names do
    @tag timeout: 60_000
    test "golden #{name}" do
      name = unquote(name)
      path = find_golden!(name)
      golden = path |> File.read!() |> decode_json!()
      steps = Map.get(golden, "steps") || []
      exec = Enum.filter(steps, fn s -> Map.has_key?(s, "op") and Map.has_key?(s, "expect") end)
      assert exec != [], "#{name}: no executable step"

      root =
        Path.join(
          System.tmp_dir!(),
          "orch-golden-" <>
            Integer.to_string(System.unique_integer([:positive])) <>
            "-" <>
            Integer.to_string(System.system_time(:nanosecond))
        )

      # Durable root when :root is set — wipe leftovers so init/clone is clean.
      File.rm_rf!(root)
      File.mkdir_p!(root)
      assert {:ok, pid} = GitEngine.start(executable: engine_path(), root: root)

      try do
        fixture = Map.fetch!(golden, "fixture")
        :ok = run_setup(pid, fixture)
        Enum.each(exec, fn step -> run_response_step(pid, path, golden, step) end)
      after
        GitEngine.stop(pid)
        File.rm_rf(root)
      end
    end
  end

  # Read-only mount still rejects push (stable message).
  @tag timeout: 30_000
  test "push returns stable read-only error when read_only" do
    assert {:ok, pid} = GitEngine.start(executable: engine_path())

    assert {:ok, json} =
             Orchestrator.run(
               pid,
               ~s({"op":"push","args":{"url":"https://example.com/demo.git"}}),
               transport: fn _, _ -> flunk("push must not dial transport when read_only") end,
               allowed_origins: ["https://example.com"],
               read_only: true
             )

    assert json =~ "\"ok\":false" or json =~ ~s("ok":false)
    assert json =~ @push_read_only
    :ok = GitEngine.stop(pid)
  end

  # — Response schema catalog: required keys + stable stderr prefixes.
  @tag timeout: 60_000
  test "response_schema catalog prefixes (unknown connection, empty pack, origin deny)" do
    path = find_golden!(@response_schema)
    schema = path |> File.read!() |> decode_json!()
    keys = Map.get(schema, "required_response_keys") || []
    assert Enum.sort(keys) == Enum.sort(@required_response_keys)

    prefixes =
      for p <- Map.get(schema, "stderr_prefixes") || [], into: %{} do
        {Map.fetch!(p, "id"), Map.fetch!(p, "prefix")}
      end

    samples = Map.get(schema, "samples") || []
    assert length(samples) >= 3

    assert {:ok, pid} = GitEngine.start(executable: engine_path())

    try do
      for sample <- samples do
        id = Map.fetch!(sample, "id")
        op = Map.fetch!(sample, "op")
        args = Map.get(sample, "args") || %{}
        origins = Map.get(sample, "allowed_origins") || []
        prefix_id = Map.fetch!(sample, "expect_prefix_id")
        want = Map.fetch!(prefixes, prefix_id)

        fixture = Map.get(sample, "fixture") || %{}
        refs =
          for r <- Map.get(fixture, "refs") || [] do
            %{name: Map.fetch!(r, "name"), hash: Map.fetch!(r, "hash")}
          end

        pack =
          case Map.get(fixture, "pack") do
            p when is_binary(p) -> p
            _ -> <<>>
          end

        connections =
          case Map.get(sample, "connections") do
            list when is_list(list) -> list
            _ -> []
          end

        transport = fixture_transport(refs, pack)

        assert {:ok, json} =
                 Orchestrator.run(
                   pid,
                   %{"op" => op, "args" => args},
                   transport: transport,
                   allowed_origins: origins,
                   connections: connections
                 )

        resp = decode_json!(json)

        for k <- @required_response_keys do
          assert Map.has_key?(resp, k), "schema/#{id}: missing key #{k}: #{json}"
        end

        # ok must be JSON boolean true/false only (not string "true"/"false")
        ok = Map.get(resp, "ok")
        assert is_boolean(ok), "schema/#{id}: ok must be boolean, got #{inspect(ok)}: #{json}"
        refute ok, "schema/#{id}: expected ok:false: #{json}"

        stderr = to_string(Map.get(resp, "stderr") || "")
        assert String.contains?(stderr, want),
               "schema/#{id}: stderr missing prefix #{inspect(want)}: #{inspect(stderr)}"
      end
    after
      GitEngine.stop(pid)
    end
  end
end
