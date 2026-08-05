defmodule AgentOS.Git.Orchestrator do
  @moduledoc """
  Server GitRemoteOrchestrator (SYSTEMS.md §11b dual-host orch).

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

  Shared executable golden vectors (K20 / P2.8 / R81):
  `memcontainers/lib/git-engine/fixtures/orch/{clone_success_steps,clone_empty_pack_fail,origin_denied,fetch_success_steps,pull_ff_steps,push_readonly}.json`
  (also under `server/test/fixtures/git/orch/`).
  """

  alias AgentOS.Git.Connections
  alias AgentOS.Git.Metrics
  alias AgentOS.Git.PackCache
  alias AgentOS.Git.SmartHttp
  alias AgentOS.GitEngine

  @type request :: map() | String.t()

  @zero_oid "0000000000000000000000000000000000000000"
  # Prefer contracts/git.kdl via AgentOS.Contracts.Git; keep atom for golden matchers.
  @push_requires_approval "git: push requires approval"
  @push_blocked "git: push blocked by policy"

  @doc """
  Handle a guest/SDK remote Request JSON against a live git-engine Port pid.

  Options:
  * `:transport` — injectable SmartHttp transport (tests)
  * `:auth` — host-owned `%{kind: :none | :bearer | :header | :basic, ...}`
    (guest body auth/token fields are rejected)
  * `:connections` — host connection catalog (`ref` / `origins` / `auth` / `spec`);
    guest may pass `args.connection` / `args.agentos` to bind one
  * `:policies` — connection push-policy rules (`pattern` / `action`)
  * `:allowed_origins` — list of canonical `http(s)://host[:port]` origins
    (required for bare-URL dials; empty/missing fails closed). Prefer explicit
    lists in tests. `:any` is fixture-transport only (see SmartHttp).
  * `:require_origin_allowlist` — default `true`; set `false` only with
    injected fixture transport
  * `:max_pack_bytes` — response/pack size cap (default 64 MiB); enforced while
    streaming upload-pack (D11 — fail closed at cap+1, no unbounded BEAM buffer)
  * `:import_chunk_bytes` — `GitEngine.import_pack` chunk size (default 1 MiB)
  * `:read_only` — when `true`, push is rejected with a stable read-only error
  * `:pack_cache` — pack cache selection (credentials never in keys):
    - pid — explicit `AgentOS.Git.PackCache` Agent
    - `:default` / `true` — **product default** (`product_default_cache/0`):
      fresh per-caller Memory unless shared opt-in
      (`AGENTOS_GIT_PACK_CACHE_SHARED=1` → process Memory/Disk, or
      SHARED + optional disk dir). Multi-tenant
      must not set SHARED or a shared disk dir across tenants.
    - `:process` / `:shared` — process-scoped singleton
      (`default_process_cache/0`); **disk** when `AGENTOS_GIT_PACK_CACHE` set
    - `:disk` — disk cache at `AGENTOS_GIT_PACK_CACHE`
    - `{:disk, dir}` / bare dir string — disk cache at `dir`
    - Omit / `nil` / `false` — disabled (direct orch; product host path
      typically passes `:default`)
    Download-key is url+wants+haves+depth+filter only — **never** auth.
  * `:require_approval` — when `true`, push must be approved (R31); also set
    when a matching policy action is `require_approval`
  * `:on_push_approval` — fun `(ctx :: map()) -> boolean` or `/0`; called when
    `require_approval` is set. Default when missing: reject (fail closed).
  * `:push_approval` — boolean shorthand when `require_approval` is set and no
    fun is provided (`true` allows, `false` rejects)
  * `:sparse_cone` — list of cone-mode prefix strings
    (e.g. `["src", "docs"]`) applied **after** `clone.apply` via Port
    `sparse-set` (D20 / JS `sparseCone` parity). **Cone-only** — not full
    sparse-checkout language. Empty/missing skips sparse-set. Gitfs sees the
    resulting worktree projection (no separate mount-side filter).

  **Push** (when not read-only): `push.prepare` → list-refs lease → pack.build
  from new tip OIDs → smart-HTTP receive-pack → `push.complete`. Empty pack on
  non-delete push fails closed. Policy `block` fails before dial.
  """
  @spec run(pid(), request(), keyword()) :: {:ok, binary()} | {:error, term()}
  def run(engine_pid, request, opts \\ []) when is_pid(engine_pid) do
    with {:ok, req} <- decode_request(request) do
      op = req |> Map.get("op", Map.get(req, :op, "")) |> to_string() |> String.downcase()
      # D35: clear per-op process labels (pack size / origin) before remote work.
      _ = Process.delete(:agent_os_git_pack_bytes)
      _ = Process.delete(:agent_os_git_origin_redacted)
      _ = Process.delete(:agent_os_git_allowlist_deny)
      t0 = System.monotonic_time(:millisecond)

      result =
        case op do
          "clone" -> clone(engine_pid, req, opts)
          "fetch" -> fetch(engine_pid, req, opts, false)
          "pull" -> fetch(engine_pid, req, opts, true)
          "push" -> push(engine_pid, req, opts)
          "submodule" -> submodule(engine_pid, req, opts)
          _ -> {:ok, response(false, 2, "", "unknown remote op: #{op}")}
        end

      duration = max(0, System.monotonic_time(:millisecond) - t0)
      record_metrics(op, result, duration)
      result
    end
  end

  defp record_metrics(op, result, duration_ms) do
    meta = %{
      duration_ms: duration_ms,
      pack_bytes: Process.delete(:agent_os_git_pack_bytes) || 0,
      origin_redacted: Process.delete(:agent_os_git_origin_redacted) || "",
      allowlist_deny?: Process.delete(:agent_os_git_allowlist_deny) == true
    }

    case result do
      {:ok, json} when is_binary(json) ->
        ok? =
          String.contains?(json, "\"ok\":true") or String.contains?(json, ~s("ok":true))

        Metrics.record_remote_result(op, ok?, meta)

      {:error, :eio} ->
        Metrics.inc(:port_eio)
        Metrics.record_remote_result(op, false, meta)

      {:error, _} ->
        Metrics.inc(:rpc_error)
        Metrics.record_remote_result(op, false, meta)

      _ ->
        :ok
    end
  end

  defp clone(engine_pid, req, opts) do
    case clone_begin(engine_pid) do
      :ok ->
        try do
          result = clone_reserved(engine_pid, req, opts)

          case clone_end(engine_pid) do
            :ok -> result
            error -> map_remote_error_if_needed(error, :clone)
          end
        rescue
          error ->
            _ = clone_end(engine_pid)
            reraise error, __STACKTRACE__
        catch
          kind, reason ->
            _ = clone_end(engine_pid)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      error ->
        map_remote_error_if_needed(error, :clone)
    end
  end

  defp clone_reserved(engine_pid, req, opts) do
    result =
      with {:ok, binding} <- resolve_binding(engine_pid, req, opts),
           opts <- apply_binding(opts, binding),
           url <- binding.url,
           {:ok, refs} <- SmartHttp.list_refs(url, opts),
           {:ok, tip} <- pick_tip(refs, ref_of(req)),
           wants <- want_oids(refs, tip.hash),
           depth <- depth_of(req, :clone),
           filter <- filter_of(req) do
        with_pack_source(url, wants, [], depth, filter, opts, fn pack ->
          with :ok <- require_non_empty_pack(pack),
               :ok <- apply_init(engine_pid),
               :ok <- apply_pack(engine_pid, pack, opts),
               :ok <- apply_refs_and_checkout(engine_pid, tip, refs, :clone),
               :ok <- configure_clone_remote(engine_pid, binding, tip, refs),
               :ok <- apply_sparse_cone(engine_pid, tip, refs, opts) do
            {:ok, response(true, 0, "cloned #{redact_url(url)}\n", "")}
          end
        end)
      end

    map_remote_error_if_needed(result, :clone)
  end

  # D23–D24: host-mediated submodule update.
  # Parse .gitmodules via Port list → for each entry apply connection policy on
  # URL → ListRefs/FetchPacks → nested Port at super_root/path → clone.apply.
  # Nested worktree files sit under the super root so gitfs projects them.
  defp submodule(engine_pid, req, opts) do
    args = args_of(req)

    action =
      case Map.get(args, "action") || Map.get(args, :action) do
        a when is_binary(a) and a != "" -> String.downcase(a)
        _ -> "update"
      end

    cond do
      action in ["list", "status"] ->
        case GitEngine.run(engine_pid, %{"op" => "submodule", "args" => %{"action" => action}}) do
          {:ok, m} -> {:ok, encode_response_map(m)}
          err -> err
        end

      action in ["update", "init", "clone"] ->
        submodule_update(engine_pid, req, opts)

      true ->
        {:ok, response(false, 2, "", "git: submodule action not supported via orch: #{action}\n")}
    end
  end

  defp submodule_update(engine_pid, req, opts) do
    with {:ok, subs} <- list_submodules(engine_pid),
         {:ok, targets} <- filter_submodules(subs, args_of(req)),
         {:ok, updated} <- update_submodules(engine_pid, targets, opts) do
      {:ok,
       response(
         true,
         0,
         "updated #{length(updated)} submodule(s)\n",
         "",
         %{"updated" => updated}
       )}
    else
      {:error, {:submodule, path, reason}} when is_binary(path) ->
        msg =
          case reason do
            bin when is_binary(bin) -> bin
            other -> inspect(other)
          end

        {:ok, response(false, 1, "", "git: submodule #{path}: #{String.trim_trailing(msg)}\n")}

      {:error, :invalid_sub_path} ->
        {:ok, response(false, 2, "", "git: submodule path invalid\n")}

      {:error, :no_super_root} ->
        {:ok, response(false, 1, "", "git: superproject engine root unavailable\n")}

      {:error, m} when is_map(m) ->
        stderr = Map.get(m, "stderr") || Map.get(m, :stderr) || inspect(m)
        {:ok, response(false, 1, "", to_string(stderr))}

      {:ok, resp} when is_binary(resp) ->
        {:ok, resp}

      other ->
        map_remote_error_if_needed(other, :clone)
    end
  end

  defp list_submodules(engine_pid) do
    case GitEngine.run(engine_pid, %{"op" => "submodule", "args" => %{"action" => "list"}}) do
      {:ok, m} ->
        if ok?(m) do
          result = Map.get(m, "result") || Map.get(m, :result) || %{}
          subs = Map.get(result, "submodules") || Map.get(result, :submodules) || []
          {:ok, if(is_list(subs), do: subs, else: [])}
        else
          {:error, m}
        end

      err ->
        err
    end
  end

  defp filter_submodules(subs, args) do
    only =
      case Map.get(args, "path") || Map.get(args, :path) do
        p when is_binary(p) and p != "" -> normalize_sub_path(p)
        _ -> nil
      end

    case only do
      :error ->
        {:error, :invalid_sub_path}

      nil ->
        {:ok, subs}

      path ->
        {:ok,
         Enum.filter(subs, fn s ->
           normalize_sub_path(Map.get(s, "path") || Map.get(s, :path) || "") == path
         end)}
    end
  end

  defp update_submodules(_engine_pid, [], _opts), do: {:ok, []}

  defp update_submodules(engine_pid, targets, opts) do
    super_root = GitEngine.root(engine_pid)

    if not is_binary(super_root) or super_root == "" do
      {:error, :no_super_root}
    else
      executable = GitEngine.executable(engine_pid) || System.get_env("AGENTOS_GIT_ENGINE")

      Enum.reduce_while(targets, {:ok, []}, fn sub, {:ok, acc} ->
        case update_one_submodule(engine_pid, super_root, executable, sub, opts) do
          {:ok, path} -> {:cont, {:ok, acc ++ [path]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defp update_one_submodule(_super_pid, super_root, executable, sub, opts) do
    path_raw = Map.get(sub, "path") || Map.get(sub, :path) || ""
    url = Map.get(sub, "url") || Map.get(sub, :url) || ""
    hash = Map.get(sub, "hash") || Map.get(sub, :hash)

    path =
      case normalize_sub_path(path_raw) do
        :error -> nil
        "" -> nil
        p -> p
      end

    cond do
      path == nil ->
        {:error, {:submodule, to_string(path_raw), "missing path"}}

      not is_binary(url) or String.trim(url) == "" ->
        {:error, {:submodule, path, "missing url in .gitmodules"}}

      true ->
        nested_root = Path.join(super_root, path)
        # Fresh nested worktree each update (v1): avoid "repository already open"
        # on re-init; files re-materialize under super_root for gitfs.
        _ = File.rm_rf(nested_root)
        File.mkdir_p!(nested_root)

        # Nested Port clone: same connection policy via resolve_binding on a
        # synthetic clone request; files land under super_root for gitfs.
        start_opts =
          [root: nested_root, mount_path: "/__submodule__/" <> path]
          |> then(fn o ->
            if is_binary(executable) and executable != "",
              do: Keyword.put(o, :executable, executable),
              else: o
          end)

        case GitEngine.start(start_opts) do
          {:ok, nested_pid} ->
            try do
              clone_req = %{
                "op" => "clone",
                "args" => maybe_put_ref(%{"url" => String.trim(url)}, hash)
              }

              case clone(nested_pid, clone_req, opts) do
                {:ok, json} when is_binary(json) ->
                  if String.contains?(json, "\"ok\":true") or
                       String.contains?(json, ~s("ok":true)) do
                    # Prefer exact gitlink checkout when hash provided.
                    _ = maybe_checkout_gitlink(nested_pid, hash)
                    {:ok, path}
                  else
                    stderr = extract_stderr(json)
                    {:error, {:submodule, path, stderr}}
                  end

                {:error, reason} ->
                  {:error, {:submodule, path, inspect(reason)}}

                other ->
                  {:error, {:submodule, path, inspect(other)}}
              end
            after
              _ = GitEngine.stop(nested_pid)
            end

          {:error, reason} ->
            {:error, {:submodule, path, "nested engine start failed: #{inspect(reason)}"}}
        end
    end
  end

  defp maybe_put_ref(args, hash) when is_binary(hash) do
    if Regex.match?(~r/^[0-9a-fA-F]{40}$/, hash) do
      # Prefer advertised tip; gitlink enforced post-clone via reset.
      args
    else
      args
    end
  end

  defp maybe_put_ref(args, _), do: args

  defp maybe_checkout_gitlink(pid, hash) when is_binary(hash) do
    if Regex.match?(~r/^[0-9a-fA-F]{40}$/, hash) do
      h = String.downcase(hash)

      case GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}}) do
        {:ok, m} ->
          cur =
            (Map.get(m, "stdout") || "")
            |> to_string()
            |> String.trim()
            |> String.split(~r/\s+/)
            |> List.first()
            |> case do
              c when is_binary(c) -> String.downcase(c)
              _ -> ""
            end

          if cur != h do
            _ =
              GitEngine.run(pid, %{
                "op" => "reset",
                "args" => %{"rev" => h, "mode" => "hard"}
              })
          end

          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp maybe_checkout_gitlink(_pid, _), do: :ok

  defp normalize_sub_path(path) when is_binary(path) do
    p =
      path
      |> String.replace("\\", "/")
      |> String.trim()
      |> String.trim_leading("/")
      |> String.trim_trailing("/")

    parts =
      p
      |> String.split("/", trim: true)
      |> Enum.reject(&(&1 == "."))

    cond do
      parts == [] ->
        ""

      Enum.any?(parts, &(&1 == ".." or &1 == ".git")) ->
        :error

      true ->
        Enum.join(parts, "/")
    end
  end

  defp normalize_sub_path(_), do: :error

  defp extract_stderr(json) when is_binary(json) do
    case Regex.run(~r/"stderr"\s*:\s*"((?:\\.|[^"\\])*)"/, json) do
      [_, s] ->
        s
        |> String.replace("\\n", "\n")
        |> String.replace("\\\"", "\"")
        |> String.replace("\\\\", "\\")

      _ ->
        json
    end
  end

  # Encode a Port Run map as a guest Response JSON binary.
  defp encode_response_map(m) when is_map(m) do
    ok? = ok?(m)
    code = Map.get(m, "code") || Map.get(m, :code) || if(ok?, do: 0, else: 1)
    stdout = Map.get(m, "stdout") || Map.get(m, :stdout) || ""
    stderr = Map.get(m, "stderr") || Map.get(m, :stderr) || ""
    result = Map.get(m, "result") || Map.get(m, :result)

    if is_map(result) do
      response(ok?, code, stdout, stderr, result)
    else
      response(ok?, code, stdout, stderr)
    end
  end

  defp encode_response_map(_), do: response(false, 1, "", "git: bad submodule list response\n")

  # pull? = true → R34 fetch + local FF only
  defp fetch(engine_pid, req, opts, pull?) do
    result =
      with {:ok, binding} <- resolve_binding(engine_pid, req, opts),
           opts <- apply_binding(opts, binding),
           url <- binding.url,
           {:ok, refs} <- SmartHttp.list_refs(url, opts),
           {:ok, tip} <- pick_tip(refs, ref_of(req)),
           have <- local_haves(engine_pid),
           wants <- want_oids(refs, tip.hash),
           depth <- depth_of(req, if(pull?, do: :pull, else: :fetch)),
           filter <- filter_of(req) do
        with_pack_source(url, wants, have, depth, filter, opts, fn pack ->
          with :ok <- require_non_empty_pack(pack),
               :ok <- apply_pack(engine_pid, pack, opts),
               :ok <- apply_refs_and_checkout(engine_pid, tip, refs, :fetch),
               {:ok, kind} <- maybe_fast_forward_pull(engine_pid, tip, pull?) do
            msg =
              case kind do
                :fetched -> "fetched\n"
                :up_to_date -> "Already up to date.\n"
                :fast_forwarded -> "Fast-forward to #{ref_name_of(tip, refs)}\n"
              end

            {:ok, response(true, 0, msg, "")}
          end
        end)
      end

    case result do
      {:error, :not_fast_forward} ->
        {:ok, response(false, 1, "", AgentOS.Contracts.Git.stderr_line(:not_fast_forward))}

      other ->
        map_remote_error_if_needed(other, :fetch)
    end
  end

  # Resolve pack (cache or stream transport), run `fun`, always cleanup file sources.
  defp with_pack_source(url, wants, haves, depth, filter, opts, fun)
       when is_function(fun, 1) do
    note_origin(url)

    case resolve_pack(url, wants, haves, depth, filter, opts) do
      {:ok, pack} ->
        # D35: pack payload size for metrics (file or binary sources).
        Process.put(:agent_os_git_pack_bytes, SmartHttp.pack_byte_size(pack))

        try do
          fun.(pack)
        after
          SmartHttp.cleanup_pack_source(pack)
        end

      err ->
        err
    end
  end

  defp note_origin(url) when is_binary(url) do
    Process.put(:agent_os_git_origin_redacted, Metrics.redact_origin(url))
    :ok
  end

  defp note_origin(_), do: :ok

  defp map_remote_error_if_needed({:ok, _} = ok, _mode), do: ok
  defp map_remote_error_if_needed(err, mode), do: map_remote_error(err, mode)

  # R40: download-key hit skips transport. Key = url+wants+haves+depth+filter (no auth).
  # Product transport returns a file pack source (D11 stream); fixtures return binary.
  defp resolve_pack(url, wants, haves, depth, filter, opts) do
    cache = pack_cache_of(opts)
    pack_key = PackCache.upload_pack_cache_key(url, wants, haves, depth, filter)

    with {:ok, pack} <-
           pack_from_cache_or_transport(cache, pack_key, url, wants, haves, depth, filter, opts) do
      maybe_store_pack(cache, pack_key, pack)
      {:ok, pack}
    end
  end

  defp pack_from_cache_or_transport(nil, _key, url, wants, haves, depth, filter, opts) do
    SmartHttp.fetch_packs(
      url,
      wants,
      haves,
      opts |> Keyword.put(:depth, depth) |> Keyword.put(:filter, filter)
    )
  end

  defp pack_from_cache_or_transport(cache, pack_key, url, wants, haves, depth, filter, opts) do
    fetch_opts = opts |> Keyword.put(:depth, depth) |> Keyword.put(:filter, filter)

    case PackCache.get_by_key(cache, pack_key) do
      dig when is_binary(dig) ->
        case PackCache.get(cache, dig) do
          pack when is_binary(pack) and pack != <<>> ->
            {:ok, pack}

          _ ->
            SmartHttp.fetch_packs(url, wants, haves, fetch_opts)
        end

      _ ->
        SmartHttp.fetch_packs(url, wants, haves, fetch_opts)
    end
  end

  defp maybe_store_pack(nil, _key, _pack), do: :ok

  defp maybe_store_pack(cache, pack_key, pack) do
    case SmartHttp.read_pack_source(pack) do
      {:ok, bin} when is_binary(bin) and bin != <<>> ->
        dig = PackCache.put(cache, bin)
        PackCache.put_key(cache, pack_key, dig)
        :ok

      _ ->
        :ok
    end
  end

  defp pack_cache_of(opts) do
    case Keyword.get(opts, :pack_cache) do
      pid when is_pid(pid) ->
        pid

      # Product default: fresh Memory unless SHARED=1 (multi-tenant safer; JS parity).
      :default ->
        PackCache.product_default_cache()

      true ->
        PackCache.product_default_cache()

      # Explicit process-global share (LLB / single-tenant; or pass pid from caller).
      :process ->
        PackCache.default_process_cache()

      :shared ->
        PackCache.default_process_cache()

      :disk ->
        PackCache.disk_cache(:env)

      {:disk, dir} when is_binary(dir) and dir != "" ->
        PackCache.disk_cache(dir)

      dir when is_binary(dir) and dir != "" ->
        PackCache.disk_cache(dir)

      _ ->
        nil
    end
  end

  # PR12 / R44–R47: push.prepare → list-refs lease → pack_build → receive-pack → complete.
  # R31: optional require_approval / on_push_approval / push_approval gate.
  defp push(engine_pid, req, opts) do
    if Keyword.get(opts, :read_only, false) do
      {:ok,
       response(
         false,
         1,
         "",
         AgentOS.Contracts.Git.stderr_line(:push_read_only)
       )}
    else
      do_push(engine_pid, req, opts)
    end
  end

  defp do_push(engine_pid, req, opts) do
    with {:ok, binding} <- resolve_binding(engine_pid, req, opts),
         :ok <- gate_push_policy(binding),
         opts <- apply_binding(opts, binding),
         opts <- maybe_force_require_approval(opts, binding),
         url <- binding.url,
         {:ok, prep} <- run_push_prepare(engine_pid),
         receive_opts <- Keyword.put(opts, :service, :receive_pack),
         {:ok, remote_refs} <- SmartHttp.list_refs(url, receive_opts),
         {:ok, commands} <- build_push_commands(prep, remote_refs, req),
         capabilities <- receive_capabilities(remote_refs),
         :ok <- require_delete_capability(commands, capabilities),
         :ok <- maybe_require_push_approval(url, binding, commands, opts),
         {:ok, pack, delete_only?} <- build_push_pack(engine_pid, commands),
         :ok <- require_push_pack(pack, delete_only?),
         push_opts <- Keyword.put(opts, :receive_capabilities, capabilities),
         {:ok, status} <- SmartHttp.push_packs(url, commands, pack, push_opts),
         :ok <- apply_push_complete(engine_pid, req, commands, status) do
      if status.ok do
        {:ok, response(true, 0, "pushed to #{redact_url(url)}\n", "")}
      else
        msg = status[:message] || status["message"] || "unknown"

        {:ok, response(false, 1, "", "git: remote rejected push: #{msg}\n")}
      end
    else
      {:error, :push_blocked} ->
        {:ok, response(false, 1, "", @push_blocked <> "\n")}

      {:error, :push_requires_approval} ->
        {:ok, response(false, 1, "", @push_requires_approval <> "\n")}

      err ->
        map_remote_error(err, :push)
    end
  end

  defp gate_push_policy(%{push_action: :block}), do: {:error, :push_blocked}
  defp gate_push_policy(_), do: :ok

  defp receive_capabilities(refs) when is_list(refs) do
    refs
    |> Enum.flat_map(fn ref -> Map.get(ref, :capabilities, Map.get(ref, "capabilities", [])) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp require_delete_capability(commands, capabilities) do
    deleting? =
      Enum.any?(commands, fn c ->
        (Map.get(c, :new_hash) || Map.get(c, "new_hash") || Map.get(c, "newHash")) ==
          @zero_oid
      end)

    if deleting? and "delete-refs" not in capabilities,
      do: {:error, :delete_refs_not_advertised},
      else: :ok
  end

  defp maybe_force_require_approval(opts, %{push_action: :require_approval}) do
    Keyword.put(opts, :require_approval, true)
  end

  defp maybe_force_require_approval(opts, _), do: opts

  # R31: when require_approval is true (opts or policy), call on_push_approval
  # or use push_approval bool. Default without fun / without true push_approval
  # → reject (fail closed).
  defp maybe_require_push_approval(url, binding, commands, opts) do
    if Keyword.get(opts, :require_approval, false) == true do
      ctx = %{
        url: url,
        connection_ref: Map.get(binding, :connection_ref),
        commands: commands
      }

      allowed =
        case Keyword.get(opts, :on_push_approval) do
          fun when is_function(fun, 1) ->
            try do
              fun.(ctx) == true
            rescue
              _ -> false
            end

          fun when is_function(fun, 0) ->
            try do
              fun.() == true
            rescue
              _ -> false
            end

          _ ->
            Keyword.get(opts, :push_approval, false) == true
        end

      if allowed, do: :ok, else: {:error, :push_requires_approval}
    else
      :ok
    end
  end

  defp require_non_empty_pack(pack) when is_binary(pack) and pack != <<>>, do: :ok

  defp require_non_empty_pack({:file, _path, _offset} = src) do
    if SmartHttp.pack_byte_size(src) > 0, do: :ok, else: {:error, :empty_pack}
  end

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
        {:ok, response(false, 2, "", "clone/fetch/push need args.url or args.connection\n")}

      {:error, :bad_remote_url} ->
        {:ok,
         response(
           false,
           1,
           "",
           "git: remote url must be http(s) without embedded credentials\n"
         )}

      {:error, {:unknown_connection, ref}} ->
        {:ok, response(false, 1, "", "git: unknown connection ref #{ref}\n")}

      {:error, {:origin_not_allowlisted_for_connection, ref}} ->
        # D36: allowlist deny alert (origin already noted when known).
        Process.put(:agent_os_git_allowlist_deny, true)

        {:ok,
         response(
           false,
           1,
           "",
           AgentOS.Contracts.Git.stderr_line(
             :origin_not_allowlisted,
             "for connection #{ref}"
           )
         )}

      {:error, :guest_secrets_forbidden} ->
        {:ok,
         response(
           false,
           1,
           "",
           AgentOS.Contracts.Git.stderr_line(
             :guest_auth_secrets,
             "(use connection ref)"
           )
         )}

      {:error, :query_auth_unsupported} ->
        {:ok,
         response(
           false,
           1,
           "",
           AgentOS.Contracts.Git.stderr_line(:query_auth_unsupported)
         )}

      {:error, :invalid_auth} ->
        {:ok,
         response(
           false,
           1,
           "",
           AgentOS.Contracts.Git.stderr_line(:invalid_auth)
         )}

      {:error, :origin_not_allowed} ->
        Process.put(:agent_os_git_allowlist_deny, true)
        {:ok, response(false, 1, "", AgentOS.Contracts.Git.stderr_line(:origin_not_allowlisted))}

      {:error, :push_blocked} ->
        {:ok, response(false, 1, "", @push_blocked <> "\n")}

      {:error, :empty_pack} ->
        {:ok,
         response(
           false,
           1,
           "",
           AgentOS.Contracts.Git.stderr_line(:empty_pack, "from remote")
         )}

      {:error, :empty_push_pack} ->
        {:ok,
         response(
           false,
           1,
           "",
           AgentOS.Contracts.Git.stderr_line(
             :empty_pack,
             "refused for non-delete push"
           )
         )}

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

  defp build_push_commands(prep, remote_refs, req) when is_list(remote_refs) do
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

    commands = maybe_delete_commands(commands, remote_by_name, req)

    if commands == [] do
      {:error, :no_push_commands}
    else
      {:ok, commands}
    end
  end

  # R51: args.delete → zero newHash commands (empty pack allowed).
  defp maybe_delete_commands(commands, remote_by_name, req) do
    args = Map.get(req, "args") || Map.get(req, :args) || %{}
    args = if is_map(args), do: stringify_keys(args), else: %{}
    del = Map.get(args, "delete")

    names =
      cond do
        del == true or del == "true" ->
          Enum.map(commands, & &1.name)

        is_binary(del) and del != "" ->
          [normalize_ref_name(del)]

        is_list(del) ->
          del
          |> Enum.filter(&(is_binary(&1) and &1 != ""))
          |> Enum.map(&normalize_ref_name/1)

        true ->
          nil
      end

    case names do
      nil ->
        commands

      [] ->
        commands

      ns ->
        for name <- ns do
          %{
            old_hash: Map.get(remote_by_name, name, @zero_oid),
            new_hash: @zero_oid,
            name: name
          }
        end
    end
  end

  defp normalize_ref_name(name) when is_binary(name) do
    cond do
      String.starts_with?(name, "refs/") -> name
      String.starts_with?(name, "heads/") -> "refs/" <> name
      true -> "refs/heads/" <> name
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

      # R48: lease old_hash tips as haves so pack omits objects remote already has.
      haves =
        commands
        |> Enum.map(& &1.old_hash)
        |> Enum.filter(fn h ->
          is_binary(h) and Regex.match?(~r/^[0-9a-fA-F]{40}$/, h) and h != @zero_oid
        end)
        |> Enum.uniq()

      if oids == [] do
        {:error, :no_push_oids}
      else
        case GitEngine.pack_build(pid, oids, haves: haves) do
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

  # Shared engine contract: atomically reserve a genuinely fresh empty root
  # before list-refs/pack import, then release the control lock on every exit.
  defp clone_begin(pid) do
    case GitEngine.run(pid, %{"op" => "clone.begin"}) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  defp clone_end(pid) do
    case GitEngine.run(pid, %{"op" => "clone.end"}) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  defp apply_init(pid) do
    case GitEngine.run(pid, %{"op" => "init"}) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  # Empty pack must never succeed — product honesty (P0.2).
  # D11: stream file or binary pack sources into chunked import_pack (default 1 MiB).
  defp apply_pack(pid, pack, opts)

  defp apply_pack(_pid, pack, _opts) when pack == <<>>, do: {:error, :empty_pack}

  defp apply_pack(pid, pack, opts) when is_binary(pack) do
    chunk = import_chunk_bytes(opts)
    size = byte_size(pack)
    abort_failed_import(pid, do_import_chunks(pid, pack, 0, size, chunk))
  end

  defp apply_pack(pid, {:file, path, offset}, opts)
       when is_binary(path) and is_integer(offset) and offset >= 0 do
    chunk = import_chunk_bytes(opts)
    size = SmartHttp.pack_byte_size({:file, path, offset})

    if size == 0 do
      {:error, :empty_pack}
    else
      case File.open(path, [:read, :raw, :binary]) do
        {:ok, device} ->
          try do
            case :file.position(device, offset) do
              {:ok, _} ->
                abort_failed_import(pid, import_from_device(pid, device, size, chunk))

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
  end

  defp apply_pack(_pid, _pack, _opts), do: {:error, :empty_pack}

  defp abort_failed_import(_pid, :ok), do: :ok

  defp abort_failed_import(pid, error) do
    _ = GitEngine.abort_import_pack(pid)
    error
  end

  defp import_chunk_bytes(opts) when is_list(opts) do
    case Keyword.get(opts, :import_chunk_bytes, 1024 * 1024) do
      n when is_integer(n) and n > 0 -> n
      _ -> 1024 * 1024
    end
  end

  defp import_from_device(pid, _device, remaining, _chunk) when remaining <= 0 do
    GitEngine.import_pack(pid, <<>>, final: true)
  end

  defp import_from_device(pid, device, remaining, chunk) do
    take = min(chunk, remaining)

    case :file.read(device, take) do
      {:ok, data} when is_binary(data) and byte_size(data) > 0 ->
        got = byte_size(data)
        final? = remaining - got <= 0

        case GitEngine.import_pack(pid, data, final: final?) do
          :ok ->
            if final?, do: :ok, else: import_from_device(pid, device, remaining - got, chunk)

          err ->
            err
        end

      :eof ->
        GitEngine.import_pack(pid, <<>>, final: true)

      {:ok, <<>>} ->
        GitEngine.import_pack(pid, <<>>, final: true)

      {:error, reason} ->
        {:error, reason}
    end
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

  # One atomic refs.import; never turn an all-or-nothing failure into a partial
  # set of best-effort secondary heads.
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

    apply_refs_array(pid, to_import)
  end

  defp apply_refs_array(_pid, []), do: :ok

  defp apply_refs_array(pid, entries) when is_list(entries) do
    refs =
      Enum.map(entries, fn %{name: name, hash: hash} ->
        %{"name" => name, "hash" => hash}
      end)

    case GitEngine.run(pid, %{
           "op" => "refs.import",
           "args" => %{"refs" => refs}
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

  # D9: after clone.apply set remote.origin.url + branch tracking for usable pull.
  defp configure_clone_remote(pid, binding, tip, refs) when is_map(binding) do
    url = Map.get(binding, :url) || Map.get(binding, "url") || ""
    connection_ref = Map.get(binding, :connection_ref) || Map.get(binding, "connection_ref")
    name = ref_name_of(tip, refs)
    hash = Map.get(tip, :hash) || Map.get(tip, "hash") || ""
    remote = "origin"

    {short, merge} =
      cond do
        is_binary(name) and String.starts_with?(name, "refs/heads/") ->
          {String.replace_prefix(name, "refs/heads/", ""), name}

        is_binary(name) and String.starts_with?(name, "refs/") ->
          short = name |> String.split("/") |> List.last()
          {short, name}

        is_binary(name) and name != "" ->
          {name, "refs/heads/#{name}"}

        true ->
          {"main", "refs/heads/main"}
      end

    with :ok <- remote_add_or_set_url(pid, remote, url),
         :ok <- maybe_set_agentos(pid, remote, connection_ref),
         :ok <- config_set(pid, "branch.#{short}.remote", remote),
         :ok <- config_set(pid, "branch.#{short}.merge", merge),
         :ok <- import_remote_tracking(pid, remote, short, hash) do
      :ok
    end
  end

  defp remote_add_or_set_url(pid, remote, url) when is_binary(url) and url != "" do
    case GitEngine.run(pid, %{
           "op" => "remote",
           "args" => %{"action" => "add", "name" => remote, "url" => url}
         }) do
      {:ok, m} ->
        if ok?(m) do
          :ok
        else
          config_set(pid, "remote.#{remote}.url", url)
        end

      _err ->
        config_set(pid, "remote.#{remote}.url", url)
    end
  end

  defp remote_add_or_set_url(_pid, _remote, _url), do: {:error, :bad_url}

  defp maybe_set_agentos(_pid, _remote, ref) when ref in [nil, ""], do: :ok

  defp maybe_set_agentos(pid, remote, ref) when is_binary(ref) do
    config_set(pid, "remote.#{remote}.agentos", ref)
  end

  defp config_set(pid, key, value) do
    case GitEngine.run(pid, %{
           "op" => "config",
           "args" => %{"action" => "set", "key" => key, "value" => value}
         }) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  defp config_get(pid, key) do
    case GitEngine.run(pid, %{
           "op" => "config",
           "args" => %{"action" => "get", "key" => key}
         }) do
      {:ok, m} when is_map(m) ->
        stdout = Map.get(m, "stdout") || Map.get(m, :stdout) || ""
        v = if is_binary(stdout), do: String.trim(stdout), else: ""

        if v != "", do: {:ok, v}, else: :error

      _ ->
        :error
    end
  end

  defp import_remote_tracking(_pid, _remote, _short, hash)
       when not is_binary(hash) or hash == "",
       do: :ok

  defp import_remote_tracking(pid, remote, short, hash)
       when is_binary(short) and short != "" do
    case GitEngine.run(pid, %{
           "op" => "refs.import",
           "args" => %{
             "name" => "refs/remotes/#{remote}/#{short}",
             "hash" => hash
           }
         }) do
      {:ok, m} -> if ok?(m), do: :ok, else: {:error, m}
      err -> err
    end
  end

  defp import_remote_tracking(_pid, _remote, _short, _hash), do: :ok

  # D20 / JS applySparseCone: cone-only sparse-set after clone.apply.
  # Patterns join as newline string; engine also accepts JSON arrays.
  defp apply_sparse_cone(pid, tip, refs, opts) do
    case sparse_cone_of(opts) do
      [] ->
        :ok

      cone ->
        patterns = Enum.join(cone, "\n")
        ref_name = ref_name_of(tip, refs)

        case GitEngine.run(pid, %{"op" => "sparse-set", "args" => %{"patterns" => patterns}}) do
          {:ok, m} ->
            if ok?(m) do
              # sparse-set force-checkouts HEAD into the cone; re-checkout the
              # cloned tip so branch name / worktree stay aligned with clone.apply.
              case GitEngine.run(pid, %{"op" => "checkout", "args" => %{"name" => ref_name}}) do
                {:ok, co} ->
                  if ok?(co) do
                    :ok
                  else
                    # Detached / unborn tip: sparse-set already materialised HEAD.
                    case GitEngine.run(pid, %{"op" => "rev-parse", "args" => %{"rev" => "HEAD"}}) do
                      {:ok, rp} -> if ok?(rp), do: :ok, else: {:error, co}
                      err -> err
                    end
                  end

                err ->
                  err
              end
            else
              {:error, m}
            end

          err ->
            err
        end
    end
  end

  defp sparse_cone_of(opts) when is_list(opts) do
    raw = Keyword.get(opts, :sparse_cone, [])
    normalize_sparse_cone(raw)
  end

  defp sparse_cone_of(_), do: []

  # Strip leading/trailing slashes; drop empties / non-binaries (JS parity).
  defp normalize_sparse_cone(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(fn p ->
      p
      |> String.trim()
      |> String.trim_leading("/")
      |> String.trim_trailing("/")
    end)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_sparse_cone(_), do: []

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

  # ── request parsing / remote resolve ───────────────────────────────────────

  defp decode_request(bin) when is_binary(bin) do
    case safe_json_decode(bin) do
      {:ok, map} when is_map(map) -> {:ok, stringify_keys(map)}
      _ -> {:error, :invalid_json}
    end
  end

  defp decode_request(map) when is_map(map), do: {:ok, stringify_keys(map)}

  # Resolve connection-bound or bare URL; guest auth/token fields are rejected.
  # D9: fill url/connection from engine remote.* config when only remote name
  # (or bare fetch/pull/push after clone) is provided.
  defp resolve_binding(engine_pid, req, opts) do
    args = Map.get(req, "args") || %{}
    args = if is_map(args), do: stringify_keys(args), else: %{}
    op = Map.get(req, "op") || Map.get(req, :op) || ""
    op = op |> to_string() |> String.downcase()
    args = fill_remote_args_from_config(engine_pid, op, args, opts)
    # D35: best-effort redacted origin from guest/host URL before dial/deny.
    note_origin(string_or_empty(Map.get(args, "url")))

    case Connections.resolve_remote(args, opts) do
      {:ok, binding} = ok ->
        note_origin(binding.url)
        ok

      other ->
        other
    end
  end

  defp fill_remote_args_from_config(pid, op, args, opts) when is_map(args) do
    url = string_or_empty(Map.get(args, "url"))

    if url != "" do
      args
    else
      remote = string_or_empty(Map.get(args, "remote"))

      remote =
        if remote == "" and op in ["fetch", "pull", "push"] and
             string_or_empty(Map.get(args, "connection")) == "" and
             string_or_empty(Map.get(args, "agentos")) == "" do
          "origin"
        else
          remote
        end

      args =
        if remote != "" and string_or_empty(Map.get(args, "remote")) == "" do
          Map.put(args, "remote", remote)
        else
          args
        end

      if remote == "" do
        args
      else
        remote_urls = keyword_map(opts, :remote_urls)
        remote_connections = keyword_map(opts, :remote_connections)

        # Prefer host remote_urls; otherwise use the canonical engine config op.
        args =
          if map_get_string(remote_urls, remote) != "" do
            args
          else
            case config_get(pid, "remote.#{remote}.url") do
              {:ok, u} -> Map.put(args, "url", u)
              _ -> args
            end
          end

        if string_or_empty(Map.get(args, "connection")) == "" and
             string_or_empty(Map.get(args, "agentos")) == "" and
             map_get_string(remote_connections, remote) == "" do
          case config_get(pid, "remote.#{remote}.agentos") do
            {:ok, cref} -> Map.put(args, "connection", cref)
            _ -> args
          end
        else
          args
        end
      end
    end
  end

  defp keyword_map(opts, key) when is_list(opts) and is_atom(key) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, key) do
        m when is_map(m) -> m
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp keyword_map(_, _), do: %{}

  defp string_or_empty(v) when is_binary(v), do: v
  # nil is an atom — must not become "nil".
  defp string_or_empty(nil), do: ""
  defp string_or_empty(v) when is_atom(v), do: Atom.to_string(v)
  defp string_or_empty(_), do: ""

  defp map_get_string(map, key) when is_map(map) do
    v = Map.get(map, key) || Map.get(map, safe_atom_key(key))
    if is_binary(v), do: v, else: ""
  end

  defp map_get_string(_, _), do: ""

  defp safe_atom_key(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_atom_key(k) when is_atom(k), do: k
  defp safe_atom_key(_), do: nil

  # Splice host/connection auth + binding origins into SmartHttp opts.
  # Credentials only from resolve (host catalog / host opts) — never guest body.
  defp apply_binding(opts, binding) when is_list(opts) and is_map(binding) do
    opts
    |> Keyword.put(:auth, Map.get(binding, :auth) || %{kind: :none})
    |> Keyword.put(:allowed_origins, Map.get(binding, :origins) || [])
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
  # contracts/git.kdl: clone default shallow; fetch/pull default full when depth omitted.
  defp depth_of(req, op) do
    args = Map.get(req, "args") || %{}
    args = if is_map(args), do: stringify_keys(args), else: %{}

    case Map.get(args, "depth") do
      d when is_integer(d) and d > 0 ->
        d

      d when is_integer(d) ->
        nil

      _ ->
        case op do
          :clone ->
            d = AgentOS.Contracts.Git.default_clone_depth()
            if is_integer(d) and d > 0, do: d, else: nil

          _ ->
            d = AgentOS.Contracts.Git.default_fetch_depth()
            if is_integer(d) and d > 0, do: d, else: nil
        end
    end
  end

  # R36: optional partial-clone filter (`blob:none`, `tree:0`, …).
  defp filter_of(req) do
    args = Map.get(req, "args") || %{}
    args = if is_map(args), do: stringify_keys(args), else: %{}

    case Map.get(args, "filter") do
      f when is_binary(f) ->
        f = String.trim(f)

        if f != "" and byte_size(f) <= 128 and not String.contains?(f, ["\n", "\r", <<0>>]) do
          f
        else
          nil
        end

      _ ->
        nil
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
    Map.get(m, "ok", Map.get(m, :ok)) == true
  end

  defp ok?(_), do: false

  defp response(ok, code, stdout, stderr) do
    ~s({"ok":#{ok},"code":#{code},"stdout":#{json_str(stdout)},"stderr":#{json_str(stderr)}})
  end

  defp response(ok, code, stdout, stderr, result) when is_map(result) do
    ~s({"ok":#{ok},"code":#{code},"stdout":#{json_str(stdout)},"stderr":#{json_str(stderr)},"result":#{json_encode_value(result)}})
  end

  defp args_of(req) when is_map(req) do
    case Map.get(req, "args") || Map.get(req, :args) do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp args_of(_), do: %{}

  defp json_encode_value(v) when is_map(v) do
    parts =
      Enum.map(v, fn {k, val} ->
        key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
        "#{json_str(key)}:#{json_encode_value(val)}"
      end)

    "{" <> Enum.join(parts, ",") <> "}"
  end

  defp json_encode_value(list) when is_list(list) do
    "[" <> Enum.map_join(list, ",", &json_encode_value/1) <> "]"
  end

  defp json_encode_value(s) when is_binary(s), do: json_str(s)
  defp json_encode_value(true), do: "true"
  defp json_encode_value(false), do: "false"
  defp json_encode_value(n) when is_integer(n) or is_float(n), do: to_string(n)
  defp json_encode_value(nil), do: "null"
  defp json_encode_value(other), do: json_str(inspect(other))

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

  # OTP 27+ :json; OTP 26 (Bazel) falls back to Jason_like parser.
  defp safe_json_decode(bin) when is_binary(bin) do
    AgentOS.GitEngine.Jason_like.decode(bin)
  end

  defp safe_json_decode(_), do: {:error, :invalid_json}

  defp decode_json_list(bin) when is_binary(bin) do
    case safe_json_decode(bin) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end
end
