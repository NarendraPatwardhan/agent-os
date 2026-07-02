# @generated from contracts/control.kdl by //contracts/codegen:projector — do not edit.
defmodule AgentOS.Contracts.Control do
  @moduledoc false

  defp field!(map, key) do
    case field(map, key, :__mc_missing__) do
      :__mc_missing__ -> raise KeyError, key: key, term: map
      value -> value
    end
  end

  defp field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp read_header(bytes, expected_id, expected_version) do
    with {:ok, id, rest} <- read_u16(bytes),
         true <- id == expected_id || {:error, "wrong message id"},
         {:ok, version, rest} <- read_u8(rest),
         true <- version == expected_version || {:error, "unsupported message version"} do
      {:ok, rest}
    end
  end

  defp read_u8(<<value, rest::binary>>), do: {:ok, value, rest}
  defp read_u8(_bytes), do: {:error, "truncated frame"}
  defp read_u16(<<value::unsigned-little-16, rest::binary>>), do: {:ok, value, rest}
  defp read_u16(_bytes), do: {:error, "truncated frame"}
  defp read_u32(<<value::unsigned-little-32, rest::binary>>), do: {:ok, value, rest}
  defp read_u32(_bytes), do: {:error, "truncated frame"}
  defp read_i64(<<value::signed-little-64, rest::binary>>), do: {:ok, value, rest}
  defp read_i64(_bytes), do: {:error, "truncated frame"}

  defp read_bool(bytes) do
    case read_u8(bytes) do
      {:ok, 0, rest} -> {:ok, false, rest}
      {:ok, 1, rest} -> {:ok, true, rest}
      {:ok, _value, _rest} -> {:error, "invalid bool"}
      err -> err
    end
  end

  defp read_bytes(bytes) do
    with {:ok, len, rest} <- read_u32(bytes),
         true <- byte_size(rest) >= len || {:error, "truncated frame"} do
      <<out::binary-size(^len), rest::binary>> = rest
      {:ok, out, rest}
    end
  end

  defp read_str(bytes) do
    with {:ok, out, rest} <- read_bytes(bytes),
         true <- String.valid?(out) || {:error, "invalid utf-8"} do
      {:ok, out, rest}
    end
  end

  defp read_strmap(bytes) do
    with {:ok, n, rest} <- read_u32(bytes) do
      read_strmap_entries(n, rest, nil, %{})
    end
  end

  defp read_strmap_entries(0, rest, _prev, out), do: {:ok, out, rest}

  defp read_strmap_entries(n, bytes, prev, out) do
    with {:ok, key, rest} <- read_str(bytes),
         true <- is_nil(prev) or prev < key || {:error, "non-canonical strmap"},
         {:ok, value, rest} <- read_str(rest) do
      read_strmap_entries(n - 1, rest, key, Map.put(out, key, value))
    end
  end

  defp read_opt(bytes, fun) do
    case read_u8(bytes) do
      {:ok, 0, rest} -> {:ok, nil, rest}
      {:ok, 1, rest} -> fun.(rest)
      {:ok, _value, _rest} -> {:error, "invalid optional presence"}
      err -> err
    end
  end

  defp read_eof(<<>>), do: :ok
  defp read_eof(_rest), do: {:error, "trailing bytes"}

  defp put_u8(value), do: <<value::unsigned-little-8>>
  defp put_u16(value), do: <<value::unsigned-little-16>>
  defp put_u32(value), do: <<value::unsigned-little-32>>
  defp put_i64(value), do: <<value::signed-little-64>>
  defp put_bool(true), do: <<1>>
  defp put_bool(false), do: <<0>>
  defp put_bytes(bytes), do: [put_u32(byte_size(bytes)), bytes]
  defp put_str(value), do: put_bytes(value)

  defp put_strmap(map) do
    entries = map |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end) |> Enum.sort()
    [put_u32(length(entries)), Enum.map(entries, fn {k, v} -> [put_str(k), put_str(v)] end)]
  end

  defp read_message_list(bytes, decoder) do
    with {:ok, n, rest} <- read_u32(bytes) do
      read_message_list_items(n, rest, decoder, [])
    end
  end

  defp read_message_list_items(0, rest, _decoder, acc), do: {:ok, Enum.reverse(acc), rest}

  defp read_message_list_items(n, bytes, decoder, acc) do
    with {:ok, item_bytes, rest} <- read_bytes(bytes),
         {:ok, item} <- decoder.(item_bytes) do
      read_message_list_items(n - 1, rest, decoder, [item | acc])
    end
  end

  defp put_message_list(values, encoder) do
    [put_u32(length(values)), Enum.map(values, fn value -> put_bytes(encoder.(value)) end)]
  end

  defp read_i32(<<value::signed-little-32, rest::binary>>), do: {:ok, value, rest}
  defp read_i32(_bytes), do: {:error, "truncated frame"}
  defp put_i32(value), do: <<value::signed-little-32>>

  @exec_request_msg_id 1
  @exec_request_version 1

  def encode_exec_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@exec_request_msg_id),
      put_u8(@exec_request_version),
      put_str(field!(msg, :cmd)),
      case field(msg, :cwd) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_strmap(field!(msg, :env)),
      case field(msg, :stdin) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_exec_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @exec_request_msg_id, @exec_request_version),
         {:ok, cmd, rest} <- read_str(rest),
         {:ok, cwd, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, env, rest} <- read_strmap(rest),
         {:ok, stdin, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        cmd: cmd,
        cwd: cwd,
        env: env,
        stdin: stdin,
      }}
    end
  end

  def exec_request_msg_id, do: @exec_request_msg_id
  def exec_request_version, do: @exec_request_version

  # EXEC_REQUEST
  @exec_outcome_msg_id 2
  @exec_outcome_version 1

  def encode_exec_outcome(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@exec_outcome_msg_id),
      put_u8(@exec_outcome_version),
      put_i32(field!(msg, :exit_code)),
      put_bytes(field!(msg, :stdout)),
      put_bytes(field!(msg, :stderr))
    ])
  end

  def decode_exec_outcome(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @exec_outcome_msg_id, @exec_outcome_version),
         {:ok, exit_code, rest} <- read_i32(rest),
         {:ok, stdout, rest} <- read_bytes(rest),
         {:ok, stderr, rest} <- read_bytes(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        exit_code: exit_code,
        stdout: stdout,
        stderr: stderr,
      }}
    end
  end

  def exec_outcome_msg_id, do: @exec_outcome_msg_id
  def exec_outcome_version, do: @exec_outcome_version

  # EXEC_OUTCOME
  @file_stat_msg_id 3
  @file_stat_version 1

  def encode_file_stat(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@file_stat_msg_id),
      put_u8(@file_stat_version),
      put_i64(field!(msg, :size)),
      put_bool(field!(msg, :is_dir)),
      put_bool(field!(msg, :is_symlink)),
      put_u32(field!(msg, :nlink)),
      put_u32(field!(msg, :mode))
    ])
  end

  def decode_file_stat(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @file_stat_msg_id, @file_stat_version),
         {:ok, size, rest} <- read_i64(rest),
         {:ok, is_dir, rest} <- read_bool(rest),
         {:ok, is_symlink, rest} <- read_bool(rest),
         {:ok, nlink, rest} <- read_u32(rest),
         {:ok, mode, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        size: size,
        is_dir: is_dir,
        is_symlink: is_symlink,
        nlink: nlink,
        mode: mode,
      }}
    end
  end

  def file_stat_msg_id, do: @file_stat_msg_id
  def file_stat_version, do: @file_stat_version

  # FILE_STAT
  @dir_entry_msg_id 4
  @dir_entry_version 1

  def encode_dir_entry(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@dir_entry_msg_id),
      put_u8(@dir_entry_version),
      put_str(field!(msg, :name)),
      put_bool(field!(msg, :is_dir)),
      put_bool(field!(msg, :is_symlink))
    ])
  end

  def decode_dir_entry(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @dir_entry_msg_id, @dir_entry_version),
         {:ok, name, rest} <- read_str(rest),
         {:ok, is_dir, rest} <- read_bool(rest),
         {:ok, is_symlink, rest} <- read_bool(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        name: name,
        is_dir: is_dir,
        is_symlink: is_symlink,
      }}
    end
  end

  def dir_entry_msg_id, do: @dir_entry_msg_id
  def dir_entry_version, do: @dir_entry_version

  # DIR_ENTRY
  @dir_entries_msg_id 5
  @dir_entries_version 1

  def encode_dir_entries(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@dir_entries_msg_id),
      put_u8(@dir_entries_version),
      put_message_list(field!(msg, :entries), &encode_dir_entry/1)
    ])
  end

  def decode_dir_entries(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @dir_entries_msg_id, @dir_entries_version),
         {:ok, entries, rest} <- read_message_list(rest, &decode_dir_entry/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        entries: entries,
      }}
    end
  end

  def dir_entries_msg_id, do: @dir_entries_msg_id
  def dir_entries_version, do: @dir_entries_version

  # DIR_ENTRIES
  @svc_request_msg_id 6
  @svc_request_version 1

  def encode_svc_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@svc_request_msg_id),
      put_u8(@svc_request_version),
      put_str(field!(msg, :service)),
      put_bytes(field!(msg, :request))
    ])
  end

  def decode_svc_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @svc_request_msg_id, @svc_request_version),
         {:ok, service, rest} <- read_str(rest),
         {:ok, request, rest} <- read_bytes(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        service: service,
        request: request,
      }}
    end
  end

  def svc_request_msg_id, do: @svc_request_msg_id
  def svc_request_version, do: @svc_request_version

  # SVC_REQUEST
  @svc_response_msg_id 7
  @svc_response_version 1

  def encode_svc_response(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@svc_response_msg_id),
      put_u8(@svc_response_version),
      put_i32(field!(msg, :status)),
      put_bytes(field!(msg, :body))
    ])
  end

  def decode_svc_response(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @svc_response_msg_id, @svc_response_version),
         {:ok, status, rest} <- read_i32(rest),
         {:ok, body, rest} <- read_bytes(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        status: status,
        body: body,
      }}
    end
  end

  def svc_response_msg_id, do: @svc_response_msg_id
  def svc_response_version, do: @svc_response_version

  # SVC_RESPONSE
  @relay_event_msg_id 8
  @relay_event_version 1

  def encode_relay_event(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@relay_event_msg_id),
      put_u8(@relay_event_version),
      put_str(field!(msg, :kind)),
      put_i32(field!(msg, :handle)),
      case field(msg, :request) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :name) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :body) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :key) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :value) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :prefix) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :url) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :connection) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :method) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :origin) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :args_digest) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end
    ])
  end

  def decode_relay_event(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @relay_event_msg_id, @relay_event_version),
         {:ok, kind, rest} <- read_str(rest),
         {:ok, handle, rest} <- read_i32(rest),
         {:ok, request, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, name, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, body, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, key, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, value, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, prefix, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, url, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, connection, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, method, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, origin, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, args_digest, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        kind: kind,
        handle: handle,
        request: request,
        name: name,
        body: body,
        key: key,
        value: value,
        prefix: prefix,
        url: url,
        data: data,
        connection: connection,
        method: method,
        origin: origin,
        args_digest: args_digest,
      }}
    end
  end

  def relay_event_msg_id, do: @relay_event_msg_id
  def relay_event_version, do: @relay_event_version

  # RELAY_EVENT
end
