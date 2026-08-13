defmodule AgentOS.Git.HttpTest do
  use ExUnit.Case, async: false

  alias AgentOS.Git.Http

  test "default executor streams a bounded response to a file and preserves status" do
    body = :binary.copy("bounded-http-body", 32_768)
    {url, server} = serve_once(200, body)

    assert {:ok, %{status: 200, body: {:file, path}}} =
             Http.perform(%{method: "GET", path: url, headers: %{}}, <<>>,
               allowed_origins: [origin(url)],
               max_response_bytes: byte_size(body)
             )

    assert File.read!(path) == body
    File.rm!(path)
    assert_receive {^server, :served}, 5_000
  end

  test "default executor rejects redirects without retaining a response spool" do
    {url, server} = serve_once(302, "redirect")

    assert {:error, :redirect_not_allowed} =
             Http.perform(%{method: "GET", path: url, headers: %{}}, <<>>,
               allowed_origins: [origin(url)]
             )

    assert_receive {^server, :served}, 5_000
  end

  test "stream delivers begin and bounded chunks without retaining a response spool" do
    body = :binary.copy("streamed-http-body", 32_768)
    {url, server} = serve_once(200, body)

    consumer = fn
      {:begin, status, _headers}, %{events: events} = acc ->
        {:cont, %{acc | events: [{:begin, status} | events]}}

      {:chunk, bytes}, %{events: events, body: received} = acc ->
        {:cont, %{acc | events: [{:chunk, byte_size(bytes)} | events], body: received <> bytes}}
    end

    initial = %{events: [], body: <<>>}

    assert {:ok, %{events: events, body: ^body}} =
             Http.stream(
               %{method: "GET", path: url, headers: %{}},
               <<>>,
               [allowed_origins: [origin(url)], max_response_bytes: byte_size(body)],
               initial,
               consumer
             )

    assert [{:begin, 200} | chunks] = Enum.reverse(events)
    assert length(chunks) > 1
    assert Enum.all?(chunks, fn {:chunk, size} -> size <= 64 * 1024 end)
    assert_receive {^server, :served}, 5_000
  end

  test "stream stops after consumer rejection" do
    body = :binary.copy("halt-http-body", 16_384)
    {url, server} = serve_once(200, body)

    consumer = fn
      {:begin, _status, _headers}, count -> {:cont, count}
      {:chunk, _bytes}, count -> {:halt, :engine_finished, count + 1}
    end

    assert {:halt, :engine_finished, 1} =
             Http.stream(
               %{method: "GET", path: url, headers: %{}},
               <<>>,
               [allowed_origins: [origin(url)], max_response_bytes: byte_size(body)],
               0,
               consumer
             )

    assert_receive {^server, :served}, 5_000
  end

  defp serve_once(status, body) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        reason = if status == 200, do: "OK", else: "Found"

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} #{reason}\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
        send(parent, {self(), :served})
      end)

    {"http://127.0.0.1:#{port}/repo.git/info/refs", server}
  end

  defp origin(url) do
    uri = URI.parse(url)
    "#{uri.scheme}://#{uri.host}:#{uri.port}"
  end
end
