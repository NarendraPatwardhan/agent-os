defmodule AgentOS.Sidecars.Firecracker.Snapshot do
  @moduledoc false

  alias AgentOS.Sidecars.Firecracker.Helper

  @format "agentos-firecracker-prepared-v1"
  @state "vmstate"
  @memory "memory"

  def enabled?(opts), do: Keyword.get(opts, :prepared, false) == true

  def key(kind, opts) do
    cache =
      {__MODULE__, :key, kind,
       Keyword.take(opts, [
         :launch,
         :helper,
         :profile,
         :firecracker,
         :jailer,
         :kernel,
         :initramfs,
         :memory_mib,
         :vcpus,
         :guest_cid,
         :network
       ])}

    case :persistent_term.get(cache, :missing) do
      :missing ->
        with {:ok, key} <- build_key(kind, opts) do
          :persistent_term.put(cache, key)
          {:ok, key}
        end

      key ->
        {:ok, key}
    end
  end

  defp build_key(kind, opts) do
    with {:ok, artifacts} <- artifacts(opts),
         {:ok, host} <- host_identity() do
      profile = Keyword.get(opts, :profile, "") || ""

      fields = [
        @format,
        kind,
        profile,
        Integer.to_string(Keyword.get(opts, :memory_mib, 128)),
        Integer.to_string(Keyword.get(opts, :vcpus, 1)),
        Integer.to_string(Keyword.get(opts, :guest_cid, 3)),
        to_string(Keyword.get(opts, :network, false)),
        host
      ]

      context = Enum.reduce(fields, :crypto.hash_init(:sha256), &hash_field/2)

      with {:ok, context} <- hash_file(context, artifacts.firecracker),
           {:ok, context} <- hash_file(context, artifacts.jailer),
           {:ok, context} <- hash_file(context, artifacts.kernel),
           {:ok, context} <- hash_file(context, artifacts.initramfs) do
        {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      end
    end
  end

  def available?(key, opts) do
    case Keyword.get(opts, :launch, :jailed) do
      :jailed -> Helper.snapshot_available?(key, opts)
      :direct -> direct_available?(key, opts)
    end
  end

  def stage(key, root, opts) do
    case Keyword.get(opts, :launch, :jailed) do
      :jailed -> :ok
      :direct -> stage_direct(key, root, opts)
    end
  end

  def publish(id, key, paths, opts) do
    case Keyword.get(opts, :launch, :jailed) do
      :jailed -> Helper.publish_snapshot(id, key, opts)
      :direct -> publish_direct(key, paths, opts)
    end
  end

  def invalidate(key, opts) do
    case Keyword.get(opts, :launch, :jailed) do
      :jailed -> Helper.remove_snapshot(key, opts)
      :direct -> invalidate_direct(key, opts)
    end
  end

  def api_paths(:jailed) do
    %{state: "/run/prepared.vmstate", memory: "/run/prepared.memory"}
  end

  def api_paths(:direct) do
    %{state: "prepared.vmstate", memory: "prepared.memory"}
  end

  def restore_api_paths(:jailed) do
    %{state: "/snapshot/vmstate", memory: "/snapshot/memory"}
  end

  def restore_api_paths(:direct) do
    %{state: "snapshot/vmstate", memory: "snapshot/memory"}
  end

  def host_output_paths(root) do
    %{
      state: Path.join(root, "run/prepared.vmstate"),
      memory: Path.join(root, "run/prepared.memory")
    }
  end

  def direct_output_paths(root) do
    %{state: Path.join(root, "prepared.vmstate"), memory: Path.join(root, "prepared.memory")}
  end

  defp artifacts(opts) do
    case Keyword.get(opts, :launch, :jailed) do
      :jailed ->
        Helper.artifacts(Keyword.get(opts, :profile), opts)

      :direct ->
        {:ok,
         %{
           firecracker: Keyword.fetch!(opts, :firecracker),
           jailer: Keyword.fetch!(opts, :jailer),
           kernel: Keyword.fetch!(opts, :kernel),
           initramfs: Keyword.fetch!(opts, :initramfs)
         }}
    end
  rescue
    KeyError -> {:error, :missing_firecracker_path}
  end

  defp host_identity do
    with {release, 0} <- System.cmd("uname", ["-r"], stderr_to_stdout: true),
         {:ok, cpuinfo} <- File.read("/proc/cpuinfo") do
      cpu =
        cpuinfo
        |> String.split("\n\n", parts: 2)
        |> hd()
        |> String.split("\n")
        |> Enum.filter(fn line ->
          String.starts_with?(line, [
            "vendor_id",
            "cpu family",
            "model\t",
            "model name",
            "stepping",
            "microcode",
            "flags"
          ])
        end)
        |> Enum.join("\n")

      {:ok, String.trim(release) <> "\n" <> cpu}
    else
      _other -> {:error, :firecracker_host_identity_failed}
    end
  end

  defp hash_field(value, context) do
    bytes = IO.iodata_to_binary(value)

    context
    |> :crypto.hash_update(<<byte_size(bytes)::unsigned-big-64>>)
    |> :crypto.hash_update(bytes)
  end

  defp hash_file(context, path) when is_binary(path) do
    with {:ok, %{type: :regular, size: size}} <- File.stat(path),
         {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      context = hash_field(Integer.to_string(size), context)

      try do
        hash_stream(file, context)
      after
        File.close(file)
      end
    else
      _other ->
        {:error, :firecracker_artifact_unavailable}
    end
  end

  defp hash_stream(file, context) do
    case IO.binread(file, 1024 * 1024) do
      :eof -> {:ok, context}
      {:error, _reason} -> {:error, :firecracker_artifact_unavailable}
      bytes -> hash_stream(file, :crypto.hash_update(context, bytes))
    end
  end

  defp direct_available?(key, opts) do
    with {:ok, directory} <- direct_directory(opts),
         true <- snapshot_file?(Path.join([directory, key, @state])),
         true <- snapshot_file?(Path.join([directory, key, @memory])) do
      true
    else
      _other -> false
    end
  end

  defp stage_direct(key, root, opts) do
    with {:ok, directory} <- direct_directory(opts),
         source = Path.join(directory, key),
         target = Path.join(root, "snapshot"),
         :ok <- File.mkdir_p(target),
         :ok <- File.ln(Path.join(source, @state), Path.join(target, @state)),
         :ok <- File.ln(Path.join(source, @memory), Path.join(target, @memory)) do
      :ok
    else
      {:error, _reason} -> {:error, :firecracker_snapshot_stage_failed}
    end
  end

  defp publish_direct(key, paths, opts) do
    with {:ok, directory} <- direct_directory(opts),
         :ok <- File.mkdir_p(directory),
         false <- direct_available?(key, opts) do
      temporary = Path.join(directory, ".#{key}-#{System.unique_integer([:positive])}")
      destination = Path.join(directory, key)

      result =
        with :ok <- File.mkdir(temporary),
             :ok <- File.rename(paths.state, Path.join(temporary, @state)),
             :ok <- File.rename(paths.memory, Path.join(temporary, @memory)),
             :ok <- File.chmod(Path.join(temporary, @state), 0o444),
             :ok <- File.chmod(Path.join(temporary, @memory), 0o444),
             :ok <- File.rename(temporary, destination) do
          :ok
        else
          {:error, :eexist} -> if(direct_available?(key, opts), do: :ok, else: {:error, :publish})
          {:error, _reason} -> {:error, :publish}
        end

      if result != :ok, do: File.rm_rf(temporary)
      if result == :ok, do: :ok, else: {:error, :firecracker_snapshot_publish_failed}
    else
      true -> :ok
      {:error, _reason} -> {:error, :firecracker_snapshot_publish_failed}
    end
  end

  defp direct_directory(opts) do
    case Keyword.get(opts, :prepared_directory) do
      directory when is_binary(directory) ->
        if Path.type(directory) == :absolute,
          do: {:ok, directory},
          else: {:error, :invalid_firecracker_path}

      _other ->
        {:error, :missing_firecracker_path}
    end
  end

  defp invalidate_direct(key, opts) do
    with {:ok, directory} <- direct_directory(opts),
         {:ok, _paths} <- File.rm_rf(Path.join(directory, key)) do
      :ok
    else
      _other -> {:error, :firecracker_snapshot_remove_failed}
    end
  end

  defp snapshot_file?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, size: size}} when size > 0 -> true
      _other -> false
    end
  end
end
