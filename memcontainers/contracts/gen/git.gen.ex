# @generated from contracts/git.kdl by //contracts/codegen:projector — do not edit.
defmodule AgentOS.Contracts.Git do
  @moduledoc false

  @protocol_version 1
  def protocol_version, do: @protocol_version
  @request_magic "AOGQ"
  def request_magic, do: @request_magic
  @response_magic "AOGR"
  def response_magic, do: @response_magic
  @protocol_minor 0
  def protocol_minor, do: @protocol_minor
  @backend_browser 1
  def backend_browser, do: @backend_browser
  @backend_native 2
  def backend_native, do: @backend_native
  @capability_core 1
  def capability_core, do: @capability_core
  @envelope_header_bytes 20
  def envelope_header_bytes, do: @envelope_header_bytes
  @max_frame_bytes 1048576
  def max_frame_bytes, do: @max_frame_bytes
  @max_field_bytes 262144
  def max_field_bytes, do: @max_field_bytes
  @max_path_bytes 4096
  def max_path_bytes, do: @max_path_bytes
  @max_ref_bytes 1024
  def max_ref_bytes, do: @max_ref_bytes
  @max_handles 4096
  def max_handles, do: @max_handles
  @max_pack_bytes 67108864
  def max_pack_bytes, do: @max_pack_bytes
  @max_pack_objects 1000000
  def max_pack_objects, do: @max_pack_objects
  @max_result_bytes 16777216
  def max_result_bytes, do: @max_result_bytes
  @op_engine_describe 1
  def op_engine_describe, do: @op_engine_describe
  @op_session_open 2
  def op_session_open, do: @op_session_open
  @op_session_close 3
  def op_session_close, do: @op_session_close
  @op_repository_init 16
  def op_repository_init, do: @op_repository_init
  @op_repository_open 17
  def op_repository_open, do: @op_repository_open
  @op_file_stat 256
  def op_file_stat, do: @op_file_stat
  @op_file_read 257
  def op_file_read, do: @op_file_read
  @op_file_write 258
  def op_file_write, do: @op_file_write
  @op_file_remove 259
  def op_file_remove, do: @op_file_remove
  @op_file_rename 260
  def op_file_rename, do: @op_file_rename
  @op_file_readdir 261
  def op_file_readdir, do: @op_file_readdir
  @op_status 272
  def op_status, do: @op_status
  @op_add 273
  def op_add, do: @op_add
  @op_remove 274
  def op_remove, do: @op_remove
  @op_commit 275
  def op_commit, do: @op_commit
  @op_log 276
  def op_log, do: @op_log
  @op_resolve_revision 277
  def op_resolve_revision, do: @op_resolve_revision
  @op_diff 278
  def op_diff, do: @op_diff
  @op_show 279
  def op_show, do: @op_show
  @op_checkout 280
  def op_checkout, do: @op_checkout
  @op_reset 281
  def op_reset, do: @op_reset
  @op_branch 282
  def op_branch, do: @op_branch
  @op_tag 283
  def op_tag, do: @op_tag
  @op_config 284
  def op_config, do: @op_config
  @op_remote_metadata 285
  def op_remote_metadata, do: @op_remote_metadata
  @op_ignore_query 286
  def op_ignore_query, do: @op_ignore_query
  @op_sparse 287
  def op_sparse, do: @op_sparse
  @op_submodule 288
  def op_submodule, do: @op_submodule
  @op_object 512
  def op_object, do: @op_object
  @op_ref 528
  def op_ref, do: @op_ref
  @op_ref_transaction 529
  def op_ref_transaction, do: @op_ref_transaction
  @op_pack_import 544
  def op_pack_import, do: @op_pack_import
  @op_pack_build 545
  def op_pack_build, do: @op_pack_build
  @op_shallow 546
  def op_shallow, do: @op_shallow
  @op_mount 768
  def op_mount, do: @op_mount
  @op_stream 784
  def op_stream, do: @op_stream
  @op_clone 1024
  def op_clone, do: @op_clone
  @op_fetch 1025
  def op_fetch, do: @op_fetch
  @op_pull 1026
  def op_pull, do: @op_pull
  @op_push 1027
  def op_push, do: @op_push
  @op_http_effect 1040
  def op_http_effect, do: @op_http_effect
  @op_remote_cancel 1041
  def op_remote_cancel, do: @op_remote_cancel
  @op_checkpoint 1280
  def op_checkpoint, do: @op_checkpoint
  @op_restore 1281
  def op_restore, do: @op_restore
  @action_list 1
  def action_list, do: @action_list
  @action_get 2
  def action_get, do: @action_get
  @action_create 3
  def action_create, do: @action_create
  @action_update 4
  def action_update, do: @action_update
  @action_delete 5
  def action_delete, do: @action_delete
  @action_begin 6
  def action_begin, do: @action_begin
  @action_write 7
  def action_write, do: @action_write
  @action_finish 8
  def action_finish, do: @action_finish
  @action_abort 9
  def action_abort, do: @action_abort
  @action_read 10
  def action_read, do: @action_read
  @action_close 11
  def action_close, do: @action_close
  @http_response_begin 1
  def http_response_begin, do: @http_response_begin
  @http_response_chunk 2
  def http_response_chunk, do: @http_response_chunk
  @http_response_end 3
  def http_response_end, do: @http_response_end
  @http_response_abort 4
  def http_response_abort, do: @http_response_abort
  @stream_read 1
  def stream_read, do: @stream_read
  @stream_write 2
  def stream_write, do: @stream_write
  @stream_finish 3
  def stream_finish, do: @stream_finish
  @stream_abort 4
  def stream_abort, do: @stream_abort
  @stream_close 5
  def stream_close, do: @stream_close
  @mount_attach 1
  def mount_attach, do: @mount_attach
  @mount_detach 2
  def mount_detach, do: @mount_detach
  @mount_stat 3
  def mount_stat, do: @mount_stat
  @mount_read 4
  def mount_read, do: @mount_read
  @mount_write 5
  def mount_write, do: @mount_write
  @mount_create 6
  def mount_create, do: @mount_create
  @mount_remove 7
  def mount_remove, do: @mount_remove
  @mount_rename 8
  def mount_rename, do: @mount_rename
  @mount_readdir 9
  def mount_readdir, do: @mount_readdir
  @mount_chmod 10
  def mount_chmod, do: @mount_chmod
  @reset_soft 1
  def reset_soft, do: @reset_soft
  @reset_mixed 2
  def reset_mixed, do: @reset_mixed
  @reset_hard 3
  def reset_hard, do: @reset_hard
  @reset_merge 4
  def reset_merge, do: @reset_merge
  @status_ok 0
  def status_ok, do: @status_ok
  @status_effect 1
  def status_effect, do: @status_effect
  @status_error 2
  def status_error, do: @status_error
  @retry_never 0
  def retry_never, do: @retry_never
  @retry_after_input 1
  def retry_after_input, do: @retry_after_input
  @retry_after_refresh 2
  def retry_after_refresh, do: @retry_after_refresh
  @retry_transient_host 3
  def retry_transient_host, do: @retry_transient_host
  @error_protocol 1
  def error_protocol, do: @error_protocol
  @error_usage 2
  def error_usage, do: @error_usage
  @error_path 3
  def error_path, do: @error_path
  @error_repository 4
  def error_repository, do: @error_repository
  @error_object 5
  def error_object, do: @error_object
  @error_reference 6
  def error_reference, do: @error_reference
  @error_index 7
  def error_index, do: @error_index
  @error_worktree 8
  def error_worktree, do: @error_worktree
  @error_pack 9
  def error_pack, do: @error_pack
  @error_remote 10
  def error_remote, do: @error_remote
  @error_transport_effect 11
  def error_transport_effect, do: @error_transport_effect
  @error_persistence 12
  def error_persistence, do: @error_persistence
  @error_limit 13
  def error_limit, do: @error_limit
  @error_cancelled 14
  def error_cancelled, do: @error_cancelled
  @error_internal 15
  def error_internal, do: @error_internal
  @error_code_invalid 1
  def error_code_invalid, do: @error_code_invalid
  @error_code_missing 2
  def error_code_missing, do: @error_code_missing
  @error_code_exists 3
  def error_code_exists, do: @error_code_exists
  @error_code_not_directory 4
  def error_code_not_directory, do: @error_code_not_directory
  @error_code_is_directory 5
  def error_code_is_directory, do: @error_code_is_directory
  @error_code_not_empty 6
  def error_code_not_empty, do: @error_code_not_empty
  @error_code_denied 7
  def error_code_denied, do: @error_code_denied
  @error_code_stale 8
  def error_code_stale, do: @error_code_stale
  @error_code_conflict 9
  def error_code_conflict, do: @error_code_conflict


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

  defp read_message(bytes, decoder) do
    with {:ok, item_bytes, rest} <- read_bytes(bytes),
         {:ok, item} <- decoder.(item_bytes) do
      {:ok, item, rest}
    end
  end

  defp read_i32(<<value::signed-little-32, rest::binary>>), do: {:ok, value, rest}
  defp read_i32(_bytes), do: {:error, "truncated frame"}
  defp put_i32(value), do: <<value::signed-little-32>>

  @session_config_msg_id 1
  @session_config_version 1

  def encode_session_config(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@session_config_msg_id),
      put_u8(@session_config_version),
      put_u16(field!(msg, :backend)),
      put_bool(field!(msg, :read_only)),
      put_str(field!(msg, :root)),
      case field(msg, :restore) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_session_config(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @session_config_msg_id, @session_config_version),
         {:ok, backend, rest} <- read_u16(rest),
         {:ok, read_only, rest} <- read_bool(rest),
         {:ok, root, rest} <- read_str(rest),
         {:ok, restore, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        backend: backend,
        read_only: read_only,
        root: root,
        restore: restore,
      }}
    end
  end

  def session_config_msg_id, do: @session_config_msg_id
  def session_config_version, do: @session_config_version

  # SESSION_CONFIG
  @engine_description_msg_id 2
  @engine_description_version 1

  def encode_engine_description(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@engine_description_msg_id),
      put_u8(@engine_description_version),
      put_u16(field!(msg, :abi_major)),
      put_u16(field!(msg, :abi_minor)),
      put_str(field!(msg, :build_id)),
      put_str(field!(msg, :gitz_commit)),
      put_u16(field!(msg, :backend)),
      put_u32(field!(msg, :capabilities_low)),
      put_u32(field!(msg, :capabilities_high)),
      put_u32(field!(msg, :max_frame_bytes)),
      put_u32(field!(msg, :max_pack_bytes)),
      put_u32(field!(msg, :max_handles))
    ])
  end

  def decode_engine_description(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @engine_description_msg_id, @engine_description_version),
         {:ok, abi_major, rest} <- read_u16(rest),
         {:ok, abi_minor, rest} <- read_u16(rest),
         {:ok, build_id, rest} <- read_str(rest),
         {:ok, gitz_commit, rest} <- read_str(rest),
         {:ok, backend, rest} <- read_u16(rest),
         {:ok, capabilities_low, rest} <- read_u32(rest),
         {:ok, capabilities_high, rest} <- read_u32(rest),
         {:ok, max_frame_bytes, rest} <- read_u32(rest),
         {:ok, max_pack_bytes, rest} <- read_u32(rest),
         {:ok, max_handles, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        abi_major: abi_major,
        abi_minor: abi_minor,
        build_id: build_id,
        gitz_commit: gitz_commit,
        backend: backend,
        capabilities_low: capabilities_low,
        capabilities_high: capabilities_high,
        max_frame_bytes: max_frame_bytes,
        max_pack_bytes: max_pack_bytes,
        max_handles: max_handles,
      }}
    end
  end

  def engine_description_msg_id, do: @engine_description_msg_id
  def engine_description_version, do: @engine_description_version

  # ENGINE_DESCRIPTION
  @object_id_msg_id 3
  @object_id_version 1

  def encode_object_id(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@object_id_msg_id),
      put_u8(@object_id_version),
      put_u16(field!(msg, :algorithm)),
      put_bytes(field!(msg, :bytes))
    ])
  end

  def decode_object_id(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @object_id_msg_id, @object_id_version),
         {:ok, algorithm, rest} <- read_u16(rest),
         {:ok, bytes, rest} <- read_bytes(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        algorithm: algorithm,
        bytes: bytes,
      }}
    end
  end

  def object_id_msg_id, do: @object_id_msg_id
  def object_id_version, do: @object_id_version

  # OBJECT_ID
  @signature_msg_id 4
  @signature_version 1

  def encode_signature(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@signature_msg_id),
      put_u8(@signature_version),
      put_str(field!(msg, :name)),
      put_str(field!(msg, :email)),
      put_i64(field!(msg, :unix_seconds)),
      put_i32(field!(msg, :timezone_minutes))
    ])
  end

  def decode_signature(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @signature_msg_id, @signature_version),
         {:ok, name, rest} <- read_str(rest),
         {:ok, email, rest} <- read_str(rest),
         {:ok, unix_seconds, rest} <- read_i64(rest),
         {:ok, timezone_minutes, rest} <- read_i32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        name: name,
        email: email,
        unix_seconds: unix_seconds,
        timezone_minutes: timezone_minutes,
      }}
    end
  end

  def signature_msg_id, do: @signature_msg_id
  def signature_version, do: @signature_version

  # SIGNATURE
  @path_list_msg_id 5
  @path_list_version 1

  def encode_path_list(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@path_list_msg_id),
      put_u8(@path_list_version),
      put_strmap(field!(msg, :paths))
    ])
  end

  def decode_path_list(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @path_list_msg_id, @path_list_version),
         {:ok, paths, rest} <- read_strmap(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        paths: paths,
      }}
    end
  end

  def path_list_msg_id, do: @path_list_msg_id
  def path_list_version, do: @path_list_version

  # PATH_LIST
  @file_request_msg_id 6
  @file_request_version 1

  def encode_file_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@file_request_msg_id),
      put_u8(@file_request_version),
      put_str(field!(msg, :path)),
      case field(msg, :other_path) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :mode) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :offset_low) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :offset_high) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :handle) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end
    ])
  end

  def decode_file_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @file_request_msg_id, @file_request_version),
         {:ok, path, rest} <- read_str(rest),
         {:ok, other_path, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, mode, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, offset_low, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, offset_high, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, handle, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        path: path,
        other_path: other_path,
        mode: mode,
        offset_low: offset_low,
        offset_high: offset_high,
        data: data,
        handle: handle,
      }}
    end
  end

  def file_request_msg_id, do: @file_request_msg_id
  def file_request_version, do: @file_request_version

  # FILE_REQUEST
  @porcelain_request_msg_id 7
  @porcelain_request_version 1

  def encode_porcelain_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@porcelain_request_msg_id),
      put_u8(@porcelain_request_version),
      put_u16(field!(msg, :action)),
      put_u32(field!(msg, :flags)),
      case field(msg, :revision) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :target) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :message) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_strmap(field!(msg, :paths)),
      case field(msg, :limit) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :cursor) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :author) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_signature(value))]
      end,
      case field(msg, :committer) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_signature(value))]
      end
    ])
  end

  def decode_porcelain_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @porcelain_request_msg_id, @porcelain_request_version),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, flags, rest} <- read_u32(rest),
         {:ok, revision, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, target, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, message, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, paths, rest} <- read_strmap(rest),
         {:ok, limit, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, cursor, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, author, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_signature/1) end),
         {:ok, committer, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_signature/1) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        action: action,
        flags: flags,
        revision: revision,
        target: target,
        message: message,
        paths: paths,
        limit: limit,
        cursor: cursor,
        author: author,
        committer: committer,
      }}
    end
  end

  def porcelain_request_msg_id, do: @porcelain_request_msg_id
  def porcelain_request_version, do: @porcelain_request_version

  # PORCELAIN_REQUEST
  @ref_update_msg_id 8
  @ref_update_version 1

  def encode_ref_update(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@ref_update_msg_id),
      put_u8(@ref_update_version),
      put_str(field!(msg, :name)),
      case field(msg, :new_value) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_object_id(value))]
      end,
      case field(msg, :expected_value) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_object_id(value))]
      end,
      put_bool(field!(msg, :require_absent))
    ])
  end

  def decode_ref_update(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @ref_update_msg_id, @ref_update_version),
         {:ok, name, rest} <- read_str(rest),
         {:ok, new_value, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_object_id/1) end),
         {:ok, expected_value, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_object_id/1) end),
         {:ok, require_absent, rest} <- read_bool(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        name: name,
        new_value: new_value,
        expected_value: expected_value,
        require_absent: require_absent,
      }}
    end
  end

  def ref_update_msg_id, do: @ref_update_msg_id
  def ref_update_version, do: @ref_update_version

  # REF_UPDATE
  @stream_request_msg_id 10
  @stream_request_version 1

  def encode_stream_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@stream_request_msg_id),
      put_u8(@stream_request_version),
      put_u16(field!(msg, :action)),
      case field(msg, :handle) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :offset_low) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :offset_high) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_stream_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @stream_request_msg_id, @stream_request_version),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, handle, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, offset_low, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, offset_high, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        action: action,
        handle: handle,
        offset_low: offset_low,
        offset_high: offset_high,
        data: data,
      }}
    end
  end

  def stream_request_msg_id, do: @stream_request_msg_id
  def stream_request_version, do: @stream_request_version

  # STREAM_REQUEST
  @remote_request_msg_id 11
  @remote_request_version 1

  def encode_remote_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@remote_request_msg_id),
      put_u8(@remote_request_version),
      put_u16(field!(msg, :action)),
      put_str(field!(msg, :url)),
      case field(msg, :remote) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_strmap(field!(msg, :refspecs)),
      case field(msg, :depth) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      put_u32(field!(msg, :flags))
    ])
  end

  def decode_remote_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @remote_request_msg_id, @remote_request_version),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, url, rest} <- read_str(rest),
         {:ok, remote, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, refspecs, rest} <- read_strmap(rest),
         {:ok, depth, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, flags, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        action: action,
        url: url,
        remote: remote,
        refspecs: refspecs,
        depth: depth,
        flags: flags,
      }}
    end
  end

  def remote_request_msg_id, do: @remote_request_msg_id
  def remote_request_version, do: @remote_request_version

  # REMOTE_REQUEST
  @http_effect_msg_id 12
  @http_effect_version 1

  def encode_http_effect(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@http_effect_msg_id),
      put_u8(@http_effect_version),
      put_u32(field!(msg, :exchange)),
      put_str(field!(msg, :method)),
      put_str(field!(msg, :path)),
      put_strmap(field!(msg, :headers)),
      case field(msg, :body) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end
    ])
  end

  def decode_http_effect(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @http_effect_msg_id, @http_effect_version),
         {:ok, exchange, rest} <- read_u32(rest),
         {:ok, method, rest} <- read_str(rest),
         {:ok, path, rest} <- read_str(rest),
         {:ok, headers, rest} <- read_strmap(rest),
         {:ok, body, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        exchange: exchange,
        method: method,
        path: path,
        headers: headers,
        body: body,
      }}
    end
  end

  def http_effect_msg_id, do: @http_effect_msg_id
  def http_effect_version, do: @http_effect_version

  # HTTP_EFFECT
  @http_response_msg_id 13
  @http_response_version 1

  def encode_http_response(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@http_response_msg_id),
      put_u8(@http_response_version),
      put_u32(field!(msg, :exchange)),
      put_u16(field!(msg, :action)),
      case field(msg, :status) do
        nil -> <<0>>
        value -> [<<1>>, put_u16(value)]
      end,
      put_strmap(field!(msg, :headers)),
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :error_code) do
        nil -> <<0>>
        value -> [<<1>>, put_u16(value)]
      end
    ])
  end

  def decode_http_response(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @http_response_msg_id, @http_response_version),
         {:ok, exchange, rest} <- read_u32(rest),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, status, rest} <- read_opt(rest, fn rest -> read_u16(rest) end),
         {:ok, headers, rest} <- read_strmap(rest),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, error_code, rest} <- read_opt(rest, fn rest -> read_u16(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        exchange: exchange,
        action: action,
        status: status,
        headers: headers,
        data: data,
        error_code: error_code,
      }}
    end
  end

  def http_response_msg_id, do: @http_response_msg_id
  def http_response_version, do: @http_response_version

  # HTTP_RESPONSE
  @engine_error_msg_id 14
  @engine_error_version 1

  def encode_engine_error(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@engine_error_msg_id),
      put_u8(@engine_error_version),
      put_u16(field!(msg, :domain)),
      put_u16(field!(msg, :code)),
      put_u16(field!(msg, :operation)),
      put_u16(field!(msg, :retry)),
      case field(msg, :message) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :detail_kind) do
        nil -> <<0>>
        value -> [<<1>>, put_u16(value)]
      end,
      case field(msg, :detail) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_engine_error(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @engine_error_msg_id, @engine_error_version),
         {:ok, domain, rest} <- read_u16(rest),
         {:ok, code, rest} <- read_u16(rest),
         {:ok, operation, rest} <- read_u16(rest),
         {:ok, retry, rest} <- read_u16(rest),
         {:ok, message, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, detail_kind, rest} <- read_opt(rest, fn rest -> read_u16(rest) end),
         {:ok, detail, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        domain: domain,
        code: code,
        operation: operation,
        retry: retry,
        message: message,
        detail_kind: detail_kind,
        detail: detail,
      }}
    end
  end

  def engine_error_msg_id, do: @engine_error_msg_id
  def engine_error_version, do: @engine_error_version

  # ENGINE_ERROR
  @result_msg_id 15
  @result_version 1

  def encode_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@result_msg_id),
      put_u8(@result_version),
      put_u16(field!(msg, :kind)),
      put_u32(field!(msg, :generation)),
      case field(msg, :handle) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :count) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @result_msg_id, @result_version),
         {:ok, kind, rest} <- read_u16(rest),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, handle, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, count, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        kind: kind,
        generation: generation,
        handle: handle,
        count: count,
        data: data,
      }}
    end
  end

  def result_msg_id, do: @result_msg_id
  def result_version, do: @result_version

  # RESULT
  @file_result_msg_id 16
  @file_result_version 1

  def encode_file_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@file_result_msg_id),
      put_u8(@file_result_version),
      put_str(field!(msg, :path)),
      put_u32(field!(msg, :mode)),
      put_u32(field!(msg, :size_low)),
      put_u32(field!(msg, :size_high)),
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_file_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @file_result_msg_id, @file_result_version),
         {:ok, path, rest} <- read_str(rest),
         {:ok, mode, rest} <- read_u32(rest),
         {:ok, size_low, rest} <- read_u32(rest),
         {:ok, size_high, rest} <- read_u32(rest),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        path: path,
        mode: mode,
        size_low: size_low,
        size_high: size_high,
        data: data,
      }}
    end
  end

  def file_result_msg_id, do: @file_result_msg_id
  def file_result_version, do: @file_result_version

  # FILE_RESULT
  @status_entry_msg_id 17
  @status_entry_version 1

  def encode_status_entry(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@status_entry_msg_id),
      put_u8(@status_entry_version),
      put_str(field!(msg, :path)),
      put_u16(field!(msg, :index)),
      put_u16(field!(msg, :worktree))
    ])
  end

  def decode_status_entry(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @status_entry_msg_id, @status_entry_version),
         {:ok, path, rest} <- read_str(rest),
         {:ok, index, rest} <- read_u16(rest),
         {:ok, worktree, rest} <- read_u16(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        path: path,
        index: index,
        worktree: worktree,
      }}
    end
  end

  def status_entry_msg_id, do: @status_entry_msg_id
  def status_entry_version, do: @status_entry_version

  # STATUS_ENTRY
  @status_result_msg_id 18
  @status_result_version 1

  def encode_status_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@status_result_msg_id),
      put_u8(@status_result_version),
      put_u32(field!(msg, :generation)),
      put_message_list(field!(msg, :entries), &encode_status_entry/1)
    ])
  end

  def decode_status_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @status_result_msg_id, @status_result_version),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, entries, rest} <- read_message_list(rest, &decode_status_entry/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        generation: generation,
        entries: entries,
      }}
    end
  end

  def status_result_msg_id, do: @status_result_msg_id
  def status_result_version, do: @status_result_version

  # STATUS_RESULT
  @commit_result_msg_id 19
  @commit_result_version 1

  def encode_commit_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@commit_result_msg_id),
      put_u8(@commit_result_version),
      put_u32(field!(msg, :generation)),
      put_bytes(encode_object_id(field!(msg, :object_id)))
    ])
  end

  def decode_commit_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @commit_result_msg_id, @commit_result_version),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, object_id, rest} <- read_message(rest, &decode_object_id/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        generation: generation,
        object_id: object_id,
      }}
    end
  end

  def commit_result_msg_id, do: @commit_result_msg_id
  def commit_result_version, do: @commit_result_version

  # COMMIT_RESULT
  @resolve_result_msg_id 20
  @resolve_result_version 1

  def encode_resolve_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@resolve_result_msg_id),
      put_u8(@resolve_result_version),
      put_bytes(encode_object_id(field!(msg, :object_id)))
    ])
  end

  def decode_resolve_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @resolve_result_msg_id, @resolve_result_version),
         {:ok, object_id, rest} <- read_message(rest, &decode_object_id/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        object_id: object_id,
      }}
    end
  end

  def resolve_result_msg_id, do: @resolve_result_msg_id
  def resolve_result_version, do: @resolve_result_version

  # RESOLVE_RESULT
  @directory_entry_msg_id 21
  @directory_entry_version 1

  def encode_directory_entry(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@directory_entry_msg_id),
      put_u8(@directory_entry_version),
      put_str(field!(msg, :name)),
      put_u32(field!(msg, :mode)),
      put_u32(field!(msg, :size_low)),
      put_u32(field!(msg, :size_high))
    ])
  end

  def decode_directory_entry(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @directory_entry_msg_id, @directory_entry_version),
         {:ok, name, rest} <- read_str(rest),
         {:ok, mode, rest} <- read_u32(rest),
         {:ok, size_low, rest} <- read_u32(rest),
         {:ok, size_high, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        name: name,
        mode: mode,
        size_low: size_low,
        size_high: size_high,
      }}
    end
  end

  def directory_entry_msg_id, do: @directory_entry_msg_id
  def directory_entry_version, do: @directory_entry_version

  # DIRECTORY_ENTRY
  @directory_result_msg_id 22
  @directory_result_version 1

  def encode_directory_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@directory_result_msg_id),
      put_u8(@directory_result_version),
      put_message_list(field!(msg, :entries), &encode_directory_entry/1)
    ])
  end

  def decode_directory_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @directory_result_msg_id, @directory_result_version),
         {:ok, entries, rest} <- read_message_list(rest, &decode_directory_entry/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        entries: entries,
      }}
    end
  end

  def directory_result_msg_id, do: @directory_result_msg_id
  def directory_result_version, do: @directory_result_version

  # DIRECTORY_RESULT
  @reference_result_msg_id 23
  @reference_result_version 1

  def encode_reference_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@reference_result_msg_id),
      put_u8(@reference_result_version),
      put_str(field!(msg, :name)),
      put_u16(field!(msg, :kind)),
      case field(msg, :object_id) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_object_id(value))]
      end,
      case field(msg, :target) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end
    ])
  end

  def decode_reference_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @reference_result_msg_id, @reference_result_version),
         {:ok, name, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_u16(rest),
         {:ok, object_id, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_object_id/1) end),
         {:ok, target, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        name: name,
        kind: kind,
        object_id: object_id,
        target: target,
      }}
    end
  end

  def reference_result_msg_id, do: @reference_result_msg_id
  def reference_result_version, do: @reference_result_version

  # REFERENCE_RESULT
  @reference_list_msg_id 24
  @reference_list_version 1

  def encode_reference_list(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@reference_list_msg_id),
      put_u8(@reference_list_version),
      put_message_list(field!(msg, :references), &encode_reference_result/1)
    ])
  end

  def decode_reference_list(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @reference_list_msg_id, @reference_list_version),
         {:ok, references, rest} <- read_message_list(rest, &decode_reference_result/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        references: references,
      }}
    end
  end

  def reference_list_msg_id, do: @reference_list_msg_id
  def reference_list_version, do: @reference_list_version

  # REFERENCE_LIST
  @object_request_msg_id 25
  @object_request_version 1

  def encode_object_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@object_request_msg_id),
      put_u8(@object_request_version),
      put_u16(field!(msg, :action)),
      put_u16(field!(msg, :kind)),
      case field(msg, :object_id) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_object_id(value))]
      end,
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_object_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @object_request_msg_id, @object_request_version),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, kind, rest} <- read_u16(rest),
         {:ok, object_id, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_object_id/1) end),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        action: action,
        kind: kind,
        object_id: object_id,
        data: data,
      }}
    end
  end

  def object_request_msg_id, do: @object_request_msg_id
  def object_request_version, do: @object_request_version

  # OBJECT_REQUEST
  @object_result_msg_id 26
  @object_result_version 1

  def encode_object_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@object_result_msg_id),
      put_u8(@object_result_version),
      put_u16(field!(msg, :kind)),
      put_bytes(encode_object_id(field!(msg, :object_id))),
      put_u32(field!(msg, :size_low)),
      put_u32(field!(msg, :size_high)),
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_object_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @object_result_msg_id, @object_result_version),
         {:ok, kind, rest} <- read_u16(rest),
         {:ok, object_id, rest} <- read_message(rest, &decode_object_id/1),
         {:ok, size_low, rest} <- read_u32(rest),
         {:ok, size_high, rest} <- read_u32(rest),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        kind: kind,
        object_id: object_id,
        size_low: size_low,
        size_high: size_high,
        data: data,
      }}
    end
  end

  def object_result_msg_id, do: @object_result_msg_id
  def object_result_version, do: @object_result_version

  # OBJECT_RESULT
  @pack_request_msg_id 27
  @pack_request_version 1

  def encode_pack_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@pack_request_msg_id),
      put_u8(@pack_request_version),
      put_u16(field!(msg, :action)),
      case field(msg, :handle) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      put_message_list(field!(msg, :wants), &encode_object_id/1),
      put_message_list(field!(msg, :haves), &encode_object_id/1),
      put_message_list(field!(msg, :updates), &encode_ref_update/1),
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_pack_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @pack_request_msg_id, @pack_request_version),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, handle, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, wants, rest} <- read_message_list(rest, &decode_object_id/1),
         {:ok, haves, rest} <- read_message_list(rest, &decode_object_id/1),
         {:ok, updates, rest} <- read_message_list(rest, &decode_ref_update/1),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        action: action,
        handle: handle,
        wants: wants,
        haves: haves,
        updates: updates,
        data: data,
      }}
    end
  end

  def pack_request_msg_id, do: @pack_request_msg_id
  def pack_request_version, do: @pack_request_version

  # PACK_REQUEST
  @pack_result_msg_id 28
  @pack_result_version 1

  def encode_pack_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@pack_result_msg_id),
      put_u8(@pack_result_version),
      case field(msg, :handle) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      put_u32(field!(msg, :object_count)),
      put_u32(field!(msg, :reference_count)),
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_pack_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @pack_result_msg_id, @pack_result_version),
         {:ok, handle, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, object_count, rest} <- read_u32(rest),
         {:ok, reference_count, rest} <- read_u32(rest),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        handle: handle,
        object_count: object_count,
        reference_count: reference_count,
        data: data,
      }}
    end
  end

  def pack_result_msg_id, do: @pack_result_msg_id
  def pack_result_version, do: @pack_result_version

  # PACK_RESULT
  @snapshot_result_msg_id 29
  @snapshot_result_version 1

  def encode_snapshot_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@snapshot_result_msg_id),
      put_u8(@snapshot_result_version),
      put_u32(field!(msg, :generation)),
      put_bytes(field!(msg, :image))
    ])
  end

  def decode_snapshot_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @snapshot_result_msg_id, @snapshot_result_version),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, image, rest} <- read_bytes(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        generation: generation,
        image: image,
      }}
    end
  end

  def snapshot_result_msg_id, do: @snapshot_result_msg_id
  def snapshot_result_version, do: @snapshot_result_version

  # SNAPSHOT_RESULT
  @stream_chunk_msg_id 30
  @stream_chunk_version 1

  def encode_stream_chunk(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@stream_chunk_msg_id),
      put_u8(@stream_chunk_version),
      put_u32(field!(msg, :handle)),
      put_u32(field!(msg, :offset_low)),
      put_u32(field!(msg, :offset_high)),
      put_bytes(field!(msg, :data)),
      put_bool(field!(msg, :done))
    ])
  end

  def decode_stream_chunk(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @stream_chunk_msg_id, @stream_chunk_version),
         {:ok, handle, rest} <- read_u32(rest),
         {:ok, offset_low, rest} <- read_u32(rest),
         {:ok, offset_high, rest} <- read_u32(rest),
         {:ok, data, rest} <- read_bytes(rest),
         {:ok, done, rest} <- read_bool(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        handle: handle,
        offset_low: offset_low,
        offset_high: offset_high,
        data: data,
        done: done,
      }}
    end
  end

  def stream_chunk_msg_id, do: @stream_chunk_msg_id
  def stream_chunk_version, do: @stream_chunk_version

  # STREAM_CHUNK
  @mount_request_msg_id 31
  @mount_request_version 1

  def encode_mount_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@mount_request_msg_id),
      put_u8(@mount_request_version),
      put_u16(field!(msg, :action)),
      case field(msg, :path) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :other_path) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :handle) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      put_u32(field!(msg, :flags)),
      case field(msg, :mode) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :offset_low) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :offset_high) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :data) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :cursor) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :limit) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end
    ])
  end

  def decode_mount_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @mount_request_msg_id, @mount_request_version),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, path, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, other_path, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, handle, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, flags, rest} <- read_u32(rest),
         {:ok, mode, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, offset_low, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, offset_high, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, data, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, cursor, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, limit, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        action: action,
        path: path,
        other_path: other_path,
        handle: handle,
        flags: flags,
        mode: mode,
        offset_low: offset_low,
        offset_high: offset_high,
        data: data,
        cursor: cursor,
        limit: limit,
      }}
    end
  end

  def mount_request_msg_id, do: @mount_request_msg_id
  def mount_request_version, do: @mount_request_version

  # MOUNT_REQUEST
  @remote_result_msg_id 32
  @remote_result_version 1

  def encode_remote_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@remote_result_msg_id),
      put_u8(@remote_result_version),
      put_u32(field!(msg, :handle)),
      put_u16(field!(msg, :state)),
      put_u32(field!(msg, :generation)),
      put_message_list(field!(msg, :updated), &encode_reference_result/1)
    ])
  end

  def decode_remote_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @remote_result_msg_id, @remote_result_version),
         {:ok, handle, rest} <- read_u32(rest),
         {:ok, state, rest} <- read_u16(rest),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, updated, rest} <- read_message_list(rest, &decode_reference_result/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        handle: handle,
        state: state,
        generation: generation,
        updated: updated,
      }}
    end
  end

  def remote_result_msg_id, do: @remote_result_msg_id
  def remote_result_version, do: @remote_result_version

  # REMOTE_RESULT
  @path_query_msg_id 33
  @path_query_version 1

  def encode_path_query(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@path_query_msg_id),
      put_u8(@path_query_version),
      put_strmap(field!(msg, :paths))
    ])
  end

  def decode_path_query(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @path_query_msg_id, @path_query_version),
         {:ok, paths, rest} <- read_strmap(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        paths: paths,
      }}
    end
  end

  def path_query_msg_id, do: @path_query_msg_id
  def path_query_version, do: @path_query_version

  # PATH_QUERY
  @ignore_result_msg_id 34
  @ignore_result_version 1

  def encode_ignore_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@ignore_result_msg_id),
      put_u8(@ignore_result_version),
      put_strmap(field!(msg, :paths))
    ])
  end

  def decode_ignore_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @ignore_result_msg_id, @ignore_result_version),
         {:ok, paths, rest} <- read_strmap(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        paths: paths,
      }}
    end
  end

  def ignore_result_msg_id, do: @ignore_result_msg_id
  def ignore_result_version, do: @ignore_result_version

  # IGNORE_RESULT
  @ref_transaction_request_msg_id 35
  @ref_transaction_request_version 1

  def encode_ref_transaction_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@ref_transaction_request_msg_id),
      put_u8(@ref_transaction_request_version),
      put_u16(field!(msg, :action)),
      case field(msg, :handle) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      put_message_list(field!(msg, :updates), &encode_ref_update/1)
    ])
  end

  def decode_ref_transaction_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @ref_transaction_request_msg_id, @ref_transaction_request_version),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, handle, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, updates, rest} <- read_message_list(rest, &decode_ref_update/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        action: action,
        handle: handle,
        updates: updates,
      }}
    end
  end

  def ref_transaction_request_msg_id, do: @ref_transaction_request_msg_id
  def ref_transaction_request_version, do: @ref_transaction_request_version

  # REF_TRANSACTION_REQUEST
  @ref_transaction_result_msg_id 36
  @ref_transaction_result_version 1

  def encode_ref_transaction_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@ref_transaction_result_msg_id),
      put_u8(@ref_transaction_result_version),
      case field(msg, :handle) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      put_u32(field!(msg, :generation)),
      put_u32(field!(msg, :count))
    ])
  end

  def decode_ref_transaction_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @ref_transaction_result_msg_id, @ref_transaction_result_version),
         {:ok, handle, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, count, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        handle: handle,
        generation: generation,
        count: count,
      }}
    end
  end

  def ref_transaction_result_msg_id, do: @ref_transaction_result_msg_id
  def ref_transaction_result_version, do: @ref_transaction_result_version

  # REF_TRANSACTION_RESULT
  @shallow_request_msg_id 37
  @shallow_request_version 1

  def encode_shallow_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@shallow_request_msg_id),
      put_u8(@shallow_request_version),
      put_u16(field!(msg, :action)),
      put_message_list(field!(msg, :commits), &encode_object_id/1)
    ])
  end

  def decode_shallow_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @shallow_request_msg_id, @shallow_request_version),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, commits, rest} <- read_message_list(rest, &decode_object_id/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        action: action,
        commits: commits,
      }}
    end
  end

  def shallow_request_msg_id, do: @shallow_request_msg_id
  def shallow_request_version, do: @shallow_request_version

  # SHALLOW_REQUEST
  @shallow_result_msg_id 38
  @shallow_result_version 1

  def encode_shallow_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@shallow_result_msg_id),
      put_u8(@shallow_result_version),
      put_message_list(field!(msg, :commits), &encode_object_id/1)
    ])
  end

  def decode_shallow_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @shallow_result_msg_id, @shallow_result_version),
         {:ok, commits, rest} <- read_message_list(rest, &decode_object_id/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        commits: commits,
      }}
    end
  end

  def shallow_result_msg_id, do: @shallow_result_msg_id
  def shallow_result_version, do: @shallow_result_version

  # SHALLOW_RESULT
  @submodule_request_msg_id 39
  @submodule_request_version 1

  def encode_submodule_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@submodule_request_msg_id),
      put_u8(@submodule_request_version),
      put_u16(field!(msg, :action)),
      case field(msg, :path) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :object_id) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_object_id(value))]
      end
    ])
  end

  def decode_submodule_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @submodule_request_msg_id, @submodule_request_version),
         {:ok, action, rest} <- read_u16(rest),
         {:ok, path, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, object_id, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_object_id/1) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        action: action,
        path: path,
        object_id: object_id,
      }}
    end
  end

  def submodule_request_msg_id, do: @submodule_request_msg_id
  def submodule_request_version, do: @submodule_request_version

  # SUBMODULE_REQUEST
  @submodule_entry_msg_id 40
  @submodule_entry_version 1

  def encode_submodule_entry(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@submodule_entry_msg_id),
      put_u8(@submodule_entry_version),
      put_str(field!(msg, :name)),
      put_str(field!(msg, :path)),
      put_str(field!(msg, :url)),
      case field(msg, :gitlink) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_object_id(value))]
      end,
      case field(msg, :head) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_object_id(value))]
      end,
      put_u16(field!(msg, :state))
    ])
  end

  def decode_submodule_entry(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @submodule_entry_msg_id, @submodule_entry_version),
         {:ok, name, rest} <- read_str(rest),
         {:ok, path, rest} <- read_str(rest),
         {:ok, url, rest} <- read_str(rest),
         {:ok, gitlink, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_object_id/1) end),
         {:ok, head, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_object_id/1) end),
         {:ok, state, rest} <- read_u16(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        name: name,
        path: path,
        url: url,
        gitlink: gitlink,
        head: head,
        state: state,
      }}
    end
  end

  def submodule_entry_msg_id, do: @submodule_entry_msg_id
  def submodule_entry_version, do: @submodule_entry_version

  # SUBMODULE_ENTRY
  @submodule_result_msg_id 41
  @submodule_result_version 1

  def encode_submodule_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@submodule_result_msg_id),
      put_u8(@submodule_result_version),
      put_u32(field!(msg, :generation)),
      put_message_list(field!(msg, :entries), &encode_submodule_entry/1)
    ])
  end

  def decode_submodule_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @submodule_result_msg_id, @submodule_result_version),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, entries, rest} <- read_message_list(rest, &decode_submodule_entry/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        generation: generation,
        entries: entries,
      }}
    end
  end

  def submodule_result_msg_id, do: @submodule_result_msg_id
  def submodule_result_version, do: @submodule_result_version

  # SUBMODULE_RESULT
  def decode_request_envelope(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_frame_bytes do
case bytes do
<<@request_magic, @protocol_version::little-16, minor::little-16, opcode::little-16, flags::little-16, request_id::little-32, len::little-32, payload::binary-size(len)>>
when minor <= @protocol_minor and len <= @max_frame_bytes - @envelope_header_bytes ->
{:ok, %{opcode: opcode, flags: flags, request_id: request_id, payload: payload}}
_ -> {:error, :invalid_envelope}
end
end
def decode_request_envelope(_), do: {:error, :frame_too_large}
def encode_request_envelope(opcode, flags, request_id, payload) when is_binary(payload) and byte_size(payload) <= @max_frame_bytes - @envelope_header_bytes do
<<@request_magic, @protocol_version::little-16, @protocol_minor::little-16, opcode::little-16, flags::little-16, request_id::little-32, byte_size(payload)::little-32, payload::binary>>
end
def decode_response_envelope(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_result_bytes do
case bytes do
<<@response_magic, @protocol_version::little-16, minor::little-16, opcode::little-16, status::little-16, request_id::little-32, len::little-32, payload::binary-size(len)>> when minor <= @protocol_minor -> {:ok, %{opcode: opcode, status: status, request_id: request_id, payload: payload}}
_ -> {:error, :invalid_envelope}
end
end
def decode_response_envelope(_), do: {:error, :frame_too_large}
end
