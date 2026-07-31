defmodule AgentOS.Git.Orchestrator do
  @moduledoc """
  Server GitRemoteOrchestrator (GIT.md §7 / K16 revised).

  Runs the same algorithm as TS `remote-orchestrator.ts`:
  ListRefs → FetchPacks → Port `import_pack` → `refs.import` / `clone.apply` | `fetch.apply`.

  **HTTPS is BEAM** (`AgentOS.Git.SmartHttp`). **Apply is C Port** (`AgentOS.GitEngine`).
  No Node. Engine never dials.

  Security / honesty (P0.1 / P0.2):
  * URL scheme/userinfo/host + origin allowlist are checked **before** any HTTP
  * Empty packs never short-circuit to `ok:true` — apply requires non-empty pack
    and a successful import
  """

  alias AgentOS.Git.SmartHttp
  alias AgentOS.GitEngine

  @type request :: map() | String.t()

  @doc """
  Handle a guest/SDK remote Request JSON against a live git-engine Port pid.

  Options:
  * `:transport` — injectable SmartHttp transport (tests)
  * `:auth` — `%{kind: :none | :bearer | :header, ...}`
  * `:allowed_origins` — list of canonical `http(s)://host[:port]` origins
    (required for product dials; empty/missing fails closed). Prefer explicit
    lists in tests. `:any` is fixture-transport only (see SmartHttp).
  * `:require_origin_allowlist` — default `true`; set `false` only with
    injected fixture transport
  * `:max_pack_bytes` — response/pack size cap (default 64 MiB)
  * `:read_only` — reject push when true
  """
  @spec run(pid(), request(), keyword()) :: {:ok, binary()} | {:error, term()}
  def run(engine_pid, request, opts \\ []) when is_pid(engine_pid) do
    with {:ok, req} <- decode_request(request) do
      op = req |> Map.get("op", Map.get(req, :op, "")) |> to_string() |> String.downcase()

      case op do
        "clone" -> clone(engine_pid, req, opts)
        "fetch" -> fetch(engine_pid, req, opts)
        "pull" -> fetch(engine_pid, req, opts)
        "push" ->
          {:ok,
           response(false, 1, "", "git: push via BEAM packbuilder not yet configured on server")}

        _ ->
          {:ok, response(false, 2, "", "unknown remote op: #{op}")}
      end
    end
  end

  defp clone(engine_pid, req, opts) do
    with {:ok, url} <- url_of(req),
         {:ok, _origin} <- SmartHttp.ensure_url_allowed(url, opts),
         {:ok, refs} <- SmartHttp.list_refs(url, opts),
         {:ok, tip} <- pick_tip(refs, ref_of(req)),
         {:ok, pack} <-
           SmartHttp.fetch_packs(url, [tip.hash], [], Keyword.put(opts, :depth, depth_of(req))),
         :ok <- require_non_empty_pack(pack),
         :ok <- apply_init(engine_pid),
         :ok <- apply_pack(engine_pid, pack),
         :ok <- apply_refs_and_checkout(engine_pid, tip, :clone) do
      {:ok, response(true, 0, "cloned #{redact_url(url)}\n", "")}
    else
      err -> map_remote_error(err, :clone)
    end
  end

  defp fetch(engine_pid, req, opts) do
    with {:ok, url} <- url_of(req),
         {:ok, _origin} <- SmartHttp.ensure_url_allowed(url, opts),
         {:ok, refs} <- SmartHttp.list_refs(url, opts),
         {:ok, tip} <- pick_tip(refs, ref_of(req)),
         have <- local_haves(engine_pid),
         {:ok, pack} <-
           SmartHttp.fetch_packs(url, [tip.hash], have, Keyword.put(opts, :depth, depth_of(req))),
         :ok <- require_non_empty_pack(pack),
         :ok <- apply_pack(engine_pid, pack),
         :ok <- apply_refs_and_checkout(engine_pid, tip, :fetch) do
      {:ok, response(true, 0, "fetched\n", "")}
    else
      err -> map_remote_error(err, :fetch)
    end
  end

  defp require_non_empty_pack(pack) when is_binary(pack) and pack != <<>>, do: :ok
  defp require_non_empty_pack(_), do: {:error, :empty_pack}

  defp map_remote_error(err, mode) do
    case err do
      {:error, {:list_refs_failed, r}} ->
        {:ok, response(false, 1, "", "git: list-refs failed: #{inspect(r)}\n")}

      {:error, {:upload_pack_failed, r}} ->
        {:ok, response(false, 1, "", "git: upload-pack failed: #{inspect(r)}\n")}

      {:error, :no_refs} ->
        {:ok, response(false, 1, "", "git: no refs in advertisement\n")}

      {:error, :ref_not_found} ->
        {:ok, response(false, 1, "", "git: ref not found\n")}

      {:error, :bad_url} ->
        {:ok, response(false, 2, "", "clone/fetch need args.url\n")}

      {:error, :bad_remote_url} ->
        {:ok,
         response(
           false,
           1,
           "",
           "git: remote url must be http(s) without embedded credentials\n"
         )}

      {:error, :origin_not_allowed} ->
        {:ok, response(false, 1, "", "git: origin not allowlisted\n")}

      {:error, :empty_pack} ->
        {:ok, response(false, 1, "", "git: empty pack from remote\n")}

      {:error, :no_pack_magic} ->
        {:ok, response(false, 1, "", "git: response missing PACK magic\n")}

      {:error, :body_too_large} ->
        {:ok, response(false, 1, "", "git: pack/body exceeds max_pack_bytes\n")}

      {:error, {:http_status, status}} ->
        {:ok, response(false, 1, "", "git: HTTP status #{status}\n")}

      {:error, reason} when mode == :fetch ->
        {:ok, response(false, 1, "", "git: fetch failed: #{inspect(reason)}\n")}

      {:error, reason} ->
        {:ok, response(false, 1, "", "git: #{inspect(reason)}\n")}
    end
  end

  # ── apply via Port ─────────────────────────────────────────────────────────

  defp apply_init(pid) do
    case GitEngine.run(pid, %{"op" => "init"}) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  # Empty pack must never succeed — product honesty (P0.2).
  defp apply_pack(_pid, pack) when pack == <<>>, do: {:error, :empty_pack}

  defp apply_pack(pid, pack) when is_binary(pack) do
    # Stream in 1 MiB chunks for large packs.
    chunk = 1024 * 1024
    size = byte_size(pack)
    do_import_chunks(pid, pack, 0, size, chunk)
  end

  defp do_import_chunks(pid, _pack, off, size, _chunk) when off >= size do
    GitEngine.import_pack(pid, <<>>, final: true)
  end

  defp do_import_chunks(pid, pack, off, size, chunk) do
    take = min(chunk, size - off)
    part = binary_part(pack, off, take)
    final? = off + take >= size

    case GitEngine.import_pack(pid, part, final: final?) do
      :ok ->
        if final?, do: :ok, else: do_import_chunks(pid, pack, off + take, size, chunk)

      err ->
        err
    end
  end

  defp apply_refs_and_checkout(pid, tip, :clone) do
    with :ok <- apply_refs(pid, tip), do: apply_clone(pid, tip)
  end

  defp apply_refs_and_checkout(pid, tip, :fetch) do
    with :ok <- apply_refs(pid, tip), do: apply_fetch(pid, tip)
  end

  defp apply_refs(pid, %{name: name, hash: hash}) do
    case GitEngine.run(pid, %{
           "op" => "refs.import",
           "args" => %{"name" => name, "hash" => hash}
         }) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  defp apply_clone(pid, %{name: name}) do
    case GitEngine.run(pid, %{"op" => "clone.apply", "args" => %{"head" => name}}) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  # P0.4: engine fetch.apply requires name+hash (no silent no-op success).
  defp apply_fetch(pid, %{name: name, hash: hash}) do
    case GitEngine.run(pid, %{
           "op" => "fetch.apply",
           "args" => %{"name" => name, "hash" => hash, "remote" => "origin"}
         }) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  defp local_haves(pid) do
    case GitEngine.run(pid, %{"op" => "tips"}) do
      {:ok, m} ->
        tips = Map.get(m, "result") || Map.get(m, :result)

        tips =
          cond do
            is_list(tips) -> tips
            is_binary(tips) -> decode_json_list(tips)
            true -> []
          end

        for t <- tips,
            is_map(t),
            h = Map.get(t, "hash") || Map.get(t, :hash),
            is_binary(h) and Regex.match?(~r/^[0-9a-fA-F]{40}$/, h),
            do: String.downcase(h)

      _ ->
        []
    end
  end

  # ── request parsing ────────────────────────────────────────────────────────

  defp decode_request(bin) when is_binary(bin) do
    case safe_json_decode(bin) do
      {:ok, map} when is_map(map) -> {:ok, stringify_keys(map)}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_request(map) when is_map(map), do: {:ok, stringify_keys(map)}

  defp url_of(req) do
    args = Map.get(req, "args") || %{}
    args = if is_map(args), do: stringify_keys(args), else: %{}
    url = Map.get(args, "url") || Map.get(args, "remote") || ""

    if is_binary(url) and url != "" do
      {:ok, url}
    else
      {:error, :bad_url}
    end
  end

  defp ref_of(req) do
    args = Map.get(req, "args") || %{}
    args = if is_map(args), do: stringify_keys(args), else: %{}

    case Map.get(args, "ref") do
      r when is_binary(r) and r != "" -> r
      _ -> nil
    end
  end

  defp depth_of(req) do
    args = Map.get(req, "args") || %{}
    args = if is_map(args), do: stringify_keys(args), else: %{}

    case Map.get(args, "depth") do
      d when is_integer(d) -> d
      _ -> nil
    end
  end

  defp pick_tip([], _want), do: {:error, :no_refs}

  defp pick_tip(refs, nil) do
    tip =
      Enum.find(refs, &(&1.name == "HEAD")) ||
        Enum.find(refs, &String.ends_with?(&1.name, "/main")) ||
        Enum.find(refs, &String.ends_with?(&1.name, "/master")) ||
        Enum.find(refs, &String.starts_with?(&1.name, "refs/heads/")) ||
        List.first(refs)

    if tip, do: {:ok, tip}, else: {:error, :no_refs}
  end

  defp pick_tip(refs, want) do
    tip =
      Enum.find(refs, &(&1.name == want)) ||
        Enum.find(refs, &(&1.name == "refs/heads/" <> want)) ||
        Enum.find(refs, &(&1.name == "refs/tags/" <> want)) ||
        Enum.find(refs, &(String.downcase(&1.hash) == String.downcase(want)))

    if tip, do: {:ok, tip}, else: {:error, :ref_not_found}
  end

  defp ok?(m) when is_map(m) do
    case Map.get(m, "ok", Map.get(m, :ok)) do
      true ->
        true

      "true" ->
        true

      _ ->
        raw = Map.get(m, "raw")
        is_binary(raw) and String.contains?(raw, "\"ok\":true")
    end
  end

  defp ok?(_), do: false

  defp response(ok, code, stdout, stderr) do
    ~s({"ok":#{ok},"code":#{code},"stdout":#{json_str(stdout)},"stderr":#{json_str(stderr)}})
  end

  defp json_str(s) when is_binary(s) do
    escaped =
      s
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\r", "\\r")

    "\"#{escaped}\""
  end

  defp redact_url(url) do
    case URI.parse(url) do
      %URI{scheme: s, host: h, path: p} when is_binary(h) ->
        "#{s}://#{h}#{p || ""}"

      _ ->
        "remote"
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_keys(v)}
      {k, v} -> {k, stringify_keys(v)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(other), do: other

  defp safe_json_decode(bin) do
    try do
      # OTP 27+: :json.decode/1 returns the term (raises on error).
      term = :json.decode(bin)
      {:ok, term}
    rescue
      _ ->
        # Some builds return {:ok, term}
        try do
          case :json.decode(bin) do
            {:ok, term} -> {:ok, term}
            other when is_map(other) or is_list(other) -> {:ok, other}
            _ -> {:error, :invalid_json}
          end
        rescue
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp decode_json_list(bin) when is_binary(bin) do
    case safe_json_decode(bin) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
