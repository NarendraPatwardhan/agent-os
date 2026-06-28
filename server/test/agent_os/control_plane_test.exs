defmodule AgentOS.ControlPlaneTest do
  use ExUnit.Case, async: false

  alias AgentOS.ControlPlane

  # Exercises the OTP control-plane layer (the supervision tree + registry + facade) with REAL
  # processes and no mocks (B6) — and without a kernel.wasm, by covering the addressing/error
  # paths. Booting a real VM through the facade is the end-to-end step that needs the kernel +
  # image artifacts wired as test data.

  test "the supervision tree is up: registry + dynamic supervisor are running" do
    assert is_pid(Process.whereis(AgentOS.VmRegistry))
    assert is_pid(Process.whereis(AgentOS.VmSupervisor))
    assert is_list(ControlPlane.list())
  end

  test "addressing a VM that does not exist returns :not_found, never a crash" do
    id = {"test-ns", "does-not-exist"}

    assert ControlPlane.whereis(id) == nil
    assert ControlPlane.exec(id, "ls") == {:error, :not_found}
    assert ControlPlane.send_input(id, "\n") == {:error, :not_found}
    assert ControlPlane.tick(id) == {:error, :not_found}
    assert ControlPlane.take_output(id) == {:error, :not_found}
    assert ControlPlane.exec_start(id, "sleep 10") == {:error, :not_found}
    assert ControlPlane.exec_poll(id, 1) == {:error, :not_found}
    assert ControlPlane.exec_stdout_peek(id, 1) == {:error, :not_found}
    assert ControlPlane.exec_cancel(id, 1) == {:error, :not_found}
    assert ControlPlane.snapshot(id) == {:error, :not_found}
    assert ControlPlane.commit_layer(id) == {:error, :not_found}
    assert ControlPlane.read_file(id, "/tmp/nope") == {:error, :not_found}
    assert ControlPlane.write_file(id, "/tmp/nope", "data") == {:error, :not_found}
    assert ControlPlane.readdir(id, "/tmp") == {:error, :not_found}
    assert ControlPlane.stat(id, "/tmp/nope") == {:error, :not_found}
    assert ControlPlane.mkdir(id, "/tmp/new") == {:error, :not_found}
    assert ControlPlane.unlink(id, "/tmp/nope") == {:error, :not_found}
    assert ControlPlane.symlink(id, "/tmp/a", "/tmp/b") == {:error, :not_found}
    assert ControlPlane.status(id) == {:error, :not_found}
    assert ControlPlane.egress_next(id) == {:error, :not_found}
    assert ControlPlane.egress_http_respond(id, 1, 200, "OK", [], "") == {:error, :not_found}
    assert ControlPlane.egress_http_fail(id, 1) == {:error, :not_found}
    assert ControlPlane.egress_host_call_respond(id, 1, "") == {:error, :not_found}
    assert ControlPlane.egress_host_call_fail(id, 1) == {:error, :not_found}
    assert ControlPlane.egress_persist_respond(id, 1, "") == {:error, :not_found}
    assert ControlPlane.egress_persist_fail(id, 1) == {:error, :not_found}
    assert ControlPlane.egress_ws_open(id, 1) == {:error, :not_found}
    assert ControlPlane.egress_ws_fail(id, 1) == {:error, :not_found}
    assert ControlPlane.egress_ws_push(id, 1, "") == {:error, :not_found}
    assert ControlPlane.egress_ws_close(id, 1) == {:error, :not_found}
    assert ControlPlane.info(id) == {:error, :not_found}
    assert ControlPlane.dispose(id) == {:error, :not_found}
  end

  test "failed boot returns a clean host error and leaves no registered VM" do
    id = unique_id("bad-boot")

    assert {:error, msg} = ControlPlane.create(id, wasm: <<0, 1, 2, 3>>)
    assert is_binary(msg)
    assert msg =~ "kernel.wasm"
    assert ControlPlane.whereis(id) == nil
  end

  @tag timeout: 120_000
  test "real kernel VM supports control-channel fs, async exec, snapshot restore, and commit" do
    wasm = runfile!("memcontainers/kernel/rust/kernel.wasm")
    image = runfile!("memcontainers/images/minimal.tar")
    id = unique_id("vm")
    fork_id = unique_id("fork")

    try do
      assert {:ok, pid} =
               ControlPlane.create(id,
                 wasm: wasm,
                 base_image: image,
                 deterministic: true,
                 workers: 0
               )

      assert is_pid(pid)
      assert {:ok, status} = ControlPlane.status(id)
      assert status.at_prompt
      assert status.workers == 0
      assert status.inflight_egress == 0

      assert :ok = ControlPlane.write_file(id, "/tmp/nif.txt", "hello from nif\n")
      assert {:ok, "hello from nif\n"} = ControlPlane.read_file(id, "/tmp/nif.txt")
      assert {:ok, %{type: :file, size: 15, nlink: nlink}} = ControlPlane.stat(id, "/tmp/nif.txt")
      assert nlink >= 1

      assert {:ok, entries} = ControlPlane.readdir(id, "/tmp")
      assert Enum.any?(entries, &(&1.name == "nif.txt" and &1.type == :file))

      assert {:ok, job} = ControlPlane.exec_start(id, "cat /tmp/nif.txt")
      assert {:ok, %{exit_code: 0, stdout: "hello from nif\n", stderr: ""}} =
               poll_exec(id, job, 5_000)

      assert {:ok, snapshot} = ControlPlane.snapshot(id)
      assert binary_part(snapshot, 0, 4) == "MCSN"

      assert {:ok, fork_pid} =
               ControlPlane.create(fork_id, wasm: wasm, snapshot: snapshot, deterministic: true, workers: 0)

      assert is_pid(fork_pid)
      assert {:ok, "hello from nif\n"} = ControlPlane.read_file(fork_id, "/tmp/nif.txt")

      assert {:ok, %{tar: tar, digest: "sha256:" <> hex}} = ControlPlane.commit_layer(id)
      assert byte_size(tar) > 0
      assert byte_size(hex) == 64
    after
      ControlPlane.dispose(fork_id)
      ControlPlane.dispose(id)
    end
  end

  @tag timeout: 120_000
  test "real kernel VM relays host_call and HTTP egress to the BEAM owner" do
    wasm = runfile!("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile!("memcontainers/images/posix.tar")
    id = unique_id("egress")

    try do
      assert {:ok, _pid} =
               ControlPlane.create(id,
                 wasm: wasm,
                 base_image: posix,
                 deterministic: true,
                 workers: 0,
                 host_call: :relay,
                 net: :relay
               )

      assert :ok =
               ControlPlane.write_file(
                 id,
                 "/etc/tools/catalog.json",
                 ~s({"tools":[{"address":"host.org.main.greet","description":"Greet","binding":{"type":"host_call","name":"greet","args":"raw"}}]})
               )

      assert {:ok, host_job} = ControlPlane.exec_start(id, "tools call host.org.main.greet world")
      assert {:ok, %{kind: :host_call, name: "greet"} = event} = next_relay(id, host_job, 5_000)
      assert tool_body(event.body) == "world"

      assert :ok = ControlPlane.egress_host_call_respond(id, event.handle, "hello #{tool_body(event.body)}\n")

      assert {:ok, %{exit_code: 0, stdout: ~s({"ok":true,"data":"hello world\\n"}\n), stderr: ""}} =
               poll_exec(id, host_job, 5_000)

      assert {:ok, http_job} = ControlPlane.exec_start(id, "fetch http://example.test/hello")
      assert {:ok, %{kind: :http, request: request} = http} = next_relay(id, http_job, 5_000)
      assert request =~ "GET http://example.test/hello"

      assert :ok =
               ControlPlane.egress_http_respond(
                 id,
                 http.handle,
                 200,
                 "OK",
                 [{"content-type", "text/plain"}],
                 "net hello\n"
               )

      assert {:ok, %{exit_code: 0, stdout: "net hello\n", stderr: ""}} =
               poll_exec(id, http_job, 5_000)

      assert {:ok, nil} = ControlPlane.egress_next(id)
    after
      ControlPlane.dispose(id)
    end
  end

  @tag timeout: 120_000
  test "real kernel VM relays async persistence to the BEAM owner" do
    wasm = runfile!("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile!("memcontainers/images/posix.tar")
    id = unique_id("persist-relay")

    try do
      assert {:ok, _pid} =
               ControlPlane.create(id,
                 wasm: wasm,
                 base_image: posix,
                 deterministic: true,
                 workers: 0,
                 persist: :relay
               )

      assert {:ok, write_job} = ControlPlane.exec_start(id, "echo relay > /var/persist/item")

      assert {:ok, %{kind: :persist_get, key: "item"} = get} = next_relay(id, write_job, 5_000)
      assert :ok = ControlPlane.egress_persist_respond(id, get.handle, <<0>>)

      assert {:ok, %{kind: :persist_list, prefix: "item/"} = list} =
               next_relay(id, write_job, 5_000)

      assert :ok = ControlPlane.egress_persist_respond(id, list.handle, "")

      assert {:ok, %{kind: :persist_put, key: "item", value: "relay\n"} = put} =
               next_relay(id, write_job, 5_000)

      assert :ok = ControlPlane.egress_persist_respond(id, put.handle, "")
      assert :running = ControlPlane.tick(id, 8)
      assert {:ok, status} = ControlPlane.status(id)
      assert status.pending_commits == 0

      assert {:ok, %{exit_code: 0, stdout: "", stderr: ""}} = poll_exec(id, write_job, 5_000)

      assert {:ok, read_job} = ControlPlane.exec_start(id, "read line < /var/persist/item; echo $line")
      assert {:ok, %{kind: :persist_get, key: "item"} = read} = next_relay(id, read_job, 5_000)
      assert :ok = ControlPlane.egress_persist_respond(id, read.handle, <<1, "relay\n">>)

      assert {:ok, %{exit_code: 0, stdout: "relay\n", stderr: ""}} =
               poll_exec(id, read_job, 5_000)
    after
      ControlPlane.dispose(id)
    end
  end

  defp poll_exec(_id, _job, 0), do: flunk("exec job did not finish")

  defp poll_exec(id, job, attempts) do
    case ControlPlane.exec_poll(id, job) do
      {:ok, nil} ->
        ControlPlane.tick(id, 8)
        poll_exec(id, job, attempts - 1)

      done ->
        done
    end
  end

  defp next_relay(_id, _job, 0), do: flunk("relay event did not arrive")

  defp next_relay(id, job, attempts) do
    case ControlPlane.egress_next(id) do
      {:ok, nil} ->
        case ControlPlane.exec_poll(id, job) do
          {:ok, nil} ->
            ControlPlane.tick(id, 8)
            next_relay(id, job, attempts - 1)

          {:ok, result} ->
            flunk("exec finished before producing a relay event: #{inspect(result)}")

          {:error, reason} ->
            flunk("exec poll failed before producing a relay event: #{inspect(reason)}")
        end

      event ->
        event
    end
  end

  defp unique_id(prefix),
    do: {"test-ns", "#{prefix}-#{System.unique_integer([:positive])}"}

  defp tool_body(body), do: String.trim_trailing(body, <<0>>)

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
