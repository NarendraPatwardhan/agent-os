# @generated from contracts/runner.kdl by //contracts/codegen:projector — do not edit.
defmodule AgentOS.Contracts.Runner do
  @moduledoc false

  @protocol_version 1
  def protocol_version, do: @protocol_version
  @runner_max_frame_bytes 8392704
  def runner_max_frame_bytes, do: @runner_max_frame_bytes
  @runner_default_vsock_port 52
  def runner_default_vsock_port, do: @runner_default_vsock_port
  @runner_health_kind "agentos.health.v1"
  def runner_health_kind, do: @runner_health_kind
  @runner_health_contract_digest "sha256:515a069b3ebe4d7e6fbb23496b4e71908ad2b5046b00345b3cfe833c4ea82339"
  def runner_health_contract_digest, do: @runner_health_contract_digest


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

  @runner_hello_msg_id 1
  @runner_hello_version 1

  def encode_runner_hello(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@runner_hello_msg_id),
      put_u8(@runner_hello_version),
      put_u32(field!(msg, :protocol_version)),
      put_str(field!(msg, :agent)),
      put_str(field!(msg, :kind)),
      put_u32(field!(msg, :version)),
      put_str(field!(msg, :contract_digest))
    ])
  end

  def decode_runner_hello(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @runner_hello_msg_id, @runner_hello_version),
         {:ok, protocol_version, rest} <- read_u32(rest),
         {:ok, agent, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_str(rest),
         {:ok, version, rest} <- read_u32(rest),
         {:ok, contract_digest, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        protocol_version: protocol_version,
        agent: agent,
        kind: kind,
        version: version,
        contract_digest: contract_digest,
      }}
    end
  end

  def runner_hello_msg_id, do: @runner_hello_msg_id
  def runner_hello_version, do: @runner_hello_version

  # RUNNER_HELLO
  @runner_request_msg_id 2
  @runner_request_version 1

  def encode_runner_request(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@runner_request_msg_id),
      put_u8(@runner_request_version),
      put_str(field!(msg, :request_id)),
      put_str(field!(msg, :kind)),
      put_str(field!(msg, :operation)),
      put_bytes(field!(msg, :body)),
      put_i64(field!(msg, :timeout_ms))
    ])
  end

  def decode_runner_request(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @runner_request_msg_id, @runner_request_version),
         {:ok, request_id, rest} <- read_str(rest),
         {:ok, kind, rest} <- read_str(rest),
         {:ok, operation, rest} <- read_str(rest),
         {:ok, body, rest} <- read_bytes(rest),
         {:ok, timeout_ms, rest} <- read_i64(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        request_id: request_id,
        kind: kind,
        operation: operation,
        body: body,
        timeout_ms: timeout_ms,
      }}
    end
  end

  def runner_request_msg_id, do: @runner_request_msg_id
  def runner_request_version, do: @runner_request_version

  # RUNNER_REQUEST
  @runner_response_msg_id 3
  @runner_response_version 1

  def encode_runner_response(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@runner_response_msg_id),
      put_u8(@runner_response_version),
      put_str(field!(msg, :request_id)),
      put_bool(field!(msg, :ok)),
      put_bytes(field!(msg, :body)),
      case field(msg, :error_code) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :error_message) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end
    ])
  end

  def decode_runner_response(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @runner_response_msg_id, @runner_response_version),
         {:ok, request_id, rest} <- read_str(rest),
         {:ok, ok, rest} <- read_bool(rest),
         {:ok, body, rest} <- read_bytes(rest),
         {:ok, error_code, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, error_message, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        request_id: request_id,
        ok: ok,
        body: body,
        error_code: error_code,
        error_message: error_message,
      }}
    end
  end

  def runner_response_msg_id, do: @runner_response_msg_id
  def runner_response_version, do: @runner_response_version

  # RUNNER_RESPONSE
end
