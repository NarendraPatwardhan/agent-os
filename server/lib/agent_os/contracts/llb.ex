# @generated from contracts/llb.kdl by //contracts/codegen:projector — do not edit.
defmodule AgentOS.Contracts.LLB do
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

  defp read_message(bytes, decoder) do
    with {:ok, item_bytes, rest} <- read_bytes(bytes),
         {:ok, item} <- decoder.(item_bytes) do
      {:ok, item, rest}
    end
  end

  @build_input_msg_id 1
  @build_input_version 1

  def encode_build_input(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@build_input_msg_id),
      put_u8(@build_input_version),
      put_u32(field!(msg, :index))
    ])
  end

  def decode_build_input(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @build_input_msg_id, @build_input_version),
         {:ok, index, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        index: index,
      }}
    end
  end

  def build_input_msg_id, do: @build_input_msg_id
  def build_input_version, do: @build_input_version

  # BUILD_INPUT
  @copy_path_msg_id 4
  @copy_path_version 1

  def encode_copy_path(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@copy_path_msg_id),
      put_u8(@copy_path_version),
      put_str(field!(msg, :src_path)),
      put_str(field!(msg, :dest_path))
    ])
  end

  def decode_copy_path(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @copy_path_msg_id, @copy_path_version),
         {:ok, src_path, rest} <- read_str(rest),
         {:ok, dest_path, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        src_path: src_path,
        dest_path: dest_path,
      }}
    end
  end

  def copy_path_msg_id, do: @copy_path_msg_id
  def copy_path_version, do: @copy_path_version

  # COPY_PATH
  @build_op_msg_id 2
  @build_op_version 1

  def encode_build_op(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@build_op_msg_id),
      put_u8(@build_op_version),
      put_u32(field!(msg, :kind)),
      case field(msg, :source_ref) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :input) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :src) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :dest) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :a) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :b) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :lower) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :upper) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      put_message_list(field!(msg, :parts), &encode_build_input/1),
      put_message_list(field!(msg, :copy_paths), &encode_copy_path/1),
      case field(msg, :path) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :local_path) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :http_url) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :expected_digest) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :git_repo) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :git_ref) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :dest_path) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :data_digest) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :target) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :link) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :mode) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :cmd) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :cwd) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      put_strmap(field!(msg, :env)),
      case field(msg, :stdin) do
        nil -> <<0>>
        value -> [<<1>>, put_bytes(value)]
      end,
      case field(msg, :tier) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :budget_mib) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :fuel) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :deterministic) do
        nil -> <<0>>
        value -> [<<1>>, put_bool(value)]
      end,
      case field(msg, :net) do
        nil -> <<0>>
        value -> [<<1>>, put_bool(value)]
      end,
      put_message_list(field!(msg, :mounts), &encode_build_input/1),
      case field(msg, :config_tier) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end,
      case field(msg, :config_budget_mib) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end,
      case field(msg, :config_fuel) do
        nil -> <<0>>
        value -> [<<1>>, put_u32(value)]
      end
    ])
  end

  def decode_build_op(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @build_op_msg_id, @build_op_version),
         {:ok, kind, rest} <- read_u32(rest),
         {:ok, source_ref, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, input, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, src, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, dest, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, a, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, b, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, lower, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, upper, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, parts, rest} <- read_message_list(rest, &decode_build_input/1),
         {:ok, copy_paths, rest} <- read_message_list(rest, &decode_copy_path/1),
         {:ok, path, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, local_path, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, http_url, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, expected_digest, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, git_repo, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, git_ref, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, dest_path, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, data_digest, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, target, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, link, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, mode, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, cmd, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, cwd, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, env, rest} <- read_strmap(rest),
         {:ok, stdin, rest} <- read_opt(rest, fn rest -> read_bytes(rest) end),
         {:ok, tier, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, budget_mib, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, fuel, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, deterministic, rest} <- read_opt(rest, fn rest -> read_bool(rest) end),
         {:ok, net, rest} <- read_opt(rest, fn rest -> read_bool(rest) end),
         {:ok, mounts, rest} <- read_message_list(rest, &decode_build_input/1),
         {:ok, config_tier, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         {:ok, config_budget_mib, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         {:ok, config_fuel, rest} <- read_opt(rest, fn rest -> read_u32(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        kind: kind,
        source_ref: source_ref,
        input: input,
        src: src,
        dest: dest,
        a: a,
        b: b,
        lower: lower,
        upper: upper,
        parts: parts,
        copy_paths: copy_paths,
        path: path,
        local_path: local_path,
        http_url: http_url,
        expected_digest: expected_digest,
        git_repo: git_repo,
        git_ref: git_ref,
        dest_path: dest_path,
        data_digest: data_digest,
        target: target,
        link: link,
        mode: mode,
        cmd: cmd,
        cwd: cwd,
        env: env,
        stdin: stdin,
        tier: tier,
        budget_mib: budget_mib,
        fuel: fuel,
        deterministic: deterministic,
        net: net,
        mounts: mounts,
        config_tier: config_tier,
        config_budget_mib: config_budget_mib,
        config_fuel: config_fuel,
      }}
    end
  end

  def build_op_msg_id, do: @build_op_msg_id
  def build_op_version, do: @build_op_version

  # BUILD_OP
  @digest_edge_msg_id 5
  @digest_edge_version 1

  def encode_digest_edge(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@digest_edge_msg_id),
      put_u8(@digest_edge_version),
      put_str(field!(msg, :role)),
      put_str(field!(msg, :digest))
    ])
  end

  def decode_digest_edge(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @digest_edge_msg_id, @digest_edge_version),
         {:ok, role, rest} <- read_str(rest),
         {:ok, digest, rest} <- read_str(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        role: role,
        digest: digest,
      }}
    end
  end

  def digest_edge_msg_id, do: @digest_edge_msg_id
  def digest_edge_version, do: @digest_edge_version

  # DIGEST_EDGE
  @layer_ref_msg_id 6
  @layer_ref_version 1

  def encode_layer_ref(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@layer_ref_msg_id),
      put_u8(@layer_ref_version),
      put_str(field!(msg, :producer)),
      put_str(field!(msg, :digest)),
      put_i64(field!(msg, :size))
    ])
  end

  def decode_layer_ref(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @layer_ref_msg_id, @layer_ref_version),
         {:ok, producer, rest} <- read_str(rest),
         {:ok, digest, rest} <- read_str(rest),
         {:ok, size, rest} <- read_i64(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        producer: producer,
        digest: digest,
        size: size,
      }}
    end
  end

  def layer_ref_msg_id, do: @layer_ref_msg_id
  def layer_ref_version, do: @layer_ref_version

  # LAYER_REF
  @node_digest_msg_id 7
  @node_digest_version 1

  def encode_node_digest(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@node_digest_msg_id),
      put_u8(@node_digest_version),
      put_bytes(encode_build_op(field!(msg, :op))),
      put_message_list(field!(msg, :edges), &encode_digest_edge/1),
      put_strmap(field!(msg, :resolved)),
      put_message_list(field!(msg, :layers), &encode_layer_ref/1),
      case field(msg, :kernel_digest) do
        nil -> <<0>>
        value -> [<<1>>, put_str(value)]
      end
    ])
  end

  def decode_node_digest(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @node_digest_msg_id, @node_digest_version),
         {:ok, op, rest} <- read_message(rest, &decode_build_op/1),
         {:ok, edges, rest} <- read_message_list(rest, &decode_digest_edge/1),
         {:ok, resolved, rest} <- read_strmap(rest),
         {:ok, layers, rest} <- read_message_list(rest, &decode_layer_ref/1),
         {:ok, kernel_digest, rest} <- read_opt(rest, fn rest -> read_str(rest) end),
         :ok <- read_eof(rest) do
      {:ok, %{
        op: op,
        edges: edges,
        resolved: resolved,
        layers: layers,
        kernel_digest: kernel_digest,
      }}
    end
  end

  def node_digest_msg_id, do: @node_digest_msg_id
  def node_digest_version, do: @node_digest_version

  # NODE_DIGEST
  @definition_msg_id 3
  @definition_version 1

  def encode_definition(msg) when is_map(msg) do
    IO.iodata_to_binary([
      put_u16(@definition_msg_id),
      put_u8(@definition_version),
      put_u32(field!(msg, :version)),
      put_message_list(field!(msg, :ops), &encode_build_op/1),
      put_u32(field!(msg, :root))
    ])
  end

  def decode_definition(bytes) when is_binary(bytes) do
    with {:ok, rest} <- read_header(bytes, @definition_msg_id, @definition_version),
         {:ok, version, rest} <- read_u32(rest),
         {:ok, ops, rest} <- read_message_list(rest, &decode_build_op/1),
         {:ok, root, rest} <- read_u32(rest),
         :ok <- read_eof(rest) do
      {:ok, %{
        version: version,
        ops: ops,
        root: root,
      }}
    end
  end

  def definition_msg_id, do: @definition_msg_id
  def definition_version, do: @definition_version

  # DEFINITION
end
