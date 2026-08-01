defmodule AgentOS.Git.OrchGoldenTest do
  @moduledoc """
  P2.8 — executable K20 orch goldens shared with TS.

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
    "fetch_success_steps.json",
    "pull_ff_steps.json",
    "push_readonly.json"
  ]

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

  defp orch_dirs do
    rf = System.get_env("RUNFILES_DIR") || System.get_env("TEST_SRCDIR")

    [
      # Fixture copy (always present for mix test)
      Path.expand("../fixtures/git/orch", __DIR__),
      # SSoT under worktree (dev / when cwd is monorepo root)
      Path.expand("../../../memcontainers/lib/git-engine/testdata/orch", __DIR__),
      Path.expand("memcontainers/lib/git-engine/testdata/orch", File.cwd!()),
      rf && Path.join(rf, "memcontainers/lib/git-engine/testdata/orch"),
      rf && Path.join(rf, "_main/memcontainers/lib/git-engine/testdata/orch")
    ]
    |> Enum.reject(&is_nil/1)
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

    assert {:ok, json} =
             Orchestrator.run(pid, req,
               transport: fixture_transport(refs, pack),
               allowed_origins: origins,
               read_only: read_only
             )

    resp = decode_json!(json)
    ok? = Map.get(resp, "ok") == true or Map.get(resp, "ok") == "true"
    expected_ok = Map.fetch!(expect, "ok")
    assert ok? == expected_ok, "#{Map.get(step, "id")}: ok expected #{expected_ok}, body=#{json}"

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
          "orch-golden-" <> Integer.to_string(System.unique_integer([:positive]))
        )

      File.mkdir_p!(root)
      assert {:ok, pid} = GitEngine.start(executable: engine_path(), root: root)

      try do
        Enum.each(exec, fn step -> run_response_step(pid, path, golden, step) end)
      after
        GitEngine.stop(pid)
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
end
