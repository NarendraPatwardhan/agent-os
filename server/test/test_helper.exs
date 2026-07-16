kvm? =
  System.get_env("AGENT_OS_KVM_E2E") == "1" or
    System.get_env("AGENT_OS_BROWSER_KVM_E2E") == "1"

ExUnit.start(exclude: if(kvm?, do: [], else: [kvm: true]))

defmodule AgentOS.TestSidecarProvider do
  @behaviour AgentOS.Sidecars.Provider

  def capabilities(_opts) do
    [
      %{
        kind: "test.echo",
        version: 1,
        contract_digest: "test-echo-v1",
        placements: [:local],
        fork: :omit,
        max_instances_per_vm: 2
      }
    ]
  end

  def create(_context, %{body: "oversized-metadata"}, _opts),
    do:
      {:ok, make_ref(),
       :binary.copy(<<0>>, AgentOS.Contracts.Sidecar.sidecar_max_result_bytes() + 1)}

  def create(_context, request, _opts), do: {:ok, make_ref(), request.body}
  def inspect(_context, _ref, _opts), do: {:ok, %{state: :ready}}
  def renew(_context, _ref, _expires_at_ms, _opts), do: :ok

  def invoke(_context, _ref, "echo", body, _opts), do: {:ok, body}

  def invoke(_context, _ref, "wait", body, opts) do
    {owner, started_ref, result} = :erlang.binary_to_term(body, [:safe])
    send(owner, {started_ref, :sidecar_call_started})
    Process.sleep(Keyword.get(opts, :test_wait_ms, 50))
    {:ok, result}
  end

  def invoke(_context, _ref, _operation, _body, _opts), do: {:error, :sidecar_operation_missing}
  def delete(_context, _ref, _opts), do: :ok
  def cancel(_context, _ref, _call_ref, _opts), do: :ok
end

defmodule AgentOS.TestRunfiles do
  def find!(suffix) do
    case System.get_env("RUNFILES_MANIFEST_FILE") do
      manifest when is_binary(manifest) ->
        manifest
        |> File.stream!()
        |> Enum.find_value(fn line ->
          line = String.trim_trailing(line)

          case String.split(line, " ", parts: 2) do
            [logical, physical] -> if String.ends_with?(logical, suffix), do: physical
            [logical] -> if String.ends_with?(logical, suffix), do: logical
          end
        end)

      _ ->
        System.get_env("RUNFILES_DIR", "")
        |> Path.join("**/#{suffix}")
        |> Path.wildcard(match_dot: true)
        |> List.first()
    end || raise "missing Bazel runfile ending in #{suffix}"
  end
end

sidecar_providers =
  if kvm? do
    work_root =
      Path.join(System.tmp_dir!(), "agentos-firecracker-#{System.unique_integer([:positive])}")

    File.rm_rf!(work_root)
    ExUnit.after_suite(fn _result -> File.rm_rf!(work_root) end)
    Application.put_env(:agent_os, :firecracker_test_root, work_root)

    browser? = System.get_env("AGENT_OS_BROWSER_KVM_E2E") == "1"

    initramfs =
      if browser? do
        AgentOS.TestRunfiles.find!("server/sidecars/browser/initramfs.cpio")
      else
        AgentOS.TestRunfiles.find!("health-initramfs.cpio")
      end

    browser_profile =
      if browser? do
        %{
          AgentOS.Contracts.Browser.browser_kind() => [
            profile: nil,
            initramfs: initramfs,
            network: false
          ]
        }
      else
        %{}
      end

    [
      {AgentOS.Sidecars.Providers.Firecracker,
       launch: :direct,
       development: true,
       health_runner: not browser?,
       browser_runner: browser?,
       prepared: browser?,
       prepared_directory: Path.join(work_root, "prepared"),
       profiles: browser_profile,
       work_root: work_root,
       firecracker: AgentOS.TestRunfiles.find!("firecracker-v1.15.1-x86_64"),
       jailer: AgentOS.TestRunfiles.find!("jailer-v1.15.1-x86_64"),
       kernel: AgentOS.TestRunfiles.find!("vmlinux-6.1.155"),
       initramfs: initramfs,
       memory_mib: 128,
       vcpus: 1}
    ]
  else
    [AgentOS.TestSidecarProvider]
  end

case AgentOS.Supervisor.start_link(sidecars: [providers: sidecar_providers]) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end
