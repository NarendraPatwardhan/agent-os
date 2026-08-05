defmodule AgentOS.Git.SmartHttp do
  @moduledoc """
  Server smart-HTTP transport for git remotes (SYSTEMS.md §11b).

  Product path uses OTP `:httpc` + `:ssl` — the same host family as control-plane
  HTTPS egress for the kernel. **No Node. No C TLS.**

  Security (P0.1 / D3 / D11):
  * Only `http`/`https` schemes; reject userinfo; require host
  * Origin allowlist (`:allowed_origins`) fail-closed by default
  * Non-2xx HTTP status → error
  * Response/pack size capped (default 64 MiB) — enforced **while streaming**
    upload-pack (never buffer 64 MiB+1 in BEAM; fail `:body_too_large`)
  * `extract_pack/1` / `locate_pack_offset/1` error when no `PACK` magic
    (never treat the whole body as a pack)
  * **Redirect policy (fail-closed):** product smart-HTTP **never follows**
    redirects. `:httpc` is dialed with `autoredirect: false`, and any 3xx
    response is rejected as `:redirect_not_allowed` without reading `Location`
    or issuing a second request. Open redirect to a non-allowlisted origin is
    therefore impossible: there is no hop, so no allowlist re-check is needed.
    (An alternate design would re-validate origin on each hop; we prefer the
    simpler reject-all policy for product remotes.)

  **D11 streaming:** product `fetch_packs/4` streams the HTTP body to a temp
  file via `:httpc` `{self, once}`, then returns `{:file, path, pack_offset}`
  for chunked `GitEngine.import_pack`. Fixture transports may still return a
  binary pack.

  Injectable `transport` callback for tests (fixture double). The
  `allowed_origins: :any` / `require_origin_allowlist: false` escape hatches are
  **only** honored when a fixture `:transport` is injected — product dials always
  need an explicit matching allowlist. Prefer tests pass
  `allowed_origins: ["https://example.com"]` matching the fixture URL.
  """

  @type ref :: %{
          required(:name) => String.t(),
          required(:hash) => String.t(),
          optional(:capabilities) => [String.t()]
        }
  @type push_command :: %{old_hash: String.t(), new_hash: String.t(), name: String.t()}
  @type receive_status :: %{ok: boolean(), message: String.t() | nil}
  @type auth ::
          %{kind: :none}
          | %{kind: :bearer, token: String.t()}
          | %{kind: :header, name: String.t(), value: String.t()}
          | %{kind: :basic, username: String.t(), password: String.t()}

  @type transport :: (atom(), term() -> {:ok, term()} | {:error, term()})

  # contracts/git.kdl default_max_pack_bytes (dual-host with TS pack-cache).
  @default_max_pack_bytes AgentOS.Contracts.Git.default_max_pack_bytes()
  @max_credential_bytes 16 * 1024
  @max_header_name_bytes 256

  @doc "Default max response/pack body size in bytes (64 MiB)."
  def default_max_pack_bytes, do: @default_max_pack_bytes

  @doc """
  Build request headers from an auth map (R43).

  Supports `:none`, `:bearer`, `:header`, and `:basic` (user/pass → Base64
  `Authorization: Basic …`). Mirrors JS `spliceCredentialHeaders` where the
  kinds overlap. Accepts atom or string keys/kinds.

  **Never** puts credentials into the URL — headers only. Used by list/fetch/push.
  """
  @spec auth_headers(map() | nil) :: [{String.t(), String.t()}]
  def auth_headers(auth) do
    case normalize_auth(auth) do
      :invalid ->
        raise ArgumentError, AgentOS.Contracts.Git.stderr_line(:invalid_auth) |> String.trim()

      normalized ->
        do_auth_headers(normalized)
    end
  end

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

  @doc "List refs via upload-pack (default) or receive-pack discovery."
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

  @typedoc """
  Pack payload source.

  * `binary()` — in-memory pack (fixture transports, cache hits)
  * `{:file, path, offset}` — on-disk response body; pack starts at `offset`
    (product smart-HTTP stream). Caller owns cleanup via `cleanup_pack_source/1`.
  """
  @type pack_source :: binary() | {:file, String.t(), non_neg_integer()}

  @doc """
  Fetch a pack (upload-pack).

  Product path **streams** the HTTP body to a temp file with a running size
  cap (`:max_pack_bytes`, default **64 MiB**). Exceeding the cap fails closed
  as `:body_too_large` without retaining an oversize body in BEAM memory.
  Returns `{:ok, {:file, path, offset}}` where `offset` points at `PACK` magic.

  Fixture `:transport` may still return `{:ok, binary()}`.

  Callers that import must feed `GitEngine.import_pack/3` in chunks (see
  Orchestrator) and call `cleanup_pack_source/1` on file sources when done.
  """
  @spec fetch_packs(String.t(), [String.t()], [String.t()], keyword()) ::
          {:ok, pack_source()} | {:error, term()}
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
  Release a pack source produced by `fetch_packs/4`.

  No-op for binaries. Deletes the temp file for `{:file, path, offset}`.
  """
  @spec cleanup_pack_source(pack_source() | nil | term()) :: :ok
  def cleanup_pack_source({:file, path, _offset}) when is_binary(path) do
    _ = File.rm(path)
    :ok
  end

  def cleanup_pack_source(_), do: :ok

  @doc "Byte size of the pack payload (from PACK magic for file sources)."
  @spec pack_byte_size(pack_source()) :: non_neg_integer()
  def pack_byte_size(pack) when is_binary(pack), do: byte_size(pack)

  def pack_byte_size({:file, path, offset})
      when is_binary(path) and is_integer(offset) and offset >= 0 do
    case File.stat(path) do
      {:ok, %{size: size}} when size > offset -> size - offset
      _ -> 0
    end
  end

  def pack_byte_size(_), do: 0

  @doc """
  Read full pack bytes from a pack source (capped sources only — max 64 MiB).

  Used by pack-cache put. Prefer chunked import for the engine path.
  """
  @spec read_pack_source(pack_source()) :: {:ok, binary()} | {:error, term()}
  def read_pack_source(pack) when is_binary(pack), do: {:ok, pack}

  def read_pack_source({:file, path, offset})
      when is_binary(path) and is_integer(offset) and offset >= 0 do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, device} ->
        try do
          case :file.position(device, offset) do
            {:ok, _} ->
              case :file.read(device, @default_max_pack_bytes + 1) do
                {:ok, data} when is_binary(data) ->
                  if byte_size(data) > @default_max_pack_bytes do
                    {:error, :body_too_large}
                  else
                    {:ok, data}
                  end

                :eof ->
                  {:ok, <<>>}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end
        after
          File.close(device)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def read_pack_source(_), do: {:error, :bad_pack_source}

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

    service =
      case Keyword.get(opts, :service, :upload_pack) do
        s when s in [:receive_pack, "git-receive-pack"] -> "git-receive-pack"
        _ -> "git-upload-pack"
      end

    info = base <> "/info/refs?service=" <> service
    headers = auth_headers(Keyword.get(opts, :auth, %{kind: :none}))
    max = max_bytes(opts)

    case request(:get, info, headers, "", max) do
      {:ok, body} when is_binary(body) ->
        {:ok, parse_info_refs(body)}

      {:error, reason} ->
        {:error, {:list_refs_failed, reason}}
    end
  end

  # D11: stream upload-pack body to a temp file with a running size cap, then
  # locate PACK magic by offset — never hold an unbounded response in BEAM.
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

    case stream_request_to_file(:post, base <> "/git-upload-pack", headers, body, max) do
      {:ok, path} ->
        case locate_pack_offset(path) do
          {:ok, offset} ->
            pack_size = pack_byte_size({:file, path, offset})

            cond do
              pack_size == 0 ->
                _ = File.rm(path)
                {:error, {:upload_pack_failed, :no_pack_magic}}

              pack_size > max ->
                _ = File.rm(path)
                {:error, {:upload_pack_failed, :body_too_large}}

              true ->
                {:ok, {:file, path, offset}}
            end

          {:error, reason} ->
            _ = File.rm(path)
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
      advertised = Keyword.get(opts, :receive_capabilities, [])
      requested_status = receive_status_capability(advertised)

      body =
        build_receive_pack_body(
          commands,
          pack,
          requested_status
        )

      headers =
        [
          {"content-type", "application/x-git-receive-pack-request"},
          {"accept", "application/x-git-receive-pack-result"}
        ] ++ auth_headers(Keyword.get(opts, :auth, %{kind: :none}))

      case request(:post, base <> "/git-receive-pack", headers, body, max) do
        {:ok, resp} when is_binary(resp) ->
          {:ok, parse_receive_status(resp, is_binary(requested_status))}

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
    http_opts = http_options(url)
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

  # Stream response body to a temp file with a running size cap (D11).
  # 200/206 bodies are drained via `{self, once}` so we can abort mid-stream
  # when `max_bytes` is exceeded — never buffer 64MiB+1 in BEAM.
  defp stream_request_to_file(method, url, headers, body, max_bytes)
       when is_binary(url) and is_integer(max_bytes) and max_bytes > 0 do
    url_char = String.to_charlist(url)
    hdrs = Enum.map(headers, fn {k, v} -> {as_charlist(k), as_charlist(v)} end)
    http_opts = http_options(url)
    # once-mode: atom `self` (not pid) — we pull each chunk and can cancel
    # when over cap. See :httpc option `stream` / `{self, once}`.
    opts = [sync: false, stream: {:self, :once}]

    path =
      Path.join(
        System.tmp_dir!(),
        "agentos-pack-" <> Integer.to_string(System.unique_integer([:positive]))
      )

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
      {:ok, req_id} ->
        drain_http_stream(req_id, path, max_bytes)

      {:error, reason} ->
        _ = File.rm(path)
        {:error, reason}
    end
  rescue
    e ->
      {:error, e}
  end

  defp http_options(url) when is_binary(url) do
    base = [
      timeout: 60_000,
      connect_timeout: 30_000,
      autoredirect: false
    ]

    # Local fixture servers (http://127.0.0.1) have no TLS; only attach
    # verify_peer for https. Product remotes are https in practice.
    if String.starts_with?(String.downcase(url), "https://") do
      base ++ [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]]
    else
      base
    end
  end

  defp drain_http_stream(req_id, path, max_bytes) do
    receive do
      {:http, {^req_id, stream_start, headers, handler}}
      when stream_start == :stream_start and is_pid(handler) ->
        case content_length_over?(headers, max_bytes) do
          true ->
            _ = :httpc.cancel_request(req_id)
            _ = File.rm(path)
            {:error, :body_too_large}

          false ->
            case File.open(path, [:write, :raw, :binary]) do
              {:ok, device} ->
                try do
                  _ = :httpc.stream_next(handler)
                  stream_body_loop(req_id, handler, device, path, max_bytes, 0)
                after
                  File.close(device)
                end

              {:error, reason} ->
                _ = :httpc.cancel_request(req_id)
                {:error, reason}
            end
        end

      {:http, {^req_id, :stream_start, headers}} ->
        # stream: self (not once) — still drain with size cap.
        case content_length_over?(headers, max_bytes) do
          true ->
            _ = :httpc.cancel_request(req_id)
            _ = File.rm(path)
            {:error, :body_too_large}

          false ->
            case File.open(path, [:write, :raw, :binary]) do
              {:ok, device} ->
                try do
                  stream_body_loop(req_id, nil, device, path, max_bytes, 0)
                after
                  File.close(device)
                end

              {:error, reason} ->
                _ = :httpc.cancel_request(req_id)
                {:error, reason}
            end
        end

      {:http, {^req_id, {{_v, status, _reason}, _headers, resp_body}}} ->
        # Non-streamed response (redirects, errors, non-200). No file retained.
        _ = File.rm(path)

        case classify_http_response(status, resp_body, max_bytes) do
          {:ok, body} when is_binary(body) ->
            # Unexpected 2xx without stream — persist for pack extract.
            case File.write(path, body) do
              :ok -> {:ok, path}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:http, {^req_id, {:error, reason}}} ->
        _ = File.rm(path)
        {:error, reason}

      {:http, {^req_id, other}} ->
        _ = File.rm(path)
        {:error, {:unexpected_http, other}}
    after
      60_000 ->
        _ = :httpc.cancel_request(req_id)
        _ = File.rm(path)
        {:error, :timeout}
    end
  end

  defp stream_body_loop(req_id, handler, device, path, max_bytes, size) do
    receive do
      {:http, {^req_id, :stream, chunk}} when is_binary(chunk) ->
        new_size = size + byte_size(chunk)

        if new_size > max_bytes do
          _ = :httpc.cancel_request(req_id)
          _ = File.rm(path)
          {:error, :body_too_large}
        else
          case IO.binwrite(device, chunk) do
            :ok ->
              if is_pid(handler), do: _ = :httpc.stream_next(handler)
              stream_body_loop(req_id, handler, device, path, max_bytes, new_size)

            {:error, reason} ->
              _ = :httpc.cancel_request(req_id)
              _ = File.rm(path)
              {:error, reason}
          end
        end

      {:http, {^req_id, :stream_end, _headers}} ->
        {:ok, path}

      {:http, {^req_id, {:error, reason}}} ->
        _ = File.rm(path)
        {:error, reason}

      {:http, {^req_id, other}} ->
        _ = File.rm(path)
        {:error, {:unexpected_http, other}}
    after
      60_000 ->
        _ = :httpc.cancel_request(req_id)
        _ = File.rm(path)
        {:error, :timeout}
    end
  end

  defp content_length_over?(headers, max_bytes) when is_list(headers) do
    Enum.any?(headers, fn
      {k, v} ->
        key =
          cond do
            is_list(k) -> List.to_string(k)
            is_binary(k) -> k
            true -> ""
          end

        if String.downcase(key) == "content-length" do
          val =
            cond do
              is_list(v) -> List.to_string(v)
              is_binary(v) -> v
              true -> ""
            end

          case Integer.parse(String.trim(val)) do
            {n, _} when n > max_bytes -> true
            _ -> false
          end
        else
          false
        end

      _ ->
        false
    end)
  end

  defp content_length_over?(_, _), do: false

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

  @doc """
  Locate the byte offset of `PACK` magic in a file without loading it whole.

  Scans in 64 KiB windows (with a 3-byte overlap). Returns
  `{:ok, offset}` or `{:error, :no_pack_magic}`.
  """
  @spec locate_pack_offset(String.t()) :: {:ok, non_neg_integer()} | {:error, :no_pack_magic}
  def locate_pack_offset(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size >= 4 ->
        case File.open(path, [:read, :raw, :binary]) do
          {:ok, device} ->
            try do
              scan_pack_magic(device, 0, size, <<>>)
            after
              File.close(device)
            end

          {:error, _} ->
            {:error, :no_pack_magic}
        end

      _ ->
        {:error, :no_pack_magic}
    end
  end

  def locate_pack_offset(_), do: {:error, :no_pack_magic}

  defp scan_pack_magic(_device, pos, size, _tail) when pos >= size do
    {:error, :no_pack_magic}
  end

  defp scan_pack_magic(device, pos, size, tail) do
    window = 64 * 1024
    to_read = min(window, size - pos)

    case :file.read(device, to_read) do
      {:ok, chunk} when is_binary(chunk) and chunk != <<>> ->
        data = tail <> chunk

        case :binary.match(data, "PACK") do
          {idx, _} ->
            # File offset of match: current window started at pos, but data
            # is prefixed with `tail` carried from the previous window.
            {:ok, pos - byte_size(tail) + idx}

          :nomatch ->
            # Keep last 3 bytes so PACK split across a window boundary is found.
            keep = min(3, byte_size(data))
            new_tail = binary_part(data, byte_size(data) - keep, keep)
            scan_pack_magic(device, pos + byte_size(chunk), size, new_tail)
        end

      _ ->
        {:error, :no_pack_magic}
    end
  end

  defp as_charlist(s) when is_binary(s), do: String.to_charlist(s)
  defp as_charlist(s) when is_list(s), do: s

  defp normalize_auth(nil), do: %{kind: :none}

  defp normalize_auth(auth) when is_map(auth) do
    with normalized when is_map(normalized) <- normalize_auth_keys(auth),
         kind when kind != :invalid <- parse_auth_kind(Map.get(normalized, "kind")) do
      normalize_auth_fields(kind, normalized)
    else
      _ -> :invalid
    end
  end

  defp normalize_auth(_), do: :invalid

  defp normalize_auth_fields(:none, auth) do
    if exact_auth_keys?(auth, ["kind"]), do: %{kind: :none}, else: :invalid
  end

  defp normalize_auth_fields(:bearer, auth) do
    token = Map.get(auth, "token")

    if exact_auth_keys?(auth, ["kind", "token"]) and valid_auth_secret?(token),
      do: %{kind: :bearer, token: token},
      else: :invalid
  end

  defp normalize_auth_fields(:header, auth) do
    name = Map.get(auth, "name")
    value = Map.get(auth, "value")

    if exact_auth_keys?(auth, ["kind", "name", "value"]) and valid_auth_header?(name) and
         valid_auth_secret?(value),
       do: %{kind: :header, name: name, value: value},
       else: :invalid
  end

  defp normalize_auth_fields(:basic, auth) do
    username = Map.get(auth, "username")
    password = Map.get(auth, "password")

    if exact_auth_keys?(auth, ["kind", "username", "password"]) and
         valid_auth_secret?(username) and valid_auth_secret?(password) and
         not String.contains?(username, ":"),
       do: %{kind: :basic, username: username, password: password},
       else: :invalid
  end

  defp normalize_auth_keys(auth) do
    Enum.reduce_while(auth, %{}, fn
      {key, value}, acc when is_atom(key) or is_binary(key) ->
        normalized = if is_atom(key), do: Atom.to_string(key), else: key

        if Map.has_key?(acc, normalized) do
          {:halt, :invalid}
        else
          {:cont, Map.put(acc, normalized, value)}
        end

      _, _acc ->
        {:halt, :invalid}
    end)
  end

  defp exact_auth_keys?(auth, expected),
    do: MapSet.new(Map.keys(auth)) == MapSet.new(expected)

  defp valid_auth_secret?(value) when is_binary(value),
    do:
      value != "" and byte_size(value) <= @max_credential_bytes and String.valid?(value) and
        not String.match?(value, ~r/[\x00-\x1f\x7f]/)

  defp valid_auth_secret?(_), do: false

  defp valid_auth_header?(value) when is_binary(value),
    do:
      byte_size(value) <= @max_header_name_bytes and
        String.match?(value, ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/)

  defp valid_auth_header?(_), do: false

  defp parse_auth_kind(k) when k in [:none, :bearer, :header, :basic], do: k
  defp parse_auth_kind("none"), do: :none
  defp parse_auth_kind("bearer"), do: :bearer
  defp parse_auth_kind("header"), do: :header
  defp parse_auth_kind("basic"), do: :basic
  defp parse_auth_kind(_), do: :invalid

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
    |> decode_pkt_or_plain_lines()
    |> Enum.reduce([], fn raw, acc ->
      line = String.trim(raw)

      cond do
        line == "" ->
          acc

        String.contains?(line, "git-upload-pack") or
            String.contains?(line, "git-receive-pack") ->
          acc

        true ->
          case Regex.run(~r/^([0-9a-fA-F]{40})\s+(.+)$/, line) do
            [_, hash, raw_name] ->
              [name | cap_tail] = String.split(raw_name, "\0", parts: 2)

              capabilities =
                case cap_tail do
                  [caps] -> String.split(String.trim(caps), ~r/\s+/, trim: true)
                  _ -> []
                end

              if name == "HEAD" or String.starts_with?(name, "refs/") do
                [
                  %{name: name, hash: String.downcase(hash), capabilities: capabilities}
                  | acc
                ]
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

  # R36: optional filter after wants (partial clone). First want advertises
  # capability `filter` when set. Fixtures/servers that ignore filter stay ok.
  defp build_upload_pack_body(want, have, depth, filter) do
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

  defp receive_status_capability(advertised) when is_list(advertised) do
    cond do
      "report-status-v2" in advertised -> "report-status-v2"
      "report-status" in advertised -> "report-status"
      true -> nil
    end
  end

  defp receive_status_capability(_), do: nil

  defp build_receive_pack_body(commands, pack, requested)
       when is_list(commands) and is_binary(pack) and
              (is_binary(requested) or is_nil(requested)) do
    cmd_lines =
      commands
      |> Enum.with_index()
      |> Enum.map(fn {c, i} ->
        old_h =
          command_field(c, :old_hash) || command_field(c, "old_hash") ||
            command_field(c, "oldHash")

        new_h =
          command_field(c, :new_hash) || command_field(c, "new_hash") ||
            command_field(c, "newHash")

        name = command_field(c, :name) || command_field(c, "name") || ""

        if i == 0 and is_binary(requested) do
          pkt("#{old_h} #{new_h} #{name}\0#{requested}")
        else
          pkt("#{old_h} #{new_h} #{name}")
        end
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

  Mirrors TS `parseReceiveStatus`: unpack failure / `ng ` lines fail closed.
  When report-status was negotiated, a missing `unpack` receipt also fails.
  """
  @spec parse_receive_status(binary(), boolean()) :: receive_status()
  def parse_receive_status(text, required) when is_binary(text) and is_boolean(required) do
    lines = decode_pkt_or_plain_lines(text)
    unpack = Enum.find(lines, &String.starts_with?(&1, "unpack "))
    ng = Enum.find(lines, &String.starts_with?(&1, "ng "))

    cond do
      is_binary(unpack) and unpack != "unpack ok" ->
        %{ok: false, message: String.slice(unpack, 0, 200)}

      is_binary(ng) ->
        %{ok: false, message: String.slice(ng, 0, 200)}

      required and not is_binary(unpack) ->
        %{ok: false, message: "missing report-status"}

      true ->
        %{ok: true, message: "ok"}
    end
  end

  def parse_receive_status(_, _), do: %{ok: false, message: "invalid report-status"}

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
