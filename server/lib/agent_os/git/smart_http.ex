defmodule AgentOS.Git.SmartHttp do
  @moduledoc """
  Server smart-HTTP transport for git remotes (GIT.md K16 revised).

  Product path uses OTP `:httpc` + `:ssl` — the same host family as control-plane
  HTTPS egress for the kernel. **No Node. No C TLS.**

  Security (P0.1 / D3):
  * Only `http`/`https` schemes; reject userinfo; require host
  * Origin allowlist (`:allowed_origins`) fail-closed by default
  * Non-2xx HTTP status → error
  * Response/pack size capped (default 64 MiB)
  * `extract_pack/1` errors when no `PACK` magic (never returns the whole body)
  * **Redirect policy (fail-closed):** product smart-HTTP **never follows**
    redirects. `:httpc` is dialed with `autoredirect: false`, and any 3xx
    response is rejected as `:redirect_not_allowed` without reading `Location`
    or issuing a second request. Open redirect to a non-allowlisted origin is
    therefore impossible: there is no hop, so no allowlist re-check is needed.
    (An alternate design would re-validate origin on each hop; we prefer the
    simpler reject-all policy for product remotes.)

  Injectable `transport` callback for tests (fixture double). The
  `allowed_origins: :any` / `require_origin_allowlist: false` escape hatches are
  **only** honored when a fixture `:transport` is injected — product dials always
  need an explicit matching allowlist. Prefer tests pass
  `allowed_origins: ["https://example.com"]` matching the fixture URL.
  """

  @type ref :: %{name: String.t(), hash: String.t()}
  @type push_command :: %{old_hash: String.t(), new_hash: String.t(), name: String.t()}
  @type receive_status :: %{ok: boolean(), message: String.t() | nil}
  @type auth ::
          %{kind: :none}
          | %{kind: :bearer, token: String.t()}
          | %{kind: :header, name: String.t(), value: String.t()}
          | %{kind: :basic, username: String.t(), password: String.t()}

  @type transport :: (atom(), term() -> {:ok, term()} | {:error, term()})

  # Match TS DEFAULT_MAX_PACK_BYTES / product pack-cache default.
  @default_max_pack_bytes 64 * 1024 * 1024

  @doc "Default max response/pack body size in bytes (64 MiB)."
  def default_max_pack_bytes, do: @default_max_pack_bytes

  @doc """
  Build request headers from an auth map (R43).

  Supports `:none`, `:bearer`, `:header`, and `:basic` (user/pass → Base64
  `Authorization: Basic …`). Mirrors JS `spliceCredentialHeaders` where the
  kinds overlap. Accepts atom or string keys/kinds.

  **Never** puts credentials into the URL — headers only. Used by list/fetch/push.
  """
  @spec auth_headers(map() | keyword() | nil) :: [{String.t(), String.t()}]
  def auth_headers(auth), do: do_auth_headers(normalize_auth(auth))

  # ── Origin / URL policy (mirror TS requestOrigin / originAllowed) ───────────

  @doc """
  Normalize an http(s) URL to its canonical origin (`scheme://host[:port]`).

  Rejects non-http(s), missing host, and any userinfo (embedded credentials).
  Host is lowercased; default ports (80/443) are omitted.
  Returns `{:ok, origin}` or `:error`.
  """
  @spec request_origin(String.t()) :: {:ok, String.t()} | :error
  def request_origin(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host, port: port, userinfo: userinfo}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if userinfo_present?(userinfo) do
          :error
        else
          {:ok, normalize_origin(scheme, host, port)}
        end

      _ ->
        :error
    end
  end

  def request_origin(_), do: :error

  @doc """
  Canonical origin equality allowlist (empty list → deny).

  Both the candidate URL and each allowlist entry are normalized via
  `request_origin/1` so `:443` / host case differences still match.
  """
  @spec origin_allowed?([String.t()], String.t()) :: boolean()
  def origin_allowed?(allowed_origins, url)
      when is_list(allowed_origins) and is_binary(url) do
    if allowed_origins == [] do
      false
    else
      case request_origin(url) do
        {:ok, target} ->
          Enum.any?(allowed_origins, fn origin ->
            case request_origin(origin) do
              {:ok, ^target} -> true
              _ -> false
            end
          end)

        :error ->
          false
      end
    end
  end

  def origin_allowed?(_, _), do: false

  @doc """
  Gate a remote URL before any HTTP dial (or before fixture transport).

  Options:
  * `:allowed_origins` — list of canonical origins, or `:any` (fixture-only)
  * `:require_origin_allowlist` — default `true`; empty/missing list fails closed
  * `:transport` — when a 2-arity fun is present, test escape hatches apply

  Returns `{:ok, origin}` or `{:error, reason}`.
  """
  @spec ensure_url_allowed(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def ensure_url_allowed(url, opts \\ []) when is_binary(url) and is_list(opts) do
    case request_origin(url) do
      :error ->
        {:error, :bad_remote_url}

      {:ok, origin} ->
        if allowlist_permits?(url, origin, opts) do
          {:ok, origin}
        else
          {:error, :origin_not_allowed}
        end
    end
  end

  defp allowlist_permits?(url, _origin, opts) do
    allowed = Keyword.get(opts, :allowed_origins)
    require? = Keyword.get(opts, :require_origin_allowlist, true)
    fixture? = injected_transport?(opts)

    case allowed do
      :any ->
        # Escape hatch: only with injected fixture transport.
        fixture?

      list when is_list(list) and list != [] ->
        origin_allowed?(list, url)

      list when is_list(list) and list == [] ->
        # Empty allowlist: fail closed unless explicitly opted out under fixture.
        not require? and fixture?

      nil ->
        # Missing allowlist: fail closed unless explicitly opted out under fixture.
        not require? and fixture?

      _ ->
        false
    end
  end

  defp injected_transport?(opts) do
    case Keyword.get(opts, :transport) do
      fun when is_function(fun, 2) -> true
      _ -> false
    end
  end

  defp userinfo_present?(nil), do: false
  defp userinfo_present?(""), do: false
  defp userinfo_present?(s) when is_binary(s), do: true
  defp userinfo_present?(_), do: true

  defp normalize_origin(scheme, host, port) do
    scheme = String.downcase(scheme)
    host = String.downcase(host)
    default = if scheme == "https", do: 443, else: 80

    if is_nil(port) or port == default do
      "#{scheme}://#{host}"
    else
      "#{scheme}://#{host}:#{port}"
    end
  end

  # ── Public transport API ───────────────────────────────────────────────────

  @doc "List refs via info/refs?service=git-upload-pack."
  @spec list_refs(String.t(), keyword()) :: {:ok, [ref()]} | {:error, term()}
  def list_refs(url, opts \\ []) when is_binary(url) do
    case Keyword.get(opts, :transport) do
      fun when is_function(fun, 2) ->
        fun.(:list_refs, {url, opts})

      _ ->
        with {:ok, _origin} <- ensure_url_allowed(url, opts) do
          http_list_refs(url, opts)
        end
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
        with {:ok, _origin} <- ensure_url_allowed(url, opts) do
          http_fetch_packs(url, want, have, opts)
        end
    end
  end

  @doc """
  Push ref updates via smart-HTTP `git-receive-pack` (PR12 / R46).

  Posts pkt-line commands + pack body. Auth is spliced only into request headers
  (never into the URL). Origin allowlist and `:max_pack_bytes` apply.

  Returns `{:ok, %{ok: true|false, message: ...}}` from report-status, or
  `{:error, reason}` for transport/policy failures.

  ## R41 — pack body buffering

  The receive-pack request body is built as a **single binary**
  (`commands pkt-lines + pack`). OTP `:httpc` posts that buffer in one shot.
  Size is gated by `:max_pack_bytes` (default **64 MiB**, same as upload-pack).
  Chunked/streamed request bodies for multi-GiB packs are not implemented;
  raise the cap only when memory allows, or push smaller tip sets.
  """
  @spec push_packs(String.t(), [push_command()], binary(), keyword()) ::
          {:ok, receive_status()} | {:error, term()}
  def push_packs(url, commands, pack, opts \\ [])
      when is_binary(url) and is_list(commands) and is_binary(pack) do
    case Keyword.get(opts, :transport) do
      fun when is_function(fun, 2) ->
        fun.(:push_packs, {url, commands, pack, opts})

      _ ->
        with {:ok, _origin} <- ensure_url_allowed(url, opts) do
          http_push_packs(url, commands, pack, opts)
        end
    end
  end

  # ── Real HTTPS (:httpc) ────────────────────────────────────────────────────

  defp http_list_refs(url, opts) do
    ensure_http_apps!()
    base = String.trim_trailing(url, "/")
    info = base <> "/info/refs?service=git-upload-pack"
    headers = auth_headers(Keyword.get(opts, :auth, %{kind: :none}))
    max = max_bytes(opts)

    case request(:get, info, headers, "", max) do
      {:ok, body} when is_binary(body) ->
        {:ok, parse_info_refs(body)}

      {:error, reason} ->
        {:error, {:list_refs_failed, reason}}
    end
  end

  defp http_fetch_packs(url, want, have, opts) do
    ensure_http_apps!()
    base = String.trim_trailing(url, "/")

    body =
      build_upload_pack_body(
        want,
        have,
        Keyword.get(opts, :depth),
        Keyword.get(opts, :filter)
      )

    headers =
      [
        {"content-type", "application/x-git-upload-pack-request"},
        {"accept", "application/x-git-upload-pack-result"}
      ] ++ auth_headers(Keyword.get(opts, :auth, %{kind: :none}))

    max = max_bytes(opts)

    case request(:post, base <> "/git-upload-pack", headers, body, max) do
      {:ok, resp} when is_binary(resp) ->
        case extract_pack(resp) do
          {:ok, pack} ->
            if byte_size(pack) > max do
              {:error, {:upload_pack_failed, :body_too_large}}
            else
              {:ok, pack}
            end

          {:error, reason} ->
            {:error, {:upload_pack_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:upload_pack_failed, reason}}
    end
  end

  defp http_push_packs(url, commands, pack, opts) do
    ensure_http_apps!()
    max = max_bytes(opts)

    if byte_size(pack) > max do
      {:error, {:receive_pack_failed, :body_too_large}}
    else
      base = String.trim_trailing(url, "/")
      body = build_receive_pack_body(commands, pack)

      headers =
        [
          {"content-type", "application/x-git-receive-pack-request"},
          {"accept", "application/x-git-receive-pack-result"}
        ] ++ auth_headers(Keyword.get(opts, :auth, %{kind: :none}))

      case request(:post, base <> "/git-receive-pack", headers, body, max) do
        {:ok, resp} when is_binary(resp) ->
          {:ok, parse_receive_status(resp)}

        {:error, reason} ->
          {:error, {:receive_pack_failed, reason}}
      end
    end
  end

  defp max_bytes(opts) do
    case Keyword.get(opts, :max_pack_bytes, @default_max_pack_bytes) do
      n when is_integer(n) and n > 0 -> n
      0 -> @default_max_pack_bytes
      _ -> @default_max_pack_bytes
    end
  end

  defp ensure_http_apps! do
    _ = Application.ensure_all_started(:inets)
    _ = Application.ensure_all_started(:ssl)
    :ok
  end

  defp request(method, url, headers, body, max_bytes) when is_binary(url) do
    url_char = String.to_charlist(url)
    hdrs = Enum.map(headers, fn {k, v} -> {as_charlist(k), as_charlist(v)} end)

    # D3: never follow redirects (no silent host/credential pivot). Peer verify
    # via system CAs. 3xx is classified below as :redirect_not_allowed.
    http_opts = [
      timeout: 60_000,
      connect_timeout: 30_000,
      autoredirect: false,
      ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
    ]

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
      {:ok, {{_v, status, _reason}, _resp_headers, resp_body}} ->
        classify_http_response(status, resp_body, max_bytes)

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  end

  # Pure response gate (unit-tested via local 3xx fixture). Redirects are never
  # followed — open redirect cannot bypass the origin allowlist.
  @doc false
  def classify_http_response(status, resp_body, max_bytes)
      when is_integer(status) and is_integer(max_bytes) do
    cond do
      status >= 300 and status < 400 ->
        {:error, :redirect_not_allowed}

      status < 200 or status >= 300 ->
        {:error, {:http_status, status}}

      not is_binary(resp_body) ->
        {:error, :bad_body}

      byte_size(resp_body) > max_bytes ->
        {:error, :body_too_large}

      true ->
        {:ok, resp_body}
    end
  end

  def classify_http_response(_, _, _), do: {:error, :bad_body}

  defp as_charlist(s) when is_binary(s), do: String.to_charlist(s)
  defp as_charlist(s) when is_list(s), do: s

  defp normalize_auth(nil), do: %{kind: :none}
  defp normalize_auth(auth) when is_list(auth), do: normalize_auth(Map.new(auth))

  defp normalize_auth(auth) when is_map(auth) do
    kind = parse_auth_kind(Map.get(auth, :kind) || Map.get(auth, "kind"))

    %{kind: kind}
    |> put_auth_field(auth, :token, ["token"])
    |> put_auth_field(auth, :name, ["name"])
    |> put_auth_field(auth, :value, ["value"])
    |> put_auth_field(auth, :username, ["username", "user"])
    |> put_auth_field(auth, :password, ["password", "pass"])
  end

  defp normalize_auth(_), do: %{kind: :none}

  defp parse_auth_kind(k) when k in [:none, :bearer, :header, :basic], do: k
  defp parse_auth_kind("none"), do: :none
  defp parse_auth_kind("bearer"), do: :bearer
  defp parse_auth_kind("header"), do: :header
  defp parse_auth_kind("basic"), do: :basic
  defp parse_auth_kind(_), do: :none

  defp put_auth_field(acc, auth, atom_key, string_keys) do
    val =
      Map.get(auth, atom_key) ||
        Enum.find_value(string_keys, fn k -> Map.get(auth, k) end)

    if is_binary(val), do: Map.put(acc, atom_key, val), else: acc
  end

  defp do_auth_headers(%{kind: :none}), do: []

  defp do_auth_headers(%{kind: :bearer, token: t}) when is_binary(t) and t != "" do
    [{"authorization", "Bearer " <> t}]
  end

  defp do_auth_headers(%{kind: :header, name: n, value: v})
       when is_binary(n) and n != "" and is_binary(v) do
    [{String.downcase(n), v}]
  end

  defp do_auth_headers(%{kind: :basic, username: u, password: p})
       when is_binary(u) and is_binary(p) do
    token = Base.encode64(u <> ":" <> p)
    [{"authorization", "Basic " <> token}]
  end

  defp do_auth_headers(_), do: []

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

  # R36: optional filter after wants (partial clone). First want advertises
  # capability `filter` when set. Fixtures/servers that ignore filter stay ok.
  defp build_upload_pack_body(want, have, depth, filter \\ nil) do
    filter_s =
      case filter do
        f when is_binary(f) ->
          f = String.trim(f)
          if f != "" and byte_size(f) <= 128 and not String.contains?(f, ["\n", "\r", <<0>>]),
            do: f,
            else: nil

        _ ->
          nil
      end

    want_lines =
      want
      |> Enum.with_index()
      |> Enum.map(fn {w, i} ->
        if i == 0 and is_binary(filter_s) do
          pkt("want #{w} filter")
        else
          pkt("want #{w}")
        end
      end)

    deepen = if is_integer(depth) and depth > 0, do: [pkt("deepen #{depth}")], else: []
    filter_line = if is_binary(filter_s), do: [pkt("filter #{filter_s}")], else: []
    have_lines = Enum.map(have, fn h -> pkt("have #{h}") end)

    IO.iodata_to_binary(
      want_lines ++ deepen ++ filter_line ++ ["0000"] ++ have_lines ++ [pkt("done")]
    )
  end

  defp build_receive_pack_body(commands, pack) when is_list(commands) and is_binary(pack) do
    cmd_lines =
      Enum.map(commands, fn c ->
        old_h = command_field(c, :old_hash) || command_field(c, "old_hash") || command_field(c, "oldHash")
        new_h = command_field(c, :new_hash) || command_field(c, "new_hash") || command_field(c, "newHash")
        name = command_field(c, :name) || command_field(c, "name") || ""
        pkt("#{old_h} #{new_h} #{name}")
      end)

    head = IO.iodata_to_binary(cmd_lines ++ ["0000"])
    head <> pack
  end

  defp command_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp command_field(_, _), do: nil

  defp pkt(s) do
    body = s <> "\n"
    len = byte_size(body) + 4
    :io_lib.format("~4.16.0b", [len]) |> IO.iodata_to_binary() |> Kernel.<>(body)
  end

  @doc """
  Parse smart receive-pack report-status body (pkt-line or plain).

  Mirrors TS `parseReceiveStatus`: unpack failure / `ng ` lines fail closed;
  missing report-status is treated as ok.
  """
  @spec parse_receive_status(binary()) :: receive_status()
  def parse_receive_status(text) when is_binary(text) do
    lines = decode_pkt_or_plain_lines(text)
    unpack = Enum.find(lines, &String.starts_with?(&1, "unpack "))
    ng = Enum.find(lines, &String.starts_with?(&1, "ng "))

    cond do
      is_binary(unpack) and unpack != "unpack ok" ->
        %{ok: false, message: String.slice(unpack, 0, 200)}

      is_binary(ng) ->
        %{ok: false, message: String.slice(ng, 0, 200)}

      true ->
        %{ok: true, message: "ok"}
    end
  end

  def parse_receive_status(_), do: %{ok: false, message: "empty report-status"}

  defp decode_pkt_or_plain_lines(text) when is_binary(text) do
    {lines, _i} = decode_pkt_lines(text, 0, [])

    if lines == [] do
      text
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      Enum.reverse(lines)
    end
  end

  defp decode_pkt_lines(text, i, acc) when i + 4 <= byte_size(text) do
    hex = binary_part(text, i, 4)

    if Regex.match?(~r/^[0-9a-fA-F]{4}$/, hex) do
      n = String.to_integer(hex, 16)

      cond do
        n == 0 ->
          decode_pkt_lines(text, i + 4, acc)

        n < 4 or i + n > byte_size(text) ->
          {acc, i}

        true ->
          body =
            binary_part(text, i + 4, n - 4)
            |> String.trim_trailing("\n")

          acc2 = if body != "", do: [body | acc], else: acc
          decode_pkt_lines(text, i + n, acc2)
      end
    else
      {acc, i}
    end
  end

  defp decode_pkt_lines(_text, i, acc), do: {acc, i}

  @doc """
  Slice a smart-HTTP response down to the pack payload starting at `PACK`.

  Returns `{:error, :no_pack_magic}` when the body has no pack — never the whole body.
  """
  @spec extract_pack(binary()) :: {:ok, binary()} | {:error, :no_pack_magic}
  def extract_pack(buf) when is_binary(buf) do
    case :binary.match(buf, "PACK") do
      {idx, _} -> {:ok, binary_part(buf, idx, byte_size(buf) - idx)}
      :nomatch -> {:error, :no_pack_magic}
    end
  end

  def extract_pack(_), do: {:error, :no_pack_magic}
end
