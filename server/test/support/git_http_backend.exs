# Test-only: local smart-HTTP via system `git-http-backend` (D27/D28).
# Not product path — infrastructure so product BEAM SmartHttp can dial real HTTP.
defmodule AgentOS.GitHttpBackend do
  @moduledoc false

  @backend_candidates [
    "/usr/lib/git-core/git-http-backend",
    "/usr/libexec/git-core/git-http-backend"
  ]

  @doc "True when system git + git-http-backend are available."
  def available? do
    is_binary(System.find_executable("git")) and is_binary(backend_path())
  end

  @doc """
  Start a multi-request smart-HTTP server over a seeded bare repo.

  Returns `%{url, origin, tip, bare, project_root, branch, stop}`.
  `stop.()` shuts the acceptor and removes the temp project root.
  """
  def start!(opts \\ []) do
    unless available?() do
      raise "git + git-http-backend required for real-HTTP e2e (D27/D28)"
    end

    repo_name = Keyword.get(opts, :repo_name, "demo.git")
    file_name = Keyword.get(opts, :file, "README.md")
    file_body = Keyword.get(opts, :content, "hello real-http\n")
    branch = Keyword.get(opts, :branch, "main")

    project_root =
      Path.join(
        System.tmp_dir!(),
        "agentos-githttp-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.rm_rf!(project_root)
    File.mkdir_p!(project_root)

    src = Path.join(project_root, "_src")
    bare = Path.join(project_root, repo_name)
    File.mkdir_p!(src)

    git!(["init", "-b", branch], cd: src)
    git!(["config", "user.email", "d27@agent-os.test"], cd: src)
    git!(["config", "user.name", "D27"], cd: src)
    File.write!(Path.join(src, file_name), file_body)
    git!(["add", "."], cd: src)
    git!(["commit", "-m", "init"], cd: src)
    git!(["clone", "--bare", src, bare])
    git!(["--git-dir", bare, "config", "http.receivepack", "true"])
    git!(["--git-dir", bare, "config", "http.uploadpack", "true"])
    tip = git_out!(["--git-dir", bare, "rev-parse", "HEAD"]) |> String.trim()

    backend = backend_path()

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)

    server =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        accept_loop(listen, backend, project_root)
      end)

    stop = fn ->
      send(server, :stop)
      _ = :gen_tcp.close(listen)
      ref = Process.monitor(server)

      receive do
        {:DOWN, ^ref, :process, ^server, _} -> :ok
      after
        2_000 ->
          Process.exit(server, :kill)
          :ok
      end

      File.rm_rf(project_root)
      :ok
    end

    origin = "http://127.0.0.1:#{port}"
    url = origin <> "/" <> repo_name

    %{
      url: url,
      origin: origin,
      tip: tip,
      bare: bare,
      project_root: project_root,
      branch: branch,
      stop: stop
    }
  end

  def rev_parse_head(bare) when is_binary(bare) do
    git_out!(["--git-dir", bare, "rev-parse", "HEAD"]) |> String.trim()
  end

  def rev_parse_ref(bare, ref) when is_binary(bare) and is_binary(ref) do
    git_out!(["--git-dir", bare, "rev-parse", ref]) |> String.trim()
  end

  @doc "Build a pack containing objects reachable from the given revs."
  def pack_objects(bare, revs) when is_binary(bare) and is_list(revs) do
    {objs, 0} = git_with_stdin!(["--git-dir", bare, "rev-list", "--objects"] ++ revs, "")

    oids =
      objs
      |> String.split("\n", trim: true)
      |> Enum.map(fn line -> line |> String.split() |> hd() end)
      |> Enum.join("\n")
      |> Kernel.<>("\n")

    {pack, 0} = git_with_stdin!(["--git-dir", bare, "pack-objects", "--stdout"], oids)
    pack
  end

  # ── acceptor ──────────────────────────────────────────────────────────────

  defp accept_loop(listen, backend, project_root) do
    receive do
      :stop ->
        _ = :gen_tcp.close(listen)
        :ok
    after
      0 ->
        case :gen_tcp.accept(listen, 500) do
          {:ok, sock} ->
            _ = handle_http(sock, backend, project_root)
            _ = :gen_tcp.close(sock)
            accept_loop(listen, backend, project_root)

          {:error, :timeout} ->
            accept_loop(listen, backend, project_root)

          {:error, :closed} ->
            :ok

          {:error, _} ->
            accept_loop(listen, backend, project_root)
        end
    end
  end

  defp handle_http(sock, backend, project_root) do
    case recv_http_request(sock) do
      {:ok, method, path_q, headers, body} ->
        {path_info, query} = split_path_query(path_q)
        env = cgi_env(method, path_info, query, headers, body, project_root)
        cgi_out = run_cgi(backend, env, body)
        send_cgi_response(sock, cgi_out)

      {:error, _} ->
        :ok
    end
  end

  defp run_cgi(backend, env, body) when is_binary(backend) and is_binary(body) do
    body_path =
      Path.join(
        System.tmp_dir!(),
        "agentos-cgi-body-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.write!(body_path, body)

    try do
      # bash redirects stdin so git-http-backend sees EOF after body (POST) or empty (GET).
      # Inherit full env then overlay CGI vars (git needs PATH/HOME; progress on stderr only).
      full_env =
        System.get_env()
        |> Map.new()
        |> Map.merge(Map.new(env))
        |> Map.to_list()

      {out, _code} =
        System.cmd(
          "bash",
          ["-c", "exec \"$0\" < \"$1\"", backend, body_path],
          env: full_env,
          stderr_to_stdout: false
        )

      out
    after
      File.rm(body_path)
    end
  end

  defp recv_http_request(sock) do
    case recv_headers(sock, <<>>, 1_000_000) do
      {:ok, head, rest} ->
        case String.split(head, "\r\n", parts: 2) do
          [request_line | rest_head] ->
            headers_blob = List.first(rest_head) || ""
            [method, path_q | _] = String.split(request_line, " ", parts: 3)
            headers = parse_headers(headers_blob)
            cl = header_int(headers, "content-length", 0)

            body =
              cond do
                cl <= 0 ->
                  <<>>

                byte_size(rest) >= cl ->
                  binary_part(rest, 0, cl)

                true ->
                  need = cl - byte_size(rest)

                  case :gen_tcp.recv(sock, need, 30_000) do
                    {:ok, more} -> rest <> more
                    _ -> rest
                  end
              end

            {:ok, method, path_q, headers, body}

          _ ->
            {:error, :bad_request}
        end

      err ->
        err
    end
  end

  # Read until end of HTTP headers; return {headers_without_delim, already_read_body}.
  defp recv_headers(_sock, acc, budget) when budget <= 0, do: {:error, :too_large}

  defp recv_headers(sock, acc, budget) do
    case :binary.match(acc, "\r\n\r\n") do
      {idx, 4} ->
        head = binary_part(acc, 0, idx)
        rest = binary_part(acc, idx + 4, byte_size(acc) - idx - 4)
        {:ok, head, rest}

      :nomatch ->
        case :gen_tcp.recv(sock, 0, 10_000) do
          {:ok, chunk} ->
            recv_headers(sock, acc <> chunk, budget - byte_size(chunk))

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp parse_headers(blob) do
    blob
    |> String.split("\r\n")
    |> Enum.reduce(%{}, fn
      "", acc ->
        acc

      line, acc ->
        case String.split(line, ":", parts: 2) do
          [k, v] -> Map.put(acc, String.downcase(String.trim(k)), String.trim(v))
          _ -> acc
        end
    end)
  end

  defp header_int(headers, key, default) do
    case Map.get(headers, key) do
      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, _} -> n
          :error -> default
        end

      _ ->
        default
    end
  end

  defp split_path_query(path_q) do
    case String.split(path_q, "?", parts: 2) do
      [p, q] -> {p, q}
      [p] -> {p, ""}
    end
  end

  defp cgi_env(method, path_info, query, headers, body, project_root) do
    path = System.get_env("PATH") || "/usr/bin:/bin"

    base = [
      {"GIT_PROJECT_ROOT", project_root},
      {"GIT_HTTP_EXPORT_ALL", "1"},
      {"PATH_INFO", path_info},
      {"QUERY_STRING", query},
      {"REQUEST_METHOD", method},
      {"CONTENT_TYPE", Map.get(headers, "content-type", "")},
      {"CONTENT_LENGTH", Integer.to_string(byte_size(body))},
      {"REMOTE_ADDR", "127.0.0.1"},
      {"REMOTE_USER", "agentos-test"},
      {"SERVER_PROTOCOL", "HTTP/1.1"},
      {"GATEWAY_INTERFACE", "CGI/1.1"},
      {"PATH", path}
    ]

    case Map.get(headers, "git-protocol") do
      v when is_binary(v) and v != "" -> [{"HTTP_GIT_PROTOCOL", v} | base]
      _ -> base
    end
  end

  defp send_cgi_response(sock, cgi_out) when is_binary(cgi_out) do
    {head, body} =
      cond do
        String.contains?(cgi_out, "\r\n\r\n") ->
          [h, b] = String.split(cgi_out, "\r\n\r\n", parts: 2)
          {h, b}

        String.contains?(cgi_out, "\n\n") ->
          [h, b] = String.split(cgi_out, "\n\n", parts: 2)
          {h, b}

        true ->
          {"Status: 200 OK", cgi_out}
      end

    {status, headers} =
      head
      |> String.split(~r/\r?\n/)
      |> Enum.reduce({200, []}, fn line, {st, hs} ->
        line = String.trim_trailing(line, "\r")

        cond do
          line == "" ->
            {st, hs}

          String.starts_with?(String.downcase(line), "status:") ->
            rest = line |> String.split(":", parts: 2) |> Enum.at(1) |> String.trim()

            code =
              case Integer.parse(rest) do
                {n, _} -> n
                :error -> 200
              end

            {code, hs}

          String.contains?(line, ":") ->
            [k, v] = String.split(line, ":", parts: 2)
            k = String.trim(k)
            v = String.trim(v)

            if String.downcase(k) in ["status", "transfer-encoding"] do
              {st, hs}
            else
              {st, [{k, v} | hs]}
            end

          true ->
            {st, hs}
        end
      end)

    headers =
      if Enum.any?(headers, fn {k, _} -> String.downcase(k) == "content-length" end) do
        headers
      else
        [{"Content-Length", Integer.to_string(byte_size(body))} | headers]
      end

    headers = [{"Connection", "close"} | headers]

    status_text =
      case status do
        200 -> "OK"
        403 -> "Forbidden"
        404 -> "Not Found"
        500 -> "Internal Server Error"
        _ -> "OK"
      end

    resp =
      IO.iodata_to_binary([
        "HTTP/1.1 #{status} #{status_text}\r\n",
        Enum.map(Enum.reverse(headers), fn {k, v} -> [k, ": ", v, "\r\n"] end),
        "\r\n",
        body
      ])

    _ = :gen_tcp.send(sock, resp)
    :ok
  end

  defp backend_path do
    Enum.find(@backend_candidates, &File.regular?/1)
  end

  defp git!(args, opts \\ []) do
    cd = Keyword.get(opts, :cd)

    cmd_opts =
      [stderr_to_stdout: true]
      |> then(fn o -> if cd, do: Keyword.put(o, :cd, cd), else: o end)

    case System.cmd("git", args, cmd_opts) do
      {_, 0} -> :ok
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end

  defp git_out!(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} failed (#{code}): #{out}"
    end
  end

  defp git_with_stdin!(args, stdin) when is_binary(stdin) do
    path =
      Path.join(
        System.tmp_dir!(),
        "agentos-gitin-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.write!(path, stdin)

    try do
      # Quote-safe: pass paths as $0/$1 after -- via bash -c pattern.
      cmd = "git \"$@\" < \"$IN\""
      env = [{"IN", path} | Enum.map(System.get_env(), fn {k, v} -> {k, v} end)]

      case System.cmd("bash", ["-c", cmd, "git"] ++ args, env: env, stderr_to_stdout: true) do
        {out, code} -> {out, code}
      end
    after
      File.rm(path)
    end
  end
end
