defmodule AgentOS.GitEngineTest do
  use ExUnit.Case, async: false

  alias AgentOS.Contracts.Git
  alias AgentOS.GitEngine

  @moduletag :git_engine
  @moduletag timeout: 60_000

  test "native Port executes generated local repository contract" do
    root = temp_root("typed")

    try do
      assert {:ok, pid} = GitEngine.start(executable: engine_path(), root: root)
      assert_ok(GitEngine.request(pid, Git.op_repository_init()))

      write =
        Git.encode_file_request(%{
          path: "nested/hello.txt",
          other_path: nil,
          mode: nil,
          offset_low: nil,
          offset_high: nil,
          data: "hello from BEAM\n",
          handle: nil
        })

      assert_ok(GitEngine.request(pid, Git.op_file_write(), write))
      assert File.read!(Path.join(root, "nested/hello.txt")) == "hello from BEAM\n"

      add = porcelain(action: Git.action_update(), paths: %{"nested/hello.txt" => ""})
      assert_ok(GitEngine.request(pid, Git.op_add(), add))

      signature = %{
        name: "BEAM artifact test",
        email: "artifact@example.invalid",
        unix_seconds: 1_700_000_000,
        timezone_minutes: 0
      }

      commit =
        porcelain(action: Git.action_create(), message: "typed commit", author: signature, committer: signature)

      assert {:ok, %{status: status, payload: payload}} =
               GitEngine.request(pid, Git.op_commit(), commit)

      assert status == Git.status_ok()
      assert {:ok, %{object_id: %{bytes: object_id}}} = Git.decode_commit_result(payload)
      assert byte_size(object_id) == 20

      assert {:ok, %{status: status, payload: payload}} =
               GitEngine.request(
                 pid,
                 Git.op_resolve_revision(),
                 porcelain(action: Git.action_get(), revision: "HEAD")
               )

      assert status == Git.status_ok()
      assert {:ok, %{object_id: %{bytes: ^object_id}}} = Git.decode_resolve_result(payload)
      assert :ok = GitEngine.stop(pid)
    after
      File.rm_rf(root)
    end
  end

  test "durable placement reopens without BEAM repository reconstruction" do
    root = temp_root("durable")

    try do
      assert {:ok, first} = GitEngine.start(executable: engine_path(), root: root)
      assert_ok(GitEngine.request(first, Git.op_repository_init()))
      assert :ok = GitEngine.stop(first)

      assert {:ok, second} = GitEngine.start(executable: engine_path(), root: root)
      assert_ok(GitEngine.request(second, Git.op_repository_open()))
      assert :ok = GitEngine.stop(second)
    after
      File.rm_rf(root)
    end
  end

  test "public JSON log, diff, checkout, and reset" do
    root = temp_root("public")

    try do
      assert {:ok, pid} = GitEngine.start(executable: engine_path(), root: root)
      identity = %{name: "Public Test", email: "public@example.invalid"}

      assert_public_ok(pid, %{"op" => "init"}, identity: identity)
      assert_public_ok(pid, %{"op" => "write", "args" => %{"path" => "a.txt", "content" => "one\n"}}, identity: identity)
      assert_public_ok(pid, %{"op" => "add", "args" => %{"path" => "a.txt"}}, identity: identity)
      assert_public_ok(pid, %{"op" => "commit", "args" => %{"message" => "first"}}, identity: identity)
      assert_public_ok(pid, %{"op" => "write", "args" => %{"path" => "b.txt", "content" => "two\n"}}, identity: identity)
      assert_public_ok(pid, %{"op" => "add", "args" => %{"path" => "b.txt"}}, identity: identity)

      diff = public_ok(pid, %{"op" => "diff", "args" => %{"cached" => true}}, identity: identity)
      assert diff["stdout"] =~ "b.txt"

      assert_public_ok(pid, %{"op" => "commit", "args" => %{"message" => "second"}}, identity: identity)
      log = public_ok(pid, %{"op" => "log"}, identity: identity)
      assert log["ok"]
      assert is_binary(log["stdout"])
      assert log["stdout"] != ""

      assert_public_ok(pid, %{"op" => "reset", "args" => %{"mode" => "mixed", "rev" => "HEAD"}}, identity: identity)
      assert :ok = GitEngine.stop(pid)
    after
      File.rm_rf(root)
    end
  end

  test "public adapter rejects guest secrets and blocked pushes before the engine" do
    body =
      AgentOS.Git.Json.encode(%{
        "op" => "clone",
        "args" => %{"url" => "https://example.com/r.git", "token" => "secret"}
      })

    assert {:ok, json} = AgentOS.Git.Public.call(self(), body, [])
    assert {:ok, %{"ok" => false, "stderr" => stderr}} = AgentOS.Git.Json.decode(json)
    assert stderr =~ "credential material"

    nested =
      AgentOS.Git.Json.encode(%{
        "op" => "push",
        "args" => %{
          "url" => "https://example.com/r.git",
          "refspecs" => ["refs/heads/main:refs/heads/main"],
          "extra" => [%{"password" => "x"}]
        }
      })

    assert {:ok, nested_json} = AgentOS.Git.Public.call(self(), nested, [])
    assert {:ok, %{"ok" => false, "stderr" => nested_stderr}} = AgentOS.Git.Json.decode(nested_json)
    assert nested_stderr =~ "credential material"

    push =
      AgentOS.Git.Json.encode(%{
        "op" => "push",
        "args" => %{
          "url" => "https://example.com/r.git",
          "refspecs" => ["refs/heads/main:refs/heads/main"]
        }
      })

    assert {:ok, blocked} =
             AgentOS.Git.Public.call(self(), push,
               allowed_origins: ["https://example.com"],
               policies: [%{pattern: "*", action: :block}]
             )

    assert {:ok, %{"ok" => false, "stderr" => blocked_stderr}} = AgentOS.Git.Json.decode(blocked)
    assert blocked_stderr =~ "blocked by policy"

    assert {:ok, need_approval} =
             AgentOS.Git.Public.call(self(), push,
               allowed_origins: ["https://example.com"],
               policies: [%{pattern: "*", action: "require_approval"}]
             )

    assert {:ok, %{"ok" => false, "stderr" => approval_stderr}} =
             AgentOS.Git.Json.decode(need_approval)

    assert approval_stderr =~ "approval is required"

    assert :block =
             AgentOS.Git.Public.evaluate_push_policy("github.user.work", [
               %{pattern: "github.*", action: :require_approval},
               %{pattern: "*", action: :block}
             ])

    assert :block = AgentOS.Git.Public.evaluate_push_policy("*", :not_a_list)
    assert :block = AgentOS.Git.Public.evaluate_push_policy("*", [%{pattern: "*", action: "deny"}])

    assert {:ok, unknown} =
             AgentOS.Git.Public.call(self(), push,
               allowed_origins: ["https://example.com"],
               policies: [%{pattern: "*", action: "Block"}]
             )

    assert {:ok, %{"ok" => false, "stderr" => unknown_stderr}} = AgentOS.Git.Json.decode(unknown)
    assert unknown_stderr =~ "blocked by policy"
  end

  test "public remotes bind credentials to the guest connection ref" do
    github = %{
      ref: "github.user.work",
      origins: ["https://github.com"],
      auth: %{kind: :bearer, token: "gh-token"}
    }

    gitlab = %{
      ref: "gitlab.user.work",
      origins: ["https://gitlab.com"],
      auth: %{kind: :bearer, token: "gl-token"}
    }

    assert {:error, :origin_not_allowed} =
             AgentOS.Git.Transport.resolve_remote(
               %{"url" => "https://github.com/org/private.git"},
               connections: [github]
             )

    assert {:ok, %{auth: %{token: "gh-token"}, connection_ref: "github.user.work"}} =
             AgentOS.Git.Transport.resolve_remote(
               %{"url" => "https://github.com/org/private.git", "connection" => "github.user.work"},
               connections: [github, gitlab]
             )

    assert {:error, :origin_not_allowed} =
             AgentOS.Git.Transport.resolve_remote(
               %{"url" => "https://github.com/org/private.git", "connection" => "gitlab.user.work"},
               connections: [github, gitlab]
             )

    assert {:error, :unknown_connection} =
             AgentOS.Git.Transport.resolve_remote(
               %{"url" => "https://github.com/org/private.git", "connection" => "missing"},
               connections: [github]
             )

    body =
      AgentOS.Git.Json.encode(%{
        "op" => "clone",
        "args" => %{"url" => "https://github.com/org/private.git"}
      })

    assert {:ok, json} = AgentOS.Git.Public.call(self(), body, connections: [github])
    assert {:ok, %{"ok" => false, "stderr" => stderr}} = AgentOS.Git.Json.decode(json)
    assert stderr =~ "origin_not_allowlisted"
  end

  test "HTTP transport rejects unallowlisted origins and credentials in URLs" do
    assert {:error, :origin_not_allowed} =
             AgentOS.Git.Transport.ensure_url_allowed("https://example.com/repo.git", [])

    assert {:error, :bad_remote_url} =
             AgentOS.Git.Transport.ensure_url_allowed(
               "https://user:secret@example.com/repo.git",
               allowed_origins: ["https://example.com"]
             )

    assert {:ok, "https://example.com"} =
             AgentOS.Git.Transport.ensure_url_allowed(
               "https://EXAMPLE.com/repo.git",
               allowed_origins: ["https://example.com:443"]
             )
  end

  defp porcelain(overrides) do
    defaults = %{
      action: Git.action_get(),
      flags: 0,
      revision: nil,
      target: nil,
      message: nil,
      paths: %{},
      limit: nil,
      cursor: nil,
      author: nil,
      committer: nil
    }

    defaults |> Map.merge(Map.new(overrides)) |> Git.encode_porcelain_request()
  end

  defp assert_ok({:ok, %{status: status}}), do: assert(status == Git.status_ok())

  defp assert_public_ok(pid, request, opts) do
    assert %{"ok" => true} = public_ok(pid, request, opts)
  end

  defp public_ok(pid, request, opts) do
    assert {:ok, json} = AgentOS.Git.Public.call(pid, AgentOS.Git.Json.encode(request), opts)
    assert {:ok, %{"ok" => true} = decoded} = AgentOS.Git.Json.decode(json), json
    decoded
  end

  defp temp_root(label) do
    Path.join(
      System.tmp_dir!(),
      "agentos-gitz-#{label}-#{System.unique_integer([:positive])}"
    )
  end

  defp engine_path do
    System.get_env("AGENTOS_GIT_ENGINE") ||
      Path.expand("../memcontainers/lib/git-engine/git-engine", File.cwd!())
  end
end
