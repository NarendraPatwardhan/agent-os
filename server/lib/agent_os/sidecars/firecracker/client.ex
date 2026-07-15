defmodule AgentOS.Sidecars.Firecracker.Client do
  @moduledoc false

  @timeout 5_000

  def put(socket_path, path, body) do
    encoded = json(body)

    request = [
      "PUT ",
      path,
      " HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
      Integer.to_string(IO.iodata_length(encoded)),
      "\r\n\r\n",
      encoded
    ]

    case :gen_tcp.connect(
           {:local, String.to_charlist(socket_path)},
           0,
           [:binary, active: false, packet: :raw],
           @timeout
         ) do
      {:ok, socket} ->
        try do
          with :ok <- :gen_tcp.send(socket, request),
               {:ok, response} <- receive_headers(socket, <<>>, 65_536),
               :ok <- accepted(response) do
            :ok
          else
            {:error, reason} -> {:error, {:firecracker_api, reason}}
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, reason} ->
        {:error, {:firecracker_api, reason}}
    end
  end

  defp receive_headers(_socket, _acc, 0), do: {:error, :response_headers_too_large}

  defp receive_headers(socket, acc, remaining) do
    case :gen_tcp.recv(socket, 1, @timeout) do
      {:ok, byte} ->
        next = acc <> byte

        if String.ends_with?(next, "\r\n\r\n"),
          do: {:ok, next},
          else: receive_headers(socket, next, remaining - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp accepted(response) do
    case :binary.split(response, "\r\n", [:global]) do
      [<<"HTTP/1.1 ", status::binary-size(3), _rest::binary>> | _]
      when status in ["200", "201", "204"] ->
        :ok

      [line | _] ->
        {:error, {:unexpected_status, line}}

      _ ->
        {:error, :invalid_response}
    end
  end

  defp json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, item} -> [json(to_string(key)), ?:, json(item)] end)

    [?{, Enum.intersperse(entries, ?,), ?}]
  end

  defp json(value) when is_binary(value), do: [?", escape(value), ?"]
  defp json(value) when is_integer(value), do: Integer.to_string(value)
  defp json(true), do: "true"
  defp json(false), do: "false"
  defp json(nil), do: "null"

  defp escape(value) do
    for <<char <- value>>, into: [] do
      case char do
        ?" -> "\\\""
        ?\\ -> "\\\\"
        ?\n -> "\\n"
        ?\r -> "\\r"
        ?\t -> "\\t"
        byte when byte < 0x20 -> ["\\u00", Base.encode16(<<byte>>, case: :lower)]
        byte -> <<byte>>
      end
    end
  end
end
