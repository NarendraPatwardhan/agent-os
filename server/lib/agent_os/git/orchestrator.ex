defmodule AgentOS.Git.Orchestrator do
  @moduledoc """
  Server GitRemoteOrchestrator (GIT.md §7 / K16 revised).

  Runs the same algorithm as TS `remote-orchestrator.ts`:
  ListRefs → FetchPacks → Port `import_pack` → `refs.import` / `clone.apply` | `fetch.apply`;
  Push: `push.prepare` → list-refs lease → `pack_build` → receive-pack → `push.complete`.

  **HTTPS is BEAM** (`AgentOS.Git.SmartHttp`). **Apply / packbuilder is C Port**
  (`AgentOS.GitEngine`). No Node. Engine never dials.

  Security / honesty (P0.1 / P0.2 / P2.1 / R44–R47):
  * URL scheme/userinfo/host + origin allowlist are checked **before** any HTTP
  * Empty packs never short-circuit to `ok:true` — apply requires non-empty pack
    and a successful import; non-delete push refuses empty pack
  * **Push is supported** when not `read_only: true` (packbuilder + receive-pack)
  * Secrets only in BEAM request headers (never URL userinfo)

  Shared executable golden vectors (K20 / P2.8):
  `memcontainers/lib/git-engine/testdata/orch/{clone_success_steps,clone_empty_pack_fail,origin_denied}.json`
  (also under `server/test/fixtures/git/orch/`).
  """

  alias AgentOS.Git.SmartHttp
  alias AgentOS.GitEngine

  @type request :: map() | String.t()

  @zero_oid "0000000000000000000000000000000000000000"
  @push_read_only "git: push rejected (read-only mount)"

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
  * `:read_only` — when `true`, push is rejected with a stable read-only error

  **Push** (when not read-only): `push.prepare` → list-refs lease → pack.build
  from new tip OIDs → smart-HTTP receive-pack → `push.complete`. Empty pack on
  non-delete push fails closed.
  """
  @spec run(pid(), request(), keyword()) :: {:ok, binary()} | {:error, term()}
  def run(engine_pid, request, opts \\ []) when is_pid(engine_pid) do
    with {:ok, req} <- decode_request(request) do
      op = req |> Map.get("op", Map.get(req, :op, "")) |> to_string() |> String.downcase()

      case op do
        "clone" -> clone(engine_pid, req, opts)
        "fetch" -> fetch(engine_pid, req, opts, false)
        "pull" -> fetch(engine_pid, req, opts, true)
        "push" -> push(engine_pid, req, opts)
        _ -> {:ok, response(false, 2, "", "unknown remote op: #{op}")}
      end
    end
  end

  defp clone(engine_pid, req, opts) do
    with {:ok, url} <- url_of(req),
         {:ok, _origin} <- SmartHttp.ensure_url_allowed(url, opts),
         {:ok, refs} <- SmartHttp.list_refs(url, opts),
         {:ok, tip} <- pick_tip(refs, ref_of(req)),
         wants <- want_oids(refs, tip.hash),
         {:ok, pack} <-
           SmartHttp.fetch_packs(url, wants, [], Keyword.put(opts, :depth, depth_of(req))),
         :ok <- require_non_empty_pack(pack),
         :ok <- apply_init(engine_pid),
         :ok <- apply_pack(engine_pid, pack),
         :ok <- apply_refs_and_checkout(engine_pid, tip, refs, :clone) do
      {:ok, response(true, 0, "cloned #{redact_url(url)}\n", "")}
    else
      err -> map_remote_error(err, :clone)
    end
  end

  # pull? = true → R34 fetch + local FF only
  defp fetch(engine_pid, req, opts, pull?) do
    with {:ok, url} <- url_of(req),
         {:ok, _origin} <- SmartHttp.ensure_url_allowed(url, opts),
         {:ok, refs} <- SmartHttp.list_refs(url, opts),
         {:ok, tip} <- pick_tip(refs, ref_of(req)),
         have <- local_haves(engine_pid),
         wants <- want_oids(refs, tip.hash),
         {:ok, pack} <-
           SmartHttp.fetch_packs(url, wants, have, Keyword.put(opts, :depth, depth_of(req))),
         :ok <- require_non_empty_pack(pack),
         :ok <- apply_pack(engine_pid, pack),
         :ok <- apply_refs_and_checkout(engine_pid, tip, refs, :fetch),
         {:ok, kind} <- maybe_fast_forward_pull(engine_pid, tip, pull?) do
      msg =
        case kind do
          :fetched -> "fetched\n"
          :up_to_date -> "Already up to date.\n"
          :fast_forwarded -> "Fast-forward to #{ref_name_of(tip, refs)}\n"
        end

      {:ok, response(true, 0, msg, "")}
    else
      {:error, :not_fast_forward} ->
        {:ok, response(false, 1, "", "git: not fast-forward\n")}

      err ->
        map_remote_error(err, :fetch)
    end
  end

  # PR12 / R44–R47: push.prepare → list-refs lease → pack_build → receive-pack → complete.
  defp push(engine_pid, req, opts) do
    if Keyword.get(opts, :read_only, false) do
      {:ok, response(false, 1, "", @push_read_only <> "\n")}
    else
      do_push(engine_pid, req, opts)
    end
  end

  defp do_push(engine_pid, req, opts) do
    with {:ok, url} <- url_of(req),
         {:ok, _origin} <- SmartHttp.ensure_url_allowed(url, opts),
         {:ok, prep} <- run_push_prepare(engine_pid),
         {:ok, remote_refs} <- SmartHttp.list_refs(url, opts),
         {:ok, commands} <- build_push_commands(prep, remote_refs),
         {:ok, pack, delete_only?} <- build_push_pack(engine_pid, commands),
         :ok <- require_push_pack(pack, delete_only?),
         {:ok, status} <- SmartHttp.push_packs(url, commands, pack, opts),
         :ok <- apply_push_complete(engine_pid, req, commands, status) do
      if status.ok do
        {:ok, response(true, 0, "pushed to #{redact_url(url)}\n", "")}
      else
        msg = status[:message] || status["message"] || "unknown"

        {:ok,
         response(false, 1, "", "git: remote rejected push: #{msg}\n")}
      end
    else
      err -> map_remote_error(err, :push)
    end
  end

  defp require_non_empty_pack(pack) when is_binary(pack) and pack != <<>>, do: :ok
  defp require_non_empty_pack(_), do: {:error, :empty_pack}

  defp require_push_pack(_pack, true = _delete_only?), do: :ok

  defp require_push_pack(pack, false) when is_binary(pack) do
    cond do
      pack == <<>> ->
        {:error, :empty_push_pack}

      byte_size(pack) < 4 or not match?(<<"PACK", _::binary>>, pack) ->
        {:error, :push_pack_magic}

      true ->
        :ok
    end
  end

  defp require_push_pack(_, _), do: {:error, :empty_push_pack}

  defp map_remote_error(err, mode) do
    case err do
      {:error, {:list_refs_failed, r}} ->
        msg =
          if mode == :push do
            "git: list-refs (push lease) failed: #{inspect(r)}\n"
          else
            "git: list-refs failed: #{inspect(r)}\n"
          end

        {:ok, response(false, 1, "", msg)}

      {:error, {:upload_pack_failed, r}} ->
        {:ok, response(false, 1, "", "git: upload-pack failed: #{inspect(r)}\n")}

      {:error, {:receive_pack_failed, r}} ->
        {:ok, response(false, 1, "", "git: receive-pack failed: #{inspect(r)}\n")}

      {:error, :no_refs} ->
        {:ok, response(false, 1, "", "git: no refs in advertisement\n")}

      {:error, :ref_not_found} ->
        {:ok, response(false, 1, "", "git: ref not found\n")}

      {:error, :bad_url} ->
        op = if mode == :push, do: "push", else: "clone/fetch"
        {:ok, response(false, 2, "", "#{op} need args.url\n")}

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

      {:error, :empty_push_pack} ->
        {:ok, response(false, 1, "", "git: empty pack refused for non-delete push\n")}

      {:error, :push_pack_magic} ->
        {:ok, response(false, 1, "", "git: push pack missing PACK magic\n")}

      {:error, :no_push_commands} ->
        {:ok, response(false, 1, "", "git: push.prepare produced no commands\n")}

      {:error, :no_push_oids} ->
        {:ok, response(false, 1, "", "git: push has no new tip oids for pack build\n")}

      {:error, {:pack_build_failed, reason}} ->
        {:ok, response(false, 1, "", "git: pack.build failed: #{inspect(reason)}\n")}

      {:error, :no_oids} ->
        {:ok, response(false, 1, "", "git: pack.build failed: no oids\n")}

      {:error, :no_pack_magic} ->
        msg =
          if mode == :push do
            "git: push pack missing PACK magic\n"
          else
            "git: response missing PACK magic\n"
          end

        {:ok, response(false, 1, "", msg)}

      {:error, :body_too_large} ->
        {:ok, response(false, 1, "", "git: pack/body exceeds max_pack_bytes\n")}

      {:error, {:http_status, status}} ->
        {:ok, response(false, 1, "", "git: HTTP status #{status}\n")}

      {:error, {:push_complete_failed, m}} ->
        {:ok, response(false, 1, "", "git: push.complete failed: #{inspect(m)}\n")}

      {:error, reason} when mode == :fetch ->
        {:ok, response(false, 1, "", "git: fetch failed: #{inspect(reason)}\n")}

      {:error, reason} when mode == :push ->
        {:ok, response(false, 1, "", "git: push failed: #{inspect(reason)}\n")}

      {:error, reason} ->
        {:ok, response(false, 1, "", "git: #{inspect(reason)}\n")}
    end
  end

  # ── push helpers ───────────────────────────────────────────────────────────

  defp run_push_prepare(pid) do
    case GitEngine.run(pid, %{"op" => "push.prepare"}) do
      {:ok, m} ->
        if ok?(m), do: {:ok, m}, else: {:error, m}

      err ->
        err
    end
  end

  defp build_push_commands(prep, remote_refs) when is_list(remote_refs) do
    remote_by_name =
      Map.new(remote_refs, fn
        %{name: n, hash: h} when is_binary(n) and is_binary(h) -> {n, String.downcase(h)}
        %{"name" => n, "hash" => h} when is_binary(n) and is_binary(h) -> {n, String.downcase(h)}
        _ -> {nil, nil}
      end)
      |> Map.delete(nil)

    tips = extract_prepare_commands(prep)

    heads = Enum.filter(tips, fn t -> String.starts_with?(t.name, "refs/heads/") end)
    use = if heads != [], do: heads, else: tips

    commands =
      for t <- use do
        %{
          old_hash: Map.get(remote_by_name, t.name, @zero_oid),
          new_hash: String.downcase(t.hash),
          name: t.name
        }
      end

    if commands == [] do
      {:error, :no_push_commands}
    else
      {:ok, commands}
    end
  end

  defp extract_prepare_commands(prep) when is_map(prep) do
    result = Map.get(prep, "result") || Map.get(prep, :result)

    result =
      cond do
        is_map(result) ->
          result

        is_binary(result) ->
          case safe_json_decode(result) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        true ->
          %{}
      end

    cmds = Map.get(result, "commands") || Map.get(result, :commands) || []

    cmds =
      cond do
        is_list(cmds) -> cmds
        is_binary(cmds) -> decode_json_list(cmds)
        true -> []
      end

    for c <- cmds,
        is_map(c),
        name = Map.get(c, "name") || Map.get(c, :name),
        hash = Map.get(c, "hash") || Map.get(c, :hash),
        is_binary(name) and name != "",
        is_binary(hash) and Regex.match?(~r/^[0-9a-fA-F]{40}$/, hash) do
      %{name: name, hash: String.downcase(hash)}
    end
  end

  defp extract_prepare_commands(_), do: []

  defp build_push_pack(pid, commands) do
    delete_only? = Enum.all?(commands, fn c -> c.new_hash == @zero_oid end)

    if delete_only? do
      {:ok, <<>>, true}
    else
      oids =
        commands
        |> Enum.map(& &1.new_hash)
        |> Enum.filter(fn h ->
          is_binary(h) and Regex.match?(~r/^[0-9a-fA-F]{40}$/, h) and h != @zero_oid
        end)
        |> Enum.uniq()

      if oids == [] do
        {:error, :no_push_oids}
      else
        case GitEngine.pack_build(pid, oids) do
          {:ok, pack} -> {:ok, pack, false}
          {:error, reason} -> {:error, normalize_pack_build_error(reason)}
        end
      end
    end
  end

  defp normalize_pack_build_error(:no_oids), do: :no_oids
  defp normalize_pack_build_error(:no_pack_magic), do: :no_pack_magic
  defp normalize_pack_build_error({:pack_build_failed, r}), do: {:pack_build_failed, r}
  defp normalize_pack_build_error(other), do: {:pack_build_failed, other}

  defp apply_push_complete(pid, req, commands, status) do
    args = Map.get(req, "args") || %{}
    args = if is_map(args), do: stringify_keys(args), else: %{}
    remote = Map.get(args, "remote") || "origin"
    first = List.first(commands) || %{}
    name = Map.get(first, :name) || Map.get(first, "name") || "refs/heads/master"
    branch = String.replace_prefix(name, "refs/heads/", "")
    hash = Map.get(first, :new_hash) || Map.get(first, "new_hash") || ""

    ok? = Map.get(status, :ok, Map.get(status, "ok", false)) == true

    case GitEngine.run(pid, %{
           "op" => "push.complete",
           "args" => %{
             "ok" => ok?,
             "remote" => to_string(remote),
             "branch" => branch,
             "hash" => hash
           }
         }) do
      {:ok, m} ->
        # When remote rejected, push.complete may fail; surface remote rejection
        # from status first (caller checks status.ok). Only fail on complete error
        # when the remote accepted.
        cond do
          not ok? -> :ok
          ok?(m) -> :ok
          true -> {:error, {:push_complete_failed, m}}
        end

      err ->
        if ok?, do: err, else: :ok
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

  defp apply_refs_and_checkout(pid, tip, refs, :clone) do
    resolved = %{name: ref_name_of(tip, refs), hash: tip.hash}

    with :ok <- apply_all_heads(pid, resolved, refs), do: apply_clone(pid, resolved)
  end

  defp apply_refs_and_checkout(pid, tip, refs, :fetch) do
    resolved = %{name: ref_name_of(tip, refs), hash: tip.hash}

    with :ok <- apply_all_heads(pid, resolved, refs), do: apply_fetch(pid, resolved)
  end

  # R37: import all advertised heads (engine is single-ref → loop).
  defp apply_all_heads(pid, tip, refs) when is_list(refs) do
    primary = %{name: tip.name || ref_name_of(tip, refs), hash: tip.hash}

    heads =
      for r <- refs,
          is_map(r),
          name = Map.get(r, :name) || Map.get(r, "name"),
          is_binary(name) and String.starts_with?(name, "refs/heads/"),
          hash = Map.get(r, :hash) || Map.get(r, "hash"),
          is_binary(hash) and Regex.match?(~r/^[0-9a-fA-F]{40}$/, hash),
          do: %{name: name, hash: String.downcase(hash)}

    to_import =
      ([primary | heads] ++ [%{name: primary.name, hash: primary.hash}])
      |> Enum.uniq_by(& &1.name)
      |> Enum.filter(&(&1.name != "" and &1.hash != ""))

    Enum.reduce_while(to_import, :ok, fn %{name: name} = entry, :ok ->
      case apply_refs(pid, entry) do
        :ok ->
          {:cont, :ok}

        err ->
          if name == primary.name, do: {:halt, err}, else: {:cont, :ok}
      end
    end)
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

  defp apply_clone(pid, tip) do
    name = Map.get(tip, :name) || Map.get(tip, "name") || "refs/heads/main"

    case GitEngine.run(pid, %{"op" => "clone.apply", "args" => %{"head" => name}}) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  # P0.4: engine fetch.apply requires name+hash (no silent no-op success).
  defp apply_fetch(pid, tip) do
    name = Map.get(tip, :name) || Map.get(tip, "name")
    hash = Map.get(tip, :hash) || Map.get(tip, "hash")

    case GitEngine.run(pid, %{
           "op" => "fetch.apply",
           "args" => %{"name" => name, "hash" => hash, "remote" => "origin"}
         }) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  # R34: pull = fetch + local FF only via reset mode ff-only.
  defp maybe_fast_forward_pull(_pid, _tip, false), do: {:ok, :fetched}

  defp maybe_fast_forward_pull(pid, tip, true) do
    hash = Map.get(tip, :hash) || Map.get(tip, "hash")

    case GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}}) do
      {:ok, m} ->
        head_hex =
          (Map.get(m, "stdout") || Map.get(m, :stdout) || "")
          |> to_string()
          |> String.trim()
          |> String.split(~r/\s+/)
          |> List.first()

        if is_binary(head_hex) and String.downcase(head_hex) == String.downcase(to_string(hash)) do
          {:ok, :up_to_date}
        else
          case do_ff_reset(pid, hash) do
            :ok -> {:ok, :fast_forwarded}
            err -> err
          end
        end

      _ ->
        case do_ff_reset(pid, hash) do
          :ok -> {:ok, :fast_forwarded}
          err -> err
        end
    end
  end

  defp do_ff_reset(pid, hash) do
    case GitEngine.run(pid, %{
           "op" => "reset",
           "args" => %{"rev" => hash, "mode" => "ff-only"}
         }) do
      {:ok, m} ->
        if ok?(m), do: :ok, else: {:error, :not_fast_forward}

      {:error, _} ->
        {:error, :not_fast_forward}
    end
  end

  defp want_oids(refs, tip_hash) when is_list(refs) do
    heads =
      for r <- refs,
          is_map(r),
          name = Map.get(r, :name) || Map.get(r, "name"),
          is_binary(name) and String.starts_with?(name, "refs/heads/"),
          hash = Map.get(r, :hash) || Map.get(r, "hash"),
          is_binary(hash) and Regex.match?(~r/^[0-9a-fA-F]{40}$/, hash),
          do: String.downcase(hash)

    ([String.downcase(to_string(tip_hash)) | heads] ++ [])
    |> Enum.filter(&(&1 != ""))
    |> Enum.uniq()
  end

  defp ref_name_of(tip, refs) do
    name = Map.get(tip, :name) || Map.get(tip, "name") || ""

    if name == "HEAD" do
      hash = Map.get(tip, :hash) || Map.get(tip, "hash")

      found =
        Enum.find(refs, fn r ->
          n = Map.get(r, :name) || Map.get(r, "name")
          h = Map.get(r, :hash) || Map.get(r, "hash")
          is_binary(n) and String.starts_with?(n, "refs/") and h == hash
        end)

      case found do
        nil -> "refs/heads/master"
        r -> Map.get(r, :name) || Map.get(r, "name")
      end
    else
      name
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

  # R35: product default shallow depth=1; depth<=0 means full history.
  defp depth_of(req) do
    args = Map.get(req, "args") || %{}
    args = if is_map(args), do: stringify_keys(args), else: %{}

    case Map.get(args, "depth") do
      d when is_integer(d) and d > 0 -> d
      d when is_integer(d) -> nil
      _ -> 1
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
