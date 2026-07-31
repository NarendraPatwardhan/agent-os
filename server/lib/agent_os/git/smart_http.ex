defmodule AgentOS.Git.SmartHttp do
  @moduledoc """
  Server smart-HTTP transport for git remotes (GIT.md K16 revised).

  Product path uses OTP `:httpc` + `:ssl` — the same host family as control-plane
  HTTPS egress for the kernel. **No Node. No C TLS.**

  Injectable `transport` callback for tests (fixture double).
  """

  @type ref :: %{name: String.t(), hash: String.t()}
  @type auth ::
          %{kind: :none}
          | %{kind: :bearer, token: String.t()}
          | %{kind: :header, name: String.t(), value: String.t()}

  @type transport :: (atom(), term() -> {:ok, term()} | {:error, term()})

  @doc "List refs via info/refs?service=git-upload-pack."
  @spec list_refs(String.t(), keyword()) :: {:ok, [ref()]} | {:error, term()}
  def list_refs(url, opts \\ []) when is_binary(url) do
    case Keyword.get(opts, :transport) do
      fun when is_function(fun, 2) ->
        fun.(:list_refs, {url, opts})

      _ ->
        http_list_refs(url, opts)
    end
  end

  @doc "Fetch a pack (upload-pack). Returns raw pack bytes (PACK…)."
  @spec fetch_packs(String.t(), [String.t()], [String.t()], keyword()) ::
          {:ok, binary()} | {:error, term()}
  def fetch_packs(url, want, have, opts \\ [])
      when is_binary(url) and is_list(want) and is_list(have) do
    case Keyword.get(opts, :transport) do
      fun when is_function(fun, 2) ->
        fun.(:fetch_packs, {url, want, have, opts})

      _ ->
        http_fetch_packs(url, want, have, opts)
    end
  end

  # ── Real HTTPS (:httpc) ────────────────────────────────────────────────────

  defp http_list_refs(url, opts) do
    ensure_http_apps!()
    base = String.trim_trailing(url, "/")
    info = base <> "/info/refs?service=git-upload-pack"
    headers = auth_headers(Keyword.get(opts, :auth, %{kind: :none}))

    case request(:get, info, headers, "") do
      {:ok, {_status, _hdrs, body}} when is_binary(body) ->
        {:ok, parse_info_refs(body)}

      {:error, reason} ->
        {:error, {:list_refs_failed, reason}}
    end
  end

  defp http_fetch_packs(url, want, have, opts) do
    ensure_http_apps!()
    base = String.trim_trailing(url, "/")
    body = build_upload_pack_body(want, have, Keyword.get(opts, :depth))
    headers =
      [
        {"content-type", "application/x-git-upload-pack-request"},
        {"accept", "application/x-git-upload-pack-result"}
      ] ++ auth_headers(Keyword.get(opts, :auth, %{kind: :none}))

    case request(:post, base <> "/git-upload-pack", headers, body) do
      {:ok, {_status, _hdrs, resp}} when is_binary(resp) ->
        {:ok, extract_pack(resp)}

      {:error, reason} ->
        {:error, {:upload_pack_failed, reason}}
    end
  end

  defp ensure_http_apps! do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp request(method, url, headers, body) when is_binary(url) do
    url_char = String.to_charlist(url)
    hdrs = Enum.map(headers, fn {k, v} -> {as_charlist(k), as_charlist(v)} end)
    http_opts = [timeout: 60_000, connect_timeout: 30_000, ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]]
    opts = [body_format: :binary]

    result =
      case method do
        :get ->
          :httpc.request(:get, {url_char, hdrs}, http_opts, opts)

        :post ->
          ctype =
            case List.keyfind(hdrs, ~c"content-type", 0) do
              {_, ct} -> ct
              _ -> ~c"application/octet-stream"
            end

          :httpc.request(:post, {url_char, hdrs, ctype, body}, http_opts, opts)
      end

    case result do
      {:ok, {{_v, status, _reason}, resp_headers, resp_body}} ->
        {:ok, {status, resp_headers, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  defp as_charlist(s) when is_binary(s), do: String.to_charlist(s)
  defp as_charlist(s) when is_list(s), do: s

  defp auth_headers(%{kind: :none}), do: []
  defp auth_headers(%{kind: :bearer, token: t}), do: [{"authorization", "Bearer " <> t}]
  defp auth_headers(%{kind: :header, name: n, value: v}), do: [{String.downcase(n), v}]
  defp auth_headers(_), do: []

  # ── pkt-line helpers ───────────────────────────────────────────────────────

  @doc false
  def parse_info_refs(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.reduce([], fn raw, acc ->
      line = strip_pkt_prefix(String.trim(raw))

      cond do
        line == "" ->
          acc

        String.contains?(line, "git-upload-pack") ->
          acc

        true ->
          case Regex.run(~r/^([0-9a-fA-F]{40})\s+(\S+)/, line) do
            [_, hash, name] ->
              name = name |> String.split("\0") |> hd()

              if name == "HEAD" or String.starts_with?(name, "refs/") do
                [%{name: name, hash: String.downcase(hash)} | acc]
              else
                acc
              end

            _ ->
              acc
          end
      end
    end)
    |> Enum.reverse()
  end

  defp strip_pkt_prefix(<<a, b, c, d, rest::binary>>)
       when a in ?0..?9 or a in ?a..?f or a in ?A..?F do
    if Regex.match?(~r/^[0-9a-fA-F]{4}/, <<a, b, c, d>>) do
      rest
    else
      <<a, b, c, d, rest::binary>>
    end
  end

  defp strip_pkt_prefix(line), do: line

  defp build_upload_pack_body(want, have, depth) do
    want_lines = Enum.map(want, fn w -> pkt("want #{w}") end)
    deepen = if is_integer(depth) and depth > 0, do: [pkt("deepen #{depth}")], else: []
    have_lines = Enum.map(have, fn h -> pkt("have #{h}") end)
    IO.iodata_to_binary(want_lines ++ deepen ++ ["0000"] ++ have_lines ++ [pkt("done")])
  end

  defp pkt(s) do
    body = s <> "\n"
    len = byte_size(body) + 4
    :io_lib.format("~4.16.0b", [len]) |> IO.iodata_to_binary() |> Kernel.<>(body)
  end

  defp extract_pack(buf) when is_binary(buf) do
    case :binary.match(buf, "PACK") do
      {idx, _} -> binary_part(buf, idx, byte_size(buf) - idx)
      :nomatch -> buf
    end
  end
end
