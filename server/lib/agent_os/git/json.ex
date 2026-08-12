defmodule AgentOS.Git.Json do
  @moduledoc false

  @max_bytes 262_144
  @max_depth 16

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, value, rest} <- value(skip(bytes), 0), <<>> <- skip(rest) do
      {:ok, value}
    else
      _ -> {:error, :invalid_json}
    end
  end

  def decode(_), do: {:error, :invalid_json}

  def encode(value), do: IO.iodata_to_binary(encode_value(value))

  defp value(_, depth) when depth > @max_depth, do: {:error, :invalid_json}
  defp value(<<?{, rest::binary>>, depth), do: object(skip(rest), depth + 1, %{})
  defp value(<<?[, rest::binary>>, depth), do: array(skip(rest), depth + 1, [])
  defp value(<<?", _::binary>> = bytes, _depth), do: string(bytes)
  defp value(<<"true", rest::binary>>, _depth), do: {:ok, true, rest}
  defp value(<<"false", rest::binary>>, _depth), do: {:ok, false, rest}
  defp value(<<"null", rest::binary>>, _depth), do: {:ok, nil, rest}
  defp value(bytes, _depth), do: number(bytes)

  defp object(<<?}, rest::binary>>, _depth, map), do: {:ok, map, rest}
  defp object(bytes, depth, map) do
    with {:ok, key, rest} <- string(bytes),
         <<?:, rest::binary>> <- skip(rest),
         false <- Map.has_key?(map, key),
         {:ok, item, rest} <- value(skip(rest), depth) do
      case skip(rest) do
        <<?,, tail::binary>> -> object(skip(tail), depth, Map.put(map, key, item))
        <<?}, tail::binary>> -> {:ok, Map.put(map, key, item), tail}
        _ -> {:error, :invalid_json}
      end
    else
      _ -> {:error, :invalid_json}
    end
  end

  defp array(<<?], rest::binary>>, _depth, items), do: {:ok, Enum.reverse(items), rest}
  defp array(bytes, depth, items) do
    with {:ok, item, rest} <- value(bytes, depth) do
      case skip(rest) do
        <<?,, tail::binary>> -> array(skip(tail), depth, [item | items])
        <<?], tail::binary>> -> {:ok, Enum.reverse([item | items]), tail}
        _ -> {:error, :invalid_json}
      end
    end
  end

  defp string(<<?", rest::binary>>), do: string_chars(rest, [])
  defp string(_), do: {:error, :invalid_json}
  defp string_chars(<<?", rest::binary>>, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  defp string_chars(<<c, _::binary>>, _acc) when c < 0x20, do: {:error, :invalid_json}
  defp string_chars(<<?\\, esc, rest::binary>>, acc) when esc in [?", ?\\, ?/], do: string_chars(rest, [<<esc>> | acc])
  defp string_chars(<<?\\, ?b, rest::binary>>, acc), do: string_chars(rest, [<<8>> | acc])
  defp string_chars(<<?\\, ?f, rest::binary>>, acc), do: string_chars(rest, [<<12>> | acc])
  defp string_chars(<<?\\, ?n, rest::binary>>, acc), do: string_chars(rest, ["\n" | acc])
  defp string_chars(<<?\\, ?r, rest::binary>>, acc), do: string_chars(rest, ["\r" | acc])
  defp string_chars(<<?\\, ?t, rest::binary>>, acc), do: string_chars(rest, ["\t" | acc])
  defp string_chars(<<?\\, ?u, hex::binary-size(4), rest::binary>>, acc) do
    case Integer.parse(hex, 16) do
      {cp, ""} when cp < 0xD800 or cp > 0xDFFF -> string_chars(rest, [<<cp::utf8>> | acc])
      _ -> {:error, :invalid_json}
    end
  end
  defp string_chars(<<c::utf8, rest::binary>>, acc), do: string_chars(rest, [<<c::utf8>> | acc])
  defp string_chars(_, _), do: {:error, :invalid_json}

  defp number(bytes) do
    {token, rest} = take_number(bytes, <<>>)
    case Integer.parse(token) do
      {value, ""} -> {:ok, value, rest}
      _ -> {:error, :invalid_json}
    end
  end
  defp take_number(<<c, rest::binary>>, acc) when c in '-0123456789', do: take_number(rest, <<acc::binary, c>>)
  defp take_number(rest, acc), do: {acc, rest}

  defp skip(<<c, rest::binary>>) when c in [32, 9, 10, 13], do: skip(rest)
  defp skip(rest), do: rest

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_value(value) when is_binary(value), do: [?\", escape(value), ?\"]
  defp encode_value(values) when is_list(values), do: [?[, Enum.intersperse(Enum.map(values, &encode_value/1), ?,), ?]]
  defp encode_value(map) when is_map(map) do
    fields = map |> Enum.sort_by(fn {key, _} -> to_string(key) end) |> Enum.map(fn {key, value} -> [encode_value(to_string(key)), ?:, encode_value(value)] end)
    [?{, Enum.intersperse(fields, ?,), ?}]
  end
  defp escape(value), do: for(<<c::utf8 <- value>>, into: [], do: escape_char(c))
  defp escape_char(?"), do: "\\\""
  defp escape_char(?\\), do: "\\\\"
  defp escape_char(?\n), do: "\\n"
  defp escape_char(?\r), do: "\\r"
  defp escape_char(?\t), do: "\\t"
  defp escape_char(c) when c < 0x20, do: "\\u" <> String.pad_leading(Integer.to_string(c, 16), 4, "0")
  defp escape_char(c), do: <<c::utf8>>
end
