defmodule AgentOS.Git.MountBridge do
  @moduledoc """
  Adapts the kernel's generic mounted-filesystem ABI to typed Git `OP_MOUNT`.

  This is a filesystem carrier adapter only. It contains no Git porcelain or
  repository semantics; those remain in the native engine.
  """

  alias AgentOS.Contracts.Constants
  alias AgentOS.Contracts.Git
  alias AgentOS.GitEngine

  @status_ok Git.status_ok()
  @mount_op_open Constants.mount_op_open()
  @mount_op_readdir Constants.mount_op_readdir()
  @mount_op_mkdir Constants.mount_op_mkdir()
  @mount_op_unlink Constants.mount_op_unlink()
  @mount_op_rename Constants.mount_op_rename()
  @mount_op_stat Constants.mount_op_stat()
  @mount_op_write Constants.mount_op_write()
  @error_path Git.error_path()
  @error_usage Git.error_usage()
  @error_worktree Git.error_worktree()
  @error_repository Git.error_repository()
  @error_code_invalid Git.error_code_invalid()
  @error_code_missing Git.error_code_missing()
  @error_code_exists Git.error_code_exists()
  @error_code_not_directory Git.error_code_not_directory()
  @error_code_is_directory Git.error_code_is_directory()
  @error_code_not_empty Git.error_code_not_empty()
  @error_code_denied Git.error_code_denied()

  @spec call(pid(), binary()) :: {:ok, binary()} | {:error, term()}
  def call(pid, body) when is_pid(pid) and is_binary(body) do
    with {:ok, request} <- decode_kernel_request(body),
         {:ok, action} <- mount_action(request.op),
         payload <- Git.encode_mount_request(mount_request(request, action)),
         {:ok, response} <- GitEngine.request(pid, Git.op_mount(), payload) do
      encode_kernel_response(request.op, response)
    end
  end

  defp decode_kernel_request(<<op::little-32, path_len::little-32, rest::binary>>)
       when path_len <= byte_size(rest) do
    with <<path::binary-size(^path_len), arg_len::little-32, tail::binary>> <- rest,
         true <- arg_len <= byte_size(tail),
         <<arg::binary-size(^arg_len), data::binary>> <- tail,
         true <- String.valid?(path) and String.valid?(arg) do
      {:ok, %{op: op, path: engine_path(path), arg: engine_path(arg), data: data}}
    else
      _ -> {:error, :invalid_mount_request}
    end
  end

  defp decode_kernel_request(_), do: {:error, :invalid_mount_request}

  defp mount_action(@mount_op_open), do: {:ok, Git.mount_read()}
  defp mount_action(@mount_op_readdir), do: {:ok, Git.mount_readdir()}
  defp mount_action(@mount_op_mkdir), do: {:ok, Git.mount_create()}
  defp mount_action(@mount_op_unlink), do: {:ok, Git.mount_remove()}
  defp mount_action(@mount_op_rename), do: {:ok, Git.mount_rename()}
  defp mount_action(@mount_op_stat), do: {:ok, Git.mount_stat()}
  defp mount_action(@mount_op_write), do: {:ok, Git.mount_write()}
  defp mount_action(_), do: {:error, :unsupported_mount_operation}

  defp mount_request(request, action) do
    %{
      action: action,
      path: request.path,
      other_path: optional_path(request.arg),
      handle: nil,
      flags: if(action == Git.mount_create(), do: 1, else: 0),
      mode: nil,
      offset_low: nil,
      offset_high: nil,
      data: if(request.op == @mount_op_write, do: request.data, else: nil),
      cursor: nil,
      limit: nil
    }
  end

  defp encode_kernel_response(_op, %{status: status, payload: payload})
       when status != @status_ok do
    errno =
      case Git.decode_engine_error(payload) do
        {:ok, error} -> errno(error.domain, error.code)
        _ -> Constants.eio()
      end

    {:ok, <<errno::little-signed-32>>}
  end

  defp encode_kernel_response(op, %{status: @status_ok, payload: payload})
       when op == @mount_op_open do
    with {:ok, %{data: data}} <- Git.decode_file_result(payload) do
      {:ok, <<0::little-signed-32, data || <<>>::binary>>}
    end
  end

  defp encode_kernel_response(op, %{status: @status_ok, payload: payload})
       when op == @mount_op_stat do
    with {:ok, file} <- Git.decode_file_result(payload) do
      {:ok, <<0::little-signed-32, stat_record(file)::binary>>}
    end
  end

  defp encode_kernel_response(op, %{status: @status_ok, payload: payload})
       when op == @mount_op_readdir do
    with {:ok, %{entries: entries}} <- Git.decode_directory_result(payload) do
      {:ok, <<0::little-signed-32, directory_entries(entries)::binary>>}
    end
  end

  defp encode_kernel_response(_op, %{status: @status_ok}),
    do: {:ok, <<0::little-signed-32>>}

  defp stat_record(file) do
    size = join_u64(file.size_low, file.size_high)

    node_type =
      if directory_mode?(file.mode),
        do: Constants.stat_node_dir(),
        else: Constants.stat_node_file()

    <<size::little-unsigned-64, node_type::little-unsigned-32, 1::little-unsigned-32,
      file.mode::little-unsigned-32, 0::little-signed-64, 0::little-signed-64,
      0::little-signed-64>>
  end

  defp directory_entries(entries) do
    entries
    |> Enum.map(fn entry ->
      kind =
        if directory_mode?(entry.mode),
          do: Constants.serve_dirent_dir(),
          else: Constants.serve_dirent_file()

      name = entry.name
      <<kind::little-unsigned-32, byte_size(name)::little-unsigned-32, name::binary>>
    end)
    |> IO.iodata_to_binary()
  end

  defp directory_mode?(mode), do: Bitwise.band(mode, 0o170000) == 0o040000
  defp join_u64(low, high), do: low + Bitwise.bsl(high, 32)

  defp engine_path("/"), do: ""
  defp engine_path(path), do: String.trim_leading(path, "/")
  defp optional_path(""), do: nil
  defp optional_path(path), do: path

  defp errno(@error_path, @error_code_invalid), do: Constants.einval()
  defp errno(@error_path, @error_code_missing), do: Constants.enoent()
  defp errno(@error_path, @error_code_exists), do: Constants.eexist()
  defp errno(@error_path, @error_code_not_directory), do: Constants.enotdir()
  defp errno(@error_path, @error_code_is_directory), do: Constants.eisdir()
  defp errno(@error_path, @error_code_not_empty), do: Constants.enotempty()
  defp errno(@error_path, @error_code_denied), do: Constants.eacces()
  defp errno(@error_usage, _), do: Constants.eperm()
  defp errno(@error_worktree, _), do: Constants.eio()
  defp errno(@error_repository, _), do: Constants.eio()
  defp errno(_, _), do: Constants.eio()
end
