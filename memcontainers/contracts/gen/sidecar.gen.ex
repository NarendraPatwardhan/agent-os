# @generated from contracts/sidecar.kdl by //contracts/codegen:projector — do not edit.
defmodule AgentOS.Contracts.Sidecar do
  @moduledoc false

  @protocol_version 1
  def protocol_version, do: @protocol_version
  @sidecar_max_hosts 16
  def sidecar_max_hosts, do: @sidecar_max_hosts
  @sidecar_max_grants 32
  def sidecar_max_grants, do: @sidecar_max_grants
  @sidecar_max_instances_per_grant 8
  def sidecar_max_instances_per_grant, do: @sidecar_max_instances_per_grant
  @sidecar_max_instances_per_vm 32
  def sidecar_max_instances_per_vm, do: @sidecar_max_instances_per_vm
  @sidecar_max_inflight_per_instance 16
  def sidecar_max_inflight_per_instance, do: @sidecar_max_inflight_per_instance
  @sidecar_max_inflight_per_vm 64
  def sidecar_max_inflight_per_vm, do: @sidecar_max_inflight_per_vm
  @sidecar_max_request_bytes 1048576
  def sidecar_max_request_bytes, do: @sidecar_max_request_bytes
  @sidecar_max_result_bytes 8388608
  def sidecar_max_result_bytes, do: @sidecar_max_result_bytes
  @sidecar_max_name_bytes 64
  def sidecar_max_name_bytes, do: @sidecar_max_name_bytes
  @sidecar_max_kind_bytes 96
  def sidecar_max_kind_bytes, do: @sidecar_max_kind_bytes
  @sidecar_max_digest_bytes 96
  def sidecar_max_digest_bytes, do: @sidecar_max_digest_bytes
  @sidecar_max_operation_bytes 128
  def sidecar_max_operation_bytes, do: @sidecar_max_operation_bytes
  @sidecar_max_idempotency_bytes 128
  def sidecar_max_idempotency_bytes, do: @sidecar_max_idempotency_bytes
  @sidecar_warning_buffer 64
  def sidecar_warning_buffer, do: @sidecar_warning_buffer
  @sidecar_default_operation_timeout_ms 60000
  def sidecar_default_operation_timeout_ms, do: @sidecar_default_operation_timeout_ms
  @sidecar_max_operation_timeout_ms 300000
  def sidecar_max_operation_timeout_ms, do: @sidecar_max_operation_timeout_ms
  @sidecar_default_lease_ttl_ms 60000
  def sidecar_default_lease_ttl_ms, do: @sidecar_default_lease_ttl_ms
  @sidecar_default_renew_ms 20000
  def sidecar_default_renew_ms, do: @sidecar_default_renew_ms
  @sidecar_min_lease_ttl_ms 100
  def sidecar_min_lease_ttl_ms, do: @sidecar_min_lease_ttl_ms
  @sidecar_max_lease_ttl_ms 300000
  def sidecar_max_lease_ttl_ms, do: @sidecar_max_lease_ttl_ms
  @sidecar_min_renew_ms 10
  def sidecar_min_renew_ms, do: @sidecar_min_renew_ms
  @sidecar_max_renew_ms 30000
  def sidecar_max_renew_ms, do: @sidecar_max_renew_ms
  @sidecar_host_binding "mc.sidecar"
  def sidecar_host_binding, do: @sidecar_host_binding
  @sidecar_error_cancelled "cancelled"
  def sidecar_error_cancelled, do: @sidecar_error_cancelled
  @sidecar_error_closing "sidecar_closing"
  def sidecar_error_closing, do: @sidecar_error_closing
  @sidecar_error_contract_mismatch "sidecar_contract_mismatch"
  def sidecar_error_contract_mismatch, do: @sidecar_error_contract_mismatch
  @sidecar_error_detached "sidecar_detached"
  def sidecar_error_detached, do: @sidecar_error_detached
  @sidecar_error_grant_exists "sidecar_grant_exists"
  def sidecar_error_grant_exists, do: @sidecar_error_grant_exists
  @sidecar_error_grant_missing "sidecar_grant_missing"
  def sidecar_error_grant_missing, do: @sidecar_error_grant_missing
  @sidecar_error_host_missing "sidecar_host_missing"
  def sidecar_error_host_missing, do: @sidecar_error_host_missing
  @sidecar_error_idempotency_conflict "sidecar_idempotency_conflict"
  def sidecar_error_idempotency_conflict, do: @sidecar_error_idempotency_conflict
  @sidecar_error_in_use "sidecar_in_use"
  def sidecar_error_in_use, do: @sidecar_error_in_use
  @sidecar_error_invalid_request "sidecar_invalid_request"
  def sidecar_error_invalid_request, do: @sidecar_error_invalid_request
  @sidecar_error_limit "sidecar_limit"
  def sidecar_error_limit, do: @sidecar_error_limit
  @sidecar_error_not_found "sidecar_not_found"
  def sidecar_error_not_found, do: @sidecar_error_not_found
  @sidecar_error_not_ready "sidecar_not_ready"
  def sidecar_error_not_ready, do: @sidecar_error_not_ready
  @sidecar_error_permission_denied "sidecar_permission_denied"
  def sidecar_error_permission_denied, do: @sidecar_error_permission_denied
  @sidecar_error_provider_failed "sidecar_provider_failed"
  def sidecar_error_provider_failed, do: @sidecar_error_provider_failed
  @sidecar_error_scope_missing "sidecar_scope_missing"
  def sidecar_error_scope_missing, do: @sidecar_error_scope_missing
  @sidecar_error_stale_generation "sidecar_stale_generation"
  def sidecar_error_stale_generation, do: @sidecar_error_stale_generation
  @sidecar_error_timeout "timeout"
  def sidecar_error_timeout, do: @sidecar_error_timeout
  @sidecar_error_unavailable "sidecar_unavailable"
  def sidecar_error_unavailable, do: @sidecar_error_unavailable
  @sidecar_error_unsupported_fork_policy "sidecar_unsupported_fork_policy"
  def sidecar_error_unsupported_fork_policy, do: @sidecar_error_unsupported_fork_policy
  @sidecar_warning_fork_omitted "sidecar_fork_omitted"
  def sidecar_warning_fork_omitted, do: @sidecar_warning_fork_omitted
  @sidecar_state_allocating 1
  def sidecar_state_allocating, do: @sidecar_state_allocating
  @sidecar_state_starting 2
  def sidecar_state_starting, do: @sidecar_state_starting
  @sidecar_state_ready 3
  def sidecar_state_ready, do: @sidecar_state_ready
  @sidecar_state_suspended 4
  def sidecar_state_suspended, do: @sidecar_state_suspended
  @sidecar_state_failed 5
  def sidecar_state_failed, do: @sidecar_state_failed
  @sidecar_state_closing 6
  def sidecar_state_closing, do: @sidecar_state_closing
  @sidecar_state_closed 7
  def sidecar_state_closed, do: @sidecar_state_closed
  @sidecar_state_detached 8
  def sidecar_state_detached, do: @sidecar_state_detached
  @sidecar_fork_omit 1
  def sidecar_fork_omit, do: @sidecar_fork_omit
  @sidecar_fork_clone 2
  def sidecar_fork_clone, do: @sidecar_fork_clone


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

  @sidecar_string_msg_id 1
  @sidecar_string_version 1

  def encode_sidecar_string(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_string_msg_id),
      put_u8(@sidecar_string_version),
      put_str(field!(msg, :value))
    ])
  end

  def decode_sidecar_string(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_string_msg_id, @sidecar_string_version),
         {:ok, value, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        value: value,
      }}
    end
  end

  def sidecar_string_msg_id, do: @sidecar_string_msg_id
  def sidecar_string_version, do: @sidecar_string_version

  # SIDECAR_STRING
  @sidecar_strings_msg_id 2
  @sidecar_strings_version 1

  def encode_sidecar_strings(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_strings_msg_id),
      put_u8(@sidecar_strings_version),
      put_message_list(field!(msg, :items), &encode_sidecar_string/1)
    ])
  end

  def decode_sidecar_strings(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_strings_msg_id, @sidecar_strings_version),
         {:ok, items, rest} <- read_message_list(rest, &decode_sidecar_string/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        items: items,
      }}
    end
  end

  def sidecar_strings_msg_id, do: @sidecar_strings_msg_id
  def sidecar_strings_version, do: @sidecar_strings_version

  # SIDECAR_STRINGS
  @sidecar_grant_msg_id 3
  @sidecar_grant_version 1

  def encode_sidecar_grant(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_grant_msg_id),
      put_u8(@sidecar_grant_version),
      put_str(field!(msg, :name)),
      put_str(field!(msg, :kind)),
      put_u32(field!(msg, :version)),
      put_str(field!(msg, :contract_digest)),
      put_bool(field!(msg, :guest)),
      put_u32(field!(msg, :max_instances)),
      put_u32(field!(msg, :fork_policy)),
      put_bytes(field!(msg, :config))
    ])
  end

  def decode_sidecar_grant(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_grant_msg_id, @sidecar_grant_version),
         {:ok, name, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_str(rest),
         {:ok, version, rest} <- read_u32(rest),
         {:ok, contract_digest, rest} <- read_str(rest),
         {:ok, guest, rest} <- read_bool(rest),
         {:ok, max_instances, rest} <- read_u32(rest),
         {:ok, fork_policy, rest} <- read_u32(rest),
         {:ok, config, rest} <- read_bytes(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        name: name,
        kind: kind,
        version: version,
        contract_digest: contract_digest,
        guest: guest,
        max_instances: max_instances,
        fork_policy: fork_policy,
        config: config,
      }}
    end
  end

  def sidecar_grant_msg_id, do: @sidecar_grant_msg_id
  def sidecar_grant_version, do: @sidecar_grant_version

  # SIDECAR_GRANT
  @sidecar_capability_msg_id 4
  @sidecar_capability_version 1

  def encode_sidecar_capability(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_capability_msg_id),
      put_u8(@sidecar_capability_version),
      put_str(field!(msg, :kind)),
      put_u32(field!(msg, :version)),
      put_str(field!(msg, :contract_digest)),
      put_bytes(encode_sidecar_strings(field!(msg, :placements))),
      put_u32(field!(msg, :fork_policy)),
      put_u32(field!(msg, :max_instances_per_vm))
    ])
  end

  def decode_sidecar_capability(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_capability_msg_id, @sidecar_capability_version),
         {:ok, kind, rest} <- read_str(rest),
         {:ok, version, rest} <- read_u32(rest),
         {:ok, contract_digest, rest} <- read_str(rest),
         {:ok, placements, rest} <- read_message(rest, &decode_sidecar_strings/1),
         {:ok, fork_policy, rest} <- read_u32(rest),
         {:ok, max_instances_per_vm, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        kind: kind,
        version: version,
        contract_digest: contract_digest,
        placements: placements,
        fork_policy: fork_policy,
        max_instances_per_vm: max_instances_per_vm,
      }}
    end
  end

  def sidecar_capability_msg_id, do: @sidecar_capability_msg_id
  def sidecar_capability_version, do: @sidecar_capability_version

  # SIDECAR_CAPABILITY
  @sidecar_instance_msg_id 5
  @sidecar_instance_version 1

  def encode_sidecar_instance(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_instance_msg_id),
      put_u8(@sidecar_instance_version),
      put_str(field!(msg, :id)),
      put_str(field!(msg, :grant)),
      put_str(field!(msg, :kind)),
      put_u32(field!(msg, :generation)),
      put_u32(field!(msg, :state)),
      put_i64(field!(msg, :created_at_ms)),
      put_i64(field!(msg, :expires_at_ms)),
      put_bytes(field!(msg, :metadata))
    ])
  end

  def decode_sidecar_instance(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_instance_msg_id, @sidecar_instance_version),
         {:ok, id, rest} <- read_str(rest),
         {:ok, grant, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_str(rest),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, state, rest} <- read_u32(rest),
         {:ok, created_at_ms, rest} <- read_i64(rest),
         {:ok, expires_at_ms, rest} <- read_i64(rest),
         {:ok, metadata, rest} <- read_bytes(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        id: id,
        grant: grant,
        kind: kind,
        generation: generation,
        state: state,
        created_at_ms: created_at_ms,
        expires_at_ms: expires_at_ms,
        metadata: metadata,
      }}
    end
  end

  def sidecar_instance_msg_id, do: @sidecar_instance_msg_id
  def sidecar_instance_version, do: @sidecar_instance_version

  # SIDECAR_INSTANCE
  @sidecar_instances_msg_id 6
  @sidecar_instances_version 1

  def encode_sidecar_instances(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_instances_msg_id),
      put_u8(@sidecar_instances_version),
      put_message_list(field!(msg, :items), &encode_sidecar_instance/1)
    ])
  end

  def decode_sidecar_instances(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_instances_msg_id, @sidecar_instances_version),
         {:ok, items, rest} <- read_message_list(rest, &decode_sidecar_instance/1),
         :ok <- read_eof(rest) do
      {:ok, %{
        items: items,
      }}
    end
  end

  def sidecar_instances_msg_id, do: @sidecar_instances_msg_id
  def sidecar_instances_version, do: @sidecar_instances_version

  # SIDECAR_INSTANCES
  @sidecar_create_msg_id 7
  @sidecar_create_version 1

  def encode_sidecar_create(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_create_msg_id),
      put_u8(@sidecar_create_version),
      put_str(field!(msg, :grant)),
      put_str(field!(msg, :kind)),
      put_bytes(field!(msg, :body)),
      put_str(field!(msg, :idempotency_key)),
      put_i64(field!(msg, :timeout_ms))
    ])
  end

  def decode_sidecar_create(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_create_msg_id, @sidecar_create_version),
         {:ok, grant, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_str(rest),
         {:ok, body, rest} <- read_bytes(rest),
         {:ok, idempotency_key, rest} <- read_str(rest),
         {:ok, timeout_ms, rest} <- read_i64(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        grant: grant,
        kind: kind,
        body: body,
        idempotency_key: idempotency_key,
        timeout_ms: timeout_ms,
      }}
    end
  end

  def sidecar_create_msg_id, do: @sidecar_create_msg_id
  def sidecar_create_version, do: @sidecar_create_version

  # SIDECAR_CREATE
  @sidecar_call_msg_id 8
  @sidecar_call_version 1

  def encode_sidecar_call(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_call_msg_id),
      put_u8(@sidecar_call_version),
      put_str(field!(msg, :id)),
      put_u32(field!(msg, :generation)),
      put_str(field!(msg, :grant)),
      put_str(field!(msg, :kind)),
      put_str(field!(msg, :operation)),
      put_bytes(field!(msg, :body)),
      case field(msg, :idempotency_key) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_i64(field!(msg, :timeout_ms))
    ])
  end

  def decode_sidecar_call(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_call_msg_id, @sidecar_call_version),
         {:ok, id, rest} <- read_str(rest),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, grant, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_str(rest),
         {:ok, operation, rest} <- read_str(rest),
         {:ok, body, rest} <- read_bytes(rest),
         {:ok, idempotency_key, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, timeout_ms, rest} <- read_i64(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        id: id,
        generation: generation,
        grant: grant,
        kind: kind,
        operation: operation,
        body: body,
        idempotency_key: idempotency_key,
        timeout_ms: timeout_ms,
      }}
    end
  end

  def sidecar_call_msg_id, do: @sidecar_call_msg_id
  def sidecar_call_version, do: @sidecar_call_version

  # SIDECAR_CALL
  @sidecar_error_msg_id 9
  @sidecar_error_version 1

  def encode_sidecar_error(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_error_msg_id),
      put_u8(@sidecar_error_version),
      put_str(field!(msg, :code)),
      put_str(field!(msg, :message)),
      put_bool(field!(msg, :retryable)),
      case field(msg, :details) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end
    ])
  end

  def decode_sidecar_error(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_error_msg_id, @sidecar_error_version),
         {:ok, code, rest} <- read_str(rest),
         {:ok, message, rest} <- read_str(rest),
         {:ok, retryable, rest} <- read_bool(rest),
         {:ok, details, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        code: code,
        message: message,
        retryable: retryable,
        details: details,
      }}
    end
  end

  def sidecar_error_msg_id, do: @sidecar_error_msg_id
  def sidecar_error_version, do: @sidecar_error_version

  # SIDECAR_ERROR
  @sidecar_result_msg_id 10
  @sidecar_result_version 1

  def encode_sidecar_result(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_result_msg_id),
      put_u8(@sidecar_result_version),
      put_bool(field!(msg, :ok)),
      put_bytes(field!(msg, :body)),
      case field(msg, :error) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(encode_sidecar_error(value))]
      end
    ])
  end

  def decode_sidecar_result(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_result_msg_id, @sidecar_result_version),
         {:ok, ok, rest} <- read_bool(rest),
         {:ok, body, rest} <- read_bytes(rest),
         {:ok, error, rest} <- read_opt(rest, fn rest -> read_message(rest, &decode_sidecar_error/1) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        ok: ok,
        body: body,
        error: error,
      }}
    end
  end

  def sidecar_result_msg_id, do: @sidecar_result_msg_id
  def sidecar_result_version, do: @sidecar_result_version

  # SIDECAR_RESULT
  @sidecar_warning_msg_id 11
  @sidecar_warning_version 1

  def encode_sidecar_warning(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_warning_msg_id),
      put_u8(@sidecar_warning_version),
      put_str(field!(msg, :code)),
      put_str(field!(msg, :message)),
      case field(msg, :kind) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :grant) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :id) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end
    ])
  end

  def decode_sidecar_warning(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_warning_msg_id, @sidecar_warning_version),
         {:ok, code, rest} <- read_str(rest),
         {:ok, message, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, grant, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, id, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        code: code,
        message: message,
        kind: kind,
        grant: grant,
        id: id,
      }}
    end
  end

  def sidecar_warning_msg_id, do: @sidecar_warning_msg_id
  def sidecar_warning_version, do: @sidecar_warning_version

  # SIDECAR_WARNING
  @sidecar_delete_msg_id 12
  @sidecar_delete_version 1

  def encode_sidecar_delete(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_delete_msg_id),
      put_u8(@sidecar_delete_version),
      put_str(field!(msg, :id)),
      put_u32(field!(msg, :generation)),
      put_str(field!(msg, :grant)),
      put_str(field!(msg, :kind))
    ])
  end

  def decode_sidecar_delete(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_delete_msg_id, @sidecar_delete_version),
         {:ok, id, rest} <- read_str(rest),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, grant, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        id: id,
        generation: generation,
        grant: grant,
        kind: kind,
      }}
    end
  end

  def sidecar_delete_msg_id, do: @sidecar_delete_msg_id
  def sidecar_delete_version, do: @sidecar_delete_version

  # SIDECAR_DELETE
  @sidecar_get_msg_id 13
  @sidecar_get_version 1

  def encode_sidecar_get(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_get_msg_id),
      put_u8(@sidecar_get_version),
      put_str(field!(msg, :id)),
      put_u32(field!(msg, :generation)),
      put_str(field!(msg, :grant)),
      put_str(field!(msg, :kind))
    ])
  end

  def decode_sidecar_get(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_get_msg_id, @sidecar_get_version),
         {:ok, id, rest} <- read_str(rest),
         {:ok, generation, rest} <- read_u32(rest),
         {:ok, grant, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        id: id,
        generation: generation,
        grant: grant,
        kind: kind,
      }}
    end
  end

  def sidecar_get_msg_id, do: @sidecar_get_msg_id
  def sidecar_get_version, do: @sidecar_get_version

  # SIDECAR_GET
  @sidecar_list_msg_id 14
  @sidecar_list_version 1

  def encode_sidecar_list(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@sidecar_list_msg_id),
      put_u8(@sidecar_list_version),
      put_str(field!(msg, :grant)),
      put_str(field!(msg, :kind))
    ])
  end

  def decode_sidecar_list(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @sidecar_list_msg_id, @sidecar_list_version),
         {:ok, grant, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        grant: grant,
        kind: kind,
      }}
    end
  end

  def sidecar_list_msg_id, do: @sidecar_list_msg_id
  def sidecar_list_version, do: @sidecar_list_version

  # SIDECAR_LIST
end
