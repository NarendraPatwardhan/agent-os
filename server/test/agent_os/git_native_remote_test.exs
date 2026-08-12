defmodule AgentOS.GitNativeRemoteTest do
  use ExUnit.Case, async: false

  alias AgentOS.Git.{Json, Public}
  alias AgentOS.GitEngine

  @moduletag :git_engine
  @moduletag timeout: 180_000
  @url "https://git.test/repo.git"

  test "public JSON clone, local commit, push, and fresh clone use native Gitz" do
    fixture = temp("cgi")
    first = temp("first")
    second = temp("second")
    bare = Path.join(fixture, "repo.git")
    seed = Path.join(fixture, "seed")
    sub_bare = Path.join(fixture, "sub.git")
    sub_seed = Path.join(fixture, "sub-seed")

    try do
      File.mkdir_p!(fixture)
      git!(["init", "--bare", sub_bare])
      git!(["init", sub_seed])
      File.write!(Path.join(sub_seed, "SUBMODULE"), "nested native\n")
      git!(["-C", sub_seed, "add", "SUBMODULE"])
      git!(["-C", sub_seed, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "submodule seed"])
      git!(["-C", sub_seed, "branch", "-M", "main"])
      git!(["-C", sub_seed, "remote", "add", "origin", sub_bare])
      git!(["-C", sub_seed, "push", "origin", "main:main"])
      git!(["--git-dir", sub_bare, "symbolic-ref", "HEAD", "refs/heads/main"])
      sub_tip = head(sub_seed)

      git!(["init", "--bare", bare])
      git!(["--git-dir", bare, "config", "http.receivepack", "true"])
      git!(["init", seed])
      File.write!(Path.join(seed, "README"), "seed\n")
      File.write!(Path.join(seed, ".gitignore"), "*.tmp\n")
      git!(["-C", seed, "add", "README", ".gitignore"])
      git!(["-C", seed, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "base"])
      File.write!(Path.join(seed, ".gitmodules"), "[submodule \"deps/lib\"]\n\tpath = deps/lib\n\turl = https://git.test/sub.git\n")
      git!(["-C", seed, "add", ".gitmodules"])
      git!(["-C", seed, "update-index", "--add", "--cacheinfo", "160000,#{sub_tip},deps/lib"])
      git!(["-C", seed, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "add submodule"])
      git!(["-C", seed, "branch", "-M", "main"])
      git!(["-C", seed, "remote", "add", "origin", bare])
      git!(["-C", seed, "push", "origin", "main:main"])
      git!(["--git-dir", bare, "symbolic-ref", "HEAD", "refs/heads/main"])

      effect = cgi_effect(fixture)
      identity = %{name: "Native acceptance", email: "native@example.invalid"}

      assert {:ok, one} = GitEngine.start(executable: engine_path(), root: first)
      remote_opts = [http_effect: effect, identity: identity, allowed_origins: ["https://git.test"]]

      assert_ok(Public.call(one, request("clone", %{"url" => @url, "depth" => 1}), remote_opts))
      assert File.read!(Path.join(first, "README")) == "seed\n"
      assert String.trim(git!(["-C", first, "rev-list", "--count", "HEAD"])) == "1"
      assert String.trim(git!(["-C", first, "rev-parse", "--is-shallow-repository"])) == "true"
      before = head(first)

      assert_ok(Public.call(one, request("write", %{"path" => "ignored.tmp", "content" => "ignored\n"}), identity: identity))
      ignored = call_ok(one, request("check-ignore", %{"path" => "ignored.tmp"}), remote_opts)
      assert ignored["result"]["paths"] == %{"ignored.tmp" => "*.tmp"}
      assert ignored["stdout"] == "ignored.tmp\n"

      listed = call_ok(one, request("submodule", %{"action" => "list"}), remote_opts)
      assert [%{"path" => "deps/lib", "gitlink" => ^sub_tip}] = listed["result"]["submodules"]

      initial_status = call_ok(one, request("submodule", %{"action" => "status"}), remote_opts)
      assert [%{"path" => "deps/lib", "state" => 0}] = initial_status["result"]["submodules"]

      updated = call_ok(one, request("submodule", %{"action" => "update", "path" => "deps/lib"}), remote_opts)
      assert updated["stdout"] == "updated 1 submodule(s)\n"
      assert File.read!(Path.join(first, "deps/lib/SUBMODULE")) == "nested native\n"
      assert head(Path.join(first, "deps/lib")) == sub_tip

      final_status = call_ok(one, request("submodule", %{"action" => "status"}), remote_opts)
      assert [%{"path" => "deps/lib", "state" => 1, "head" => ^sub_tip}] = final_status["result"]["submodules"]

      assert_ok(Public.call(one, request("write", %{"path" => "pushed.txt", "content" => "from native\n"}), identity: identity))
      assert_ok(Public.call(one, request("add", %{"path" => "pushed.txt"}), identity: identity))
      assert_ok(Public.call(one, request("commit", %{"message" => "native push"}), identity: identity))
      after_commit = head(first)
      refute after_commit == before

      assert_ok(Public.call(one, request("push", %{"url" => @url, "refspecs" => ["refs/heads/main:refs/heads/main"]}), remote_opts))
      assert bare_head(bare) == after_commit
      GitEngine.stop(one)

      assert {:ok, two} = GitEngine.start(executable: engine_path(), root: second)
      assert_ok(Public.call(two, request("clone", %{"url" => @url}), remote_opts))
      assert File.read!(Path.join(second, "pushed.txt")) == "from native\n"
      assert head(second) == after_commit
      GitEngine.stop(two)
    after
      File.rm_rf(fixture)
      File.rm_rf(first)
      File.rm_rf(second)
    end
  end

  defp cgi_effect(project_root) do
    fn effect, request_body, _opts ->
      uri = URI.parse(effect.path)
      env = [
        {"GIT_PROJECT_ROOT", project_root},
        {"GIT_HTTP_EXPORT_ALL", "1"},
        {"REQUEST_METHOD", effect.method},
        {"PATH_INFO", uri.path},
        {"QUERY_STRING", uri.query || ""},
        {"CONTENT_TYPE", Map.get(effect.headers, "content-type", "")},
        {"CONTENT_LENGTH", Integer.to_string(byte_size(request_body))}
      ]

      {output, 0} = cgi_command(env, request_body)
      {header_bytes, body} = split_cgi(output)
      {status, headers} = parse_cgi_headers(header_bytes)
      {:ok, %{status: status, headers: headers, body: body}}
    end
  end

  defp cgi_command(env, input) do
    request_path = temp("cgi-request")
    File.write!(request_path, input)

    try do
      System.cmd(
        "sh",
        ["-c", "exec git http-backend < \"$1\"", "agentos-git-cgi", request_path],
        env: env,
        stderr_to_stdout: false
      )
    after
      File.rm(request_path)
    end
  end

  defp split_cgi(output) do
    case :binary.split(output, "\r\n\r\n") do
      [headers, body] -> {headers, body}
      _ -> raise "invalid git-http-backend response"
    end
  end

  defp parse_cgi_headers(bytes) do
    Enum.reduce(String.split(bytes, "\r\n"), {200, %{}}, fn line, {status, headers} ->
      case String.split(line, ":", parts: 2) do
        ["Status", value] -> {value |> String.trim() |> String.split(" ") |> hd() |> String.to_integer(), headers}
        [name, value] -> {status, Map.put(headers, String.downcase(name), String.trim(value))}
        _ -> {status, headers}
      end
    end)
  end

  defp request(op, args), do: Json.encode(%{"op" => op, "args" => args})
  defp assert_ok({:ok, json}) do
    assert {:ok, %{"ok" => true}} = Json.decode(json), json
  end
  defp call_ok(pid, body, opts) do
    assert {:ok, json} = Public.call(pid, body, opts)
    assert {:ok, %{"ok" => true} = response} = Json.decode(json), json
    response
  end
  defp head(root), do: git!(["-C", root, "rev-parse", "HEAD"]) |> String.trim()
  defp bare_head(root), do: git!(["--git-dir", root, "rev-parse", "refs/heads/main"]) |> String.trim()
  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "git fixture command failed (#{code}): #{out}"
    end
  end
  defp temp(label), do: Path.join(System.tmp_dir!(), "agentos-gitz-#{label}-#{System.unique_integer([:positive])}")
  defp engine_path, do: System.get_env("AGENTOS_GIT_ENGINE") || Path.expand("../memcontainers/lib/git-engine/git-engine", File.cwd!())
end
