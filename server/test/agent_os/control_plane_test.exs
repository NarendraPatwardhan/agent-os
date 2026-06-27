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

  defp unique_id(prefix),
    do: {"test-ns", "#{prefix}-#{System.unique_integer([:positive])}"}

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
