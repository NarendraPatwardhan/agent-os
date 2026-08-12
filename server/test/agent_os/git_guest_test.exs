defmodule AgentOS.GitGuestTest do
  @moduledoc """
  Guest `/bin/git` must exec: argv→JSON plus one real VM invocation of the binary.
  """
  use ExUnit.Case, async: false

  alias AgentOS.ControlPlane

  @moduletag :git_engine
  @moduletag timeout: 180_000
  @url "https://git.test/repo.git"

  test "guest /bin/git execs porcelain and a host-mediated clone" do
    wasm = runfile!("memcontainers/kernel/rust/kernel.wasm")
    loom = runfile!("memcontainers/images/loom.tar")
    fixture = temp("guest-cgi")
    root = temp("guest-repo")
    clone_root = temp("guest-clone")
    id = unique_id("guest-git")
    clone_id = unique_id("guest-clone")
    bare = Path.join(fixture, "repo.git")
    seed = Path.join(fixture, "seed")

    try do
      File.mkdir_p!(fixture)
      git!(["init", "--bare", bare])
      git!(["init", seed])
      File.write!(Path.join(seed, "README"), "hello-guest\n")
      git!(["-C", seed, "add", "README"])
      git!(["-C", seed, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "seed"])
      git!(["-C", seed, "branch", "-M", "main"])
      git!(["-C", seed, "remote", "add", "origin", bare])
      git!(["-C", seed, "push", "origin", "main:main"])
      git!(["--git-dir", bare, "symbolic-ref", "HEAD", "refs/heads/main"])

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
                 executable: engine_path(),
                 root: root,
                 allowed_origins: ["https://git.test"],
                 http_effect: cgi_effect(fixture),
                 identity: %{name: "Guest", email: "guest@example.invalid"}
               )

      assert {:ok, ver} = ControlPlane.run(id, "git", ["version"], timeout: 30_000)
      assert ver.exit_code == 0, inspect(ver)
      assert ver.stdout =~ "agentos-git"

      assert {:ok, init} = ControlPlane.run(id, "git", ["init"], timeout: 60_000)
      assert init.exit_code == 0, inspect(init)

      assert :ok = File.write(Path.join(root, "hello.txt"), "from-guest\n")

      assert {:ok, add} = ControlPlane.run(id, "git", ["add", "hello.txt"], timeout: 60_000)
      assert add.exit_code == 0, inspect(add)

      assert {:ok, commit} =
               ControlPlane.run(id, "git", ["commit", "-m", "guest-commit"], timeout: 60_000)

      assert commit.exit_code == 0, inspect(commit)

      assert {:ok, status} = ControlPlane.run(id, "git", ["status"], timeout: 60_000)
      assert status.exit_code == 0, inspect(status)

      assert {:ok, _pid} =
               ControlPlane.create(clone_id,
                 wasm: wasm,
                 base_image: loom,
                 deterministic: true,
                 workers: 0,
                 host_call: :relay
               )

      assert :ok =
               ControlPlane.attach_git(clone_id,
                 executable: engine_path(),
                 root: clone_root,
                 allowed_origins: ["https://git.test"],
                 http_effect: cgi_effect(fixture),
                 identity: %{name: "Guest", email: "guest@example.invalid"}
               )

      assert {:ok, clone} =
               ControlPlane.run(clone_id, "git", ["clone", "--depth", "1", @url], timeout: 120_000)

      assert clone.exit_code == 0, inspect(clone)
      assert File.read!(Path.join(clone_root, "README")) == "hello-guest\n"
    after
      _ = ControlPlane.dispose(id)
      _ = ControlPlane.dispose(clone_id)
      File.rm_rf(fixture)
      File.rm_rf(root)
      File.rm_rf(clone_root)
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
        ["Status", value] ->
          {value |> String.trim() |> String.split(" ") |> hd() |> String.to_integer(), headers}

        [name, value] ->
          {status, Map.put(headers, String.downcase(name), String.trim(value))}

        _ ->
          {status, headers}
      end
    end)
  end

  defp git!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "git fixture command failed (#{code}): #{out}"
    end
  end

  defp unique_id(prefix),
    do: {"git-guest", "#{prefix}-#{System.unique_integer([:positive])}"}

  defp temp(label),
    do: Path.join(System.tmp_dir!(), "agentos-gitz-#{label}-#{System.unique_integer([:positive])}")

  defp engine_path do
    System.get_env("AGENTOS_GIT_ENGINE") ||
      Path.expand("../memcontainers/lib/git-engine/git-engine", File.cwd!())
  end

  defp runfile!(path) do
    roots =
      [
        System.get_env("TEST_SRCDIR") && System.get_env("TEST_WORKSPACE") &&
          Path.join([System.fetch_env!("TEST_SRCDIR"), System.fetch_env!("TEST_WORKSPACE")]),
        System.get_env("TEST_SRCDIR") && Path.join(System.fetch_env!("TEST_SRCDIR"), "_main"),
        Path.expand("..", File.cwd!())
      ]
      |> Enum.reject(&is_nil/1)

    case Enum.find_value(roots, fn root ->
           candidate = Path.join(root, path)
           if File.exists?(candidate), do: candidate
         end) do
      nil -> flunk("runfile not found: #{path}")
      file -> File.read!(file)
    end
  end
end
