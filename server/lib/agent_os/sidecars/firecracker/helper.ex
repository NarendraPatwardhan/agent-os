defmodule AgentOS.Sidecars.Firecracker.Helper do
  @moduledoc false

  @layout_keys %{
    "api" => :api,
    "vsock" => :vsock,
    "cgroup" => :cgroup,
    "netns" => :netns,
    "kernel" => :kernel,
    "initramfs" => :initramfs
  }
  @artifact_keys %{
    "firecracker" => :firecracker,
    "jailer" => :jailer,
    "kernel" => :kernel,
    "initramfs" => :initramfs
  }

  def preflight(opts) do
    with {:ok, helper} <- helper_path(opts),
         {output, 0} <- System.cmd(helper, ["sys-test"], stderr_to_stdout: true),
         true <- output == "agentos-sidecar-helper 2\n" || {:error, :invalid_helper} do
      :ok
    else
      {:error, _reason} = error -> error
      {_output, status} when is_integer(status) -> {:error, :sidecar_helper_unavailable}
    end
  end

  def launch(id, _paths, opts) do
    with {:ok, helper} <- helper_path(opts) do
      profile_args =
        case Keyword.get(opts, :profile) do
          nil -> []
          profile when is_binary(profile) -> ["--profile", profile]
        end

      network_args = if Keyword.get(opts, :network, false), do: ["--network"], else: []

      snapshot_args =
        case Keyword.get(opts, :snapshot_key) do
          nil -> []
          key -> ["--snapshot", key]
        end

      args = ["jailer"] ++ profile_args ++ network_args ++ snapshot_args ++ ["--id", id]

      port =
        Port.open({:spawn_executable, String.to_charlist(helper)}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, args}
        ])

      {:ok, port}
    end
  rescue
    error -> {:error, {:sidecar_helper_failed, error}}
  end

  def artifacts(profile, opts) do
    with {:ok, helper} <- helper_path(opts) do
      profile_args = if is_binary(profile), do: ["--profile", profile], else: []

      case System.cmd(helper, ["artifacts" | profile_args], stderr_to_stdout: true) do
        {output, 0} -> parse_values(output, @artifact_keys)
        {_output, _status} -> {:error, :sidecar_helper_failed}
      end
    end
  end

  def snapshot_available?(key, opts) do
    with {:ok, helper} <- helper_path(opts) do
      case System.cmd(helper, ["snapshot-status", "--key", key], stderr_to_stdout: true) do
        {"ready\n", 0} -> true
        {"missing\n", 0} -> false
        {_output, _status} -> {:error, :sidecar_helper_failed}
      end
    end
  end

  def publish_snapshot(id, key, opts) do
    with {:ok, helper} <- helper_path(opts),
         {_output, 0} <-
           System.cmd(helper, ["snapshot-publish", "--id", id, "--key", key],
             stderr_to_stdout: true
           ) do
      :ok
    else
      {:error, _reason} = error -> error
      {_output, _status} -> {:error, :firecracker_snapshot_publish_failed}
    end
  end

  def remove_snapshot(key, opts) do
    with {:ok, helper} <- helper_path(opts),
         {_output, 0} <-
           System.cmd(helper, ["snapshot-delete", "--key", key], stderr_to_stdout: true) do
      :ok
    else
      {:error, _reason} = error -> error
      {_output, _status} -> {:error, :firecracker_snapshot_remove_failed}
    end
  end

  def layout(id, opts) do
    with {:ok, helper} <- helper_path(opts),
         {output, 0} <- System.cmd(helper, ["layout", "--id", id], stderr_to_stdout: true),
         {:ok, values} <- parse_layout(output) do
      {:ok,
       %{
         root: Path.dirname(Path.dirname(values.api)),
         api: values.api,
         vsock: values.vsock,
         cgroup: values.cgroup,
         netns: values.netns,
         kernel: values.kernel,
         initramfs: values.initramfs,
         vsock_api: "/run/vsock.socket"
       }}
    else
      {:error, _reason} = error -> error
      {_output, status} when is_integer(status) -> {:error, :sidecar_helper_failed}
    end
  end

  def cleanup(id, _paths, state) do
    opts = Map.get(state, :provider_opts, [])
    _ = cleanup_checked(id, opts)
    :ok
  end

  def cleanup_checked(id, opts) do
    if not valid_id?(id) do
      {:error, :sidecar_invalid_request}
    else
      cleanup_validated(id, opts)
    end
  end

  defp cleanup_validated(id, opts) do
    if Keyword.get(opts, :launch, :jailed) == :jailed do
      case helper_path(opts) do
        {:ok, helper} ->
          case System.cmd(helper, ["cleanup", "--id", id], stderr_to_stdout: true) do
            {_output, 0} -> :ok
            {_output, _status} -> {:error, :sidecar_cleanup_failed}
          end

        {:error, _reason} = error ->
          error
      end
    else
      case Keyword.fetch(opts, :work_root) do
        {:ok, root} when is_binary(root) ->
          if Path.type(root) == :absolute do
            case File.rm_rf(Path.join(root, id)) do
              {:ok, _paths} -> :ok
              {:error, _reason, _path} -> {:error, :sidecar_cleanup_failed}
            end
          else
            {:error, :invalid_firecracker_path}
          end

        _ ->
          {:error, :invalid_firecracker_path}
      end
    end
  end

  def reconcile(opts) do
    case helper_path(opts) do
      {:ok, helper} ->
        case System.cmd(helper, ["reconcile"], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {_output, _status} -> {:error, :sidecar_reconcile_failed}
        end

      {:error, :sidecar_helper_unavailable} = error ->
        if Keyword.get(opts, :development, false), do: :ok, else: error
    end
  end

  def renew(id, opts) do
    if not valid_id?(id) do
      {:error, :sidecar_invalid_request}
    else
      renew_validated(id, opts)
    end
  end

  defp renew_validated(id, opts) do
    if Keyword.get(opts, :launch, :jailed) == :jailed do
      with {:ok, helper} <- helper_path(opts),
           {_output, 0} <- System.cmd(helper, ["renew", "--id", id], stderr_to_stdout: true) do
        :ok
      else
        {:error, _reason} = error -> error
        {_output, status} when is_integer(status) -> {:error, :sidecar_renew_failed}
      end
    else
      :ok
    end
  end

  defp helper_path(opts) do
    case Keyword.get(opts, :helper) do
      path when is_binary(path) ->
        if Path.type(path) == :absolute and File.regular?(path),
          do: {:ok, path},
          else: {:error, :sidecar_helper_unavailable}

      _ ->
        {:error, :sidecar_helper_unavailable}
    end
  end

  defp valid_id?(id),
    do:
      is_binary(id) and byte_size(id) in 15..64 and
        Regex.match?(~r/^sc_[A-Za-z0-9_-]+$/, id)

  defp parse_layout(output) do
    keys = [:api, :vsock, :cgroup, :netns, :kernel, :initramfs]

    with {:ok, values} <- parse_values(output, @layout_keys),
         true <- Enum.all?(keys, &Map.has_key?(values, &1)) do
      {:ok, values}
    else
      _other -> {:error, :invalid_helper_layout}
    end
  end

  defp parse_values(output, allowed) do
    values =
      output
      |> String.split("\n", trim: true)
      |> Enum.reduce_while(%{}, fn line, acc ->
        case String.split(line, "=", parts: 2) do
          [key, value] when value != "" ->
            case Map.fetch(allowed, key) do
              {:ok, atom} -> {:cont, Map.put(acc, atom, value)}
              :error -> {:halt, :invalid}
            end

          _other ->
            {:halt, :invalid}
        end
      end)

    if is_map(values) and map_size(values) == map_size(allowed),
      do: {:ok, values},
      else: {:error, :invalid_helper_output}
  end
end
