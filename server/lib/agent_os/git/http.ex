defmodule AgentOS.Git.Http do
  @moduledoc """
  Executes one raw HTTP exchange requested by the Git engine.

  It applies host-owned origin and credential policy but does not parse Git
  protocol bytes or decide Git operations. Request and response bodies are
  transferred between this module and the engine by `AgentOS.GitEngine`.
  """

  alias AgentOS.Git.Transport

  # Host resource policy. This is deliberately independent of the Git wire
  # contract; the engine enforces its own protocol and pack limits.
  @default_max_response_bytes 64 * 1024 * 1024

  @type body_source :: binary() | {:file, String.t()}
  @type stream_event :: {:begin, non_neg_integer(), map()} | {:chunk, binary()}
  @type stream_result(acc, terminal) ::
          {:ok, acc}
          | {:halt, terminal, acc}
          | {:error, term(), acc}

  @doc """
  Stream one response through `consumer`, carrying its accumulator forward.

  The consumer must acknowledge each event with `{:cont, accumulator}` before
  the HTTP client requests another chunk. `{:halt, value, accumulator}` cancels
  and drains the request immediately; this is how engine rejection or early
  termination propagates backpressure to the transport.
  """
  @spec stream(map(), body_source(), keyword(), acc, (stream_event(), acc ->
          {:cont, acc} | {:halt, terminal, acc} | {:error, term(), acc})) ::
          stream_result(acc, terminal)
        when acc: term(), terminal: term()
  def stream(effect, request_body, opts, accumulator, consumer)
      when is_map(effect) and (is_binary(request_body) or is_tuple(request_body)) and
             is_list(opts) and is_function(consumer, 2) do
    with {:ok, policy} <- Transport.resolve_policy(effect.path, opts) do
      stream_with_handler(effect, request_body, opts, policy, accumulator, consumer)
    else
      {:error, reason} -> {:error, reason, accumulator}
    end
  rescue
    error -> {:error, {:http_effect_exception, error}, accumulator}
  end

  @spec perform(map(), body_source(), keyword()) :: {:ok, map()} | {:error, term()}
  def perform(effect, request_body, opts)
      when is_map(effect) and (is_binary(request_body) or is_tuple(request_body)) and
             is_list(opts) do
    with {:ok, policy} <- Transport.resolve_policy(effect.path, opts) do
      case {Keyword.get(opts, :http_executor), Keyword.get(opts, :http_effect)} do
        {nil, nil} ->
          perform_httpc(effect, request_body, opts, policy)

        {module, nil} when is_atom(module) and not is_nil(module) ->
          normalize_source(
            module.perform(effect, request_body, Keyword.put(opts, :http_policy, policy))
          )

        {nil, callback} when is_function(callback, 3) ->
          with {:ok, body} <- materialize_callback_body(request_body) do
            normalize(callback.(effect, body, Keyword.put(opts, :http_policy, policy)))
          end

        _ ->
          {:error, :invalid_http_effect_handler}
      end
    end
  rescue
    error -> {:error, {:http_effect_exception, error}}
  end

  defp stream_with_handler(effect, request_body, opts, policy, accumulator, consumer) do
    case {Keyword.get(opts, :http_executor), Keyword.get(opts, :http_effect)} do
      {nil, nil} ->
        stream_httpc(effect, request_body, opts, policy, accumulator, consumer)

      {module, nil} when is_atom(module) and not is_nil(module) ->
        executor_opts = Keyword.put(opts, :http_policy, policy)

        if function_exported?(module, :stream, 5) do
          module.stream(effect, request_body, executor_opts, accumulator, consumer)
        else
          stream_buffered_result(
            module.perform(effect, request_body, executor_opts),
            accumulator,
            consumer
          )
        end

      {nil, callback} when is_function(callback, 3) ->
        result =
          with {:ok, body} <- materialize_callback_body(request_body) do
            callback.(effect, body, Keyword.put(opts, :http_policy, policy))
          end

        stream_buffered_result(result, accumulator, consumer)

      _ ->
        {:error, :invalid_http_effect_handler, accumulator}
    end
  end

  defp stream_buffered_result(result, accumulator, consumer) do
    with {:ok, response} <- normalize_source(result),
         :ok <- reject_redirect(response.status),
         {:cont, accumulator} <- consumer.({:begin, response.status, response.headers}, accumulator) do
      stream_body_source(response.body, accumulator, consumer)
    else
      {:halt, value, next} -> cleanup_result_source(result); {:halt, value, next}
      {:error, reason, next} -> cleanup_result_source(result); {:error, reason, next}
      {:error, reason} -> cleanup_result_source(result); {:error, reason, accumulator}
      _ -> cleanup_result_source(result); {:error, :invalid_stream_consumer_result, accumulator}
    end
  end

  defp stream_body_source(<<>>, accumulator, _consumer), do: {:ok, accumulator}

  defp stream_body_source(body, accumulator, consumer) when is_binary(body) do
    size = min(byte_size(body), 64 * 1024)
    <<chunk::binary-size(^size), rest::binary>> = body

    case consumer.({:chunk, chunk}, accumulator) do
      {:cont, next} -> stream_body_source(rest, next, consumer)
      {:halt, value, next} -> {:halt, value, next}
      {:error, reason, next} -> {:error, reason, next}
      _ -> {:error, :invalid_stream_consumer_result, accumulator}
    end
  end

  defp stream_body_source({:file, path}, accumulator, consumer) do
    result =
      case File.open(path, [:read, :binary]) do
        {:ok, file} ->
          try do
            stream_body_file(file, accumulator, consumer)
          after
            File.close(file)
          end

        {:error, reason} ->
          {:error, reason, accumulator}
      end

    File.rm(path)
    result
  end

  defp stream_body_file(file, accumulator, consumer) do
    case IO.binread(file, 64 * 1024) do
      :eof -> {:ok, accumulator}
      {:error, reason} -> {:error, reason, accumulator}
      chunk ->
        case consumer.({:chunk, chunk}, accumulator) do
          {:cont, next} -> stream_body_file(file, next, consumer)
          {:halt, value, next} -> {:halt, value, next}
          {:error, reason, next} -> {:error, reason, next}
          _ -> {:error, :invalid_stream_consumer_result, accumulator}
        end
    end
  end

  defp cleanup_result_source({:ok, %{body: {:file, path}}}), do: File.rm(path)
  defp cleanup_result_source(_), do: :ok

  defp stream_httpc(effect, request_body, opts, policy, accumulator, consumer) do
    max = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)

    with {:ok, method} <- method(effect.method),
         {:ok, request} <- request(method, effect.path, effect.headers, request_body, policy),
         {:ok, request_id} <-
           :httpc.request(
             method,
             request,
             [autoredirect: false],
             sync: false,
             stream: {:self, :once},
             body_format: :binary
           ) do
      collect_httpc_stream(request_id, max, 200, %{}, 0, nil, false, accumulator, consumer)
    else
      {:error, reason} -> {:error, reason, accumulator}
    end
  end

  defp collect_httpc_stream(
         request_id,
         max,
         status,
         headers,
         size,
         handler,
         begun?,
         accumulator,
         consumer
       ) do
    receive do
      {:http, {^request_id, :stream_start, hdrs}} ->
        {next_status, response_headers} = stream_metadata(hdrs, status, headers)

        case begin_stream(next_status, response_headers, begun?, accumulator, consumer) do
          {:cont, next} ->
            collect_httpc_stream(
              request_id,
              max,
              next_status,
              response_headers,
              size,
              handler,
              true,
              next,
              consumer
            )

          result ->
            cancel_stream_result(request_id, result)
        end

      {:http, {^request_id, :stream_start, hdrs, next_handler}} ->
        {next_status, response_headers} = stream_metadata(hdrs, status, headers)

        case begin_stream(next_status, response_headers, begun?, accumulator, consumer) do
          {:cont, next} ->
            :httpc.stream_next(next_handler)

            collect_httpc_stream(
              request_id,
              max,
              next_status,
              response_headers,
              size,
              next_handler,
              true,
              next,
              consumer
            )

          result ->
            cancel_stream_result(request_id, result)
        end

      {:http, {^request_id, :stream, bytes}} when is_binary(bytes) ->
        next_size = size + byte_size(bytes)

        cond do
          next_size > max ->
            cancel_httpc(request_id)
            {:error, :body_too_large, accumulator}

          true ->
            with {:cont, begun_acc} <- begin_stream(status, headers, begun?, accumulator, consumer),
                 {:cont, next} <- consumer.({:chunk, bytes}, begun_acc) do
              if is_pid(handler), do: :httpc.stream_next(handler)

              collect_httpc_stream(
                request_id,
                max,
                status,
                headers,
                next_size,
                handler,
                true,
                next,
                consumer
              )
            else
              result -> cancel_stream_result(request_id, result)
            end
        end

      {:http, {^request_id, :stream_end, hdrs}} ->
        final_headers = merge_httpc_headers(headers, hdrs)
        final_status = status || status_from_headers(final_headers)

        with value when is_integer(value) <- final_status,
             :ok <- reject_redirect(value),
             {:cont, next} <- begin_stream(value, final_headers, begun?, accumulator, consumer) do
          {:ok, next}
        else
          {:halt, value, next} -> {:halt, value, next}
          {:error, reason, next} -> {:error, reason, next}
          {:error, reason} -> {:error, reason, accumulator}
          _ -> {:error, :missing_http_status, accumulator}
        end

      {:http, {^request_id, {{_version, next_status, _reason}, hdrs, body}}} ->
        body = httpc_body(body)
        response_headers = merge_httpc_headers(headers, hdrs)

        with :ok <- reject_redirect(next_status),
             :ok <- enforce_size(body, max_response_bytes: max),
             {:cont, next} <- consumer.({:begin, next_status, response_headers}, accumulator) do
          stream_body_source(body, next, consumer)
        else
          {:halt, value, next} -> {:halt, value, next}
          {:error, reason, next} -> {:error, reason, next}
          {:error, reason} -> {:error, reason, accumulator}
          _ -> {:error, :invalid_stream_consumer_result, accumulator}
        end

      {:http, {^request_id, {:error, reason}}} ->
        {:error, reason, accumulator}
    after
      120_000 ->
        cancel_httpc(request_id)
        {:error, :timeout, accumulator}
    end
  end

  defp begin_stream(_status, _headers, true, accumulator, _consumer),
    do: {:cont, accumulator}

  defp begin_stream(status, headers, false, accumulator, consumer) do
    case reject_redirect(status) do
      :ok -> consumer.({:begin, status, headers}, accumulator)
      {:error, reason} -> {:error, reason, accumulator}
    end
  end

  defp cancel_stream_result(request_id, {:halt, value, accumulator}) do
    cancel_httpc(request_id)
    {:halt, value, accumulator}
  end

  defp cancel_stream_result(request_id, {:error, reason, accumulator}) do
    cancel_httpc(request_id)
    {:error, reason, accumulator}
  end

  defp cancel_stream_result(request_id, _other) do
    cancel_httpc(request_id)
    {:error, :invalid_stream_consumer_result, nil}
  end

  defp perform_httpc(effect, request_body, opts, policy) do
    max = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)
    response_path = spool_path("response")

    with {:ok, method} <- method(effect.method),
         {:ok, request} <- request(method, effect.path, effect.headers, request_body, policy),
         {:ok, response_file} <- File.open(response_path, [:write, :binary, :exclusive]) do
      result =
        :httpc.request(
          method,
          request,
          [autoredirect: false],
          sync: false,
          stream: {:self, :once},
          body_format: :binary
        )

      case result do
        {:ok, request_id} ->
          collect_httpc(request_id, max, 200, %{}, response_file, response_path, 0, nil)

        {:error, reason} ->
          File.close(response_file)
          File.rm(response_path)
          {:error, reason}
      end
    else
      {:error, :eexist} -> {:error, :spool_collision}
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_httpc(request_id, max, status, headers, file, path, size, handler) do
    receive do
      {:http, {^request_id, :stream_start, hdrs}} ->
        {next_status, response_headers} = stream_metadata(hdrs, status, headers)
        collect_httpc(request_id, max, next_status, response_headers, file, path, size, handler)

      {:http, {^request_id, :stream_start, hdrs, next_handler}} ->
        :httpc.stream_next(next_handler)
        {next_status, response_headers} = stream_metadata(hdrs, status, headers)
        collect_httpc(request_id, max, next_status, response_headers, file, path, size, next_handler)

      {:http, {^request_id, :stream, bin}} when is_binary(bin) ->
        next = size + byte_size(bin)

        if next > max do
          cancel_httpc(request_id)
          File.close(file)
          File.rm(path)
          {:error, :body_too_large}
        else
          case write_spool(file, path, bin) do
            :ok ->
              if is_pid(handler), do: :httpc.stream_next(handler)
              collect_httpc(request_id, max, status, headers, file, path, next, handler)

            {:error, reason} ->
              cancel_httpc(request_id)
              {:error, reason}
          end
        end

      {:http, {^request_id, :stream_end, hdrs}} ->
        :ok = File.close(file)
        final_headers = merge_httpc_headers(headers, hdrs)
        final_status = status || status_from_headers(final_headers)

        case final_status do
          value when is_integer(value) ->
            with :ok <- reject_redirect(value) do
              {:ok, %{status: value, headers: final_headers, body: {:file, path}}}
            else
              error -> File.rm(path); error
            end

          _ ->
            File.rm(path)
            {:error, :missing_http_status}
        end

      {:http, {^request_id, {{_version, next_status, _reason}, hdrs, body}}} ->
        body = httpc_body(body)

        with :ok <- reject_redirect(next_status),
             :ok <- enforce_size(body, max_response_bytes: max),
             :ok <- IO.binwrite(file, body),
             :ok <- File.close(file) do
          {:ok, %{status: next_status, headers: merge_httpc_headers(headers, hdrs), body: {:file, path}}}
        else
          error ->
            cancel_httpc(request_id)
            File.close(file)
            File.rm(path)
            error
        end

      {:http, {^request_id, {:error, reason}}} ->
        File.close(file)
        File.rm(path)
        {:error, reason}
    after
      120_000 ->
        cancel_httpc(request_id)
        File.close(file)
        File.rm(path)
        {:error, :timeout}
    end
  end

  defp stream_metadata(headers, status, existing) do
    merged = merge_httpc_headers(existing, headers)
    {status || status_from_headers(merged), merged}
  end

  defp status_from_headers(headers) do
    value = headers["status"] || headers[":status"] || headers["status-code"]

    case Integer.parse(to_string(value || "")) do
      {status, ""} when status >= 100 and status <= 999 -> status
      _ -> nil
    end
  end

  defp cancel_httpc(request_id) do
    _ = :httpc.cancel_request(request_id)
    flush_httpc(request_id)
  end

  defp flush_httpc(request_id) do
    receive do
      {:http, {^request_id, _}} -> flush_httpc(request_id)
    after
      0 -> :ok
    end
  end

  defp httpc_body(body) when is_binary(body), do: body
  defp httpc_body(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp httpc_body(_), do: <<>>

  defp merge_httpc_headers(existing, headers) when is_map(existing) and is_list(headers) do
    Map.merge(existing, response_headers(headers))
  end

  defp merge_httpc_headers(existing, _), do: existing

  defp request(:get, url, headers, <<>>, policy),
    do: {:ok, {String.to_charlist(url), request_headers(headers, policy)}}

  defp request(:head, url, headers, <<>>, policy),
    do: {:ok, {String.to_charlist(url), request_headers(headers, policy)}}

  defp request(:post, url, headers, body, policy) do
    headers = request_headers(headers, policy)
    {content_type, headers} = take_content_type(headers)

    case body do
      {:file, path} ->
        streamed_headers =
          Enum.reject(headers, fn {name, _} ->
            String.downcase(to_string(name)) in ["content-length", "transfer-encoding"]
          end)

        {:ok,
         {String.to_charlist(url), streamed_headers, content_type,
          {:chunkify, &next_file_chunk/1, {:unopened, path}}}}

      binary when is_binary(binary) ->
        {:ok, {String.to_charlist(url), headers, content_type, binary}}
    end
  end

  defp request(_, _, _, _, _), do: {:error, :invalid_http_request}

  defp request_headers(headers, policy) do
    engine =
      headers
      |> Enum.reject(fn {key, _value} -> String.downcase(to_string(key)) == "authorization" end)
      |> Enum.map(fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    host =
      policy.auth
      |> Transport.auth_headers()
      |> Enum.map(fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    host ++ engine
  end

  defp take_content_type(headers) do
    {matches, rest} =
      Enum.split_with(headers, fn {name, _value} ->
        name |> to_string() |> String.downcase() == "content-type"
      end)

    content_type =
      case matches do
        [{_, value} | _] -> value
        [] -> ~c"application/octet-stream"
      end

    {content_type, rest}
  end

  defp response_headers(headers) do
    headers
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Enum.sort()
    |> Map.new()
  end

  defp method(value) do
    case String.upcase(value) do
      "GET" -> {:ok, :get}
      "HEAD" -> {:ok, :head}
      "POST" -> {:ok, :post}
      _ -> {:error, :method_not_allowed}
    end
  end

  defp reject_redirect(status) when status >= 300 and status < 400,
    do: {:error, :redirect_not_allowed}

  defp reject_redirect(_), do: :ok

  defp enforce_size(body, opts) do
    max = Keyword.get(opts, :max_response_bytes, @default_max_response_bytes)
    if byte_size(body) <= max, do: :ok, else: {:error, :body_too_large}
  end

  defp normalize({:ok, response}) when is_map(response) do
    with status when is_integer(status) <- Map.get(response, :status),
         headers when is_map(headers) <- Map.get(response, :headers, %{}),
         body when is_binary(body) <- Map.get(response, :body, <<>>) do
      {:ok, %{status: status, headers: headers, body: body}}
    else
      _ -> {:error, :invalid_http_effect_response}
    end
  end

  defp normalize({:error, _} = error), do: error
  defp normalize(other), do: {:error, {:invalid_http_effect_response, other}}

  defp normalize_source({:ok, response}) when is_map(response) do
    with status when is_integer(status) <- Map.get(response, :status),
         headers when is_map(headers) <- Map.get(response, :headers, %{}),
         body when is_binary(body) or is_tuple(body) <- Map.get(response, :body, <<>>) do
      {:ok, %{status: status, headers: headers, body: body}}
    else
      _ -> {:error, :invalid_http_executor_response}
    end
  end

  defp normalize_source({:error, _} = error), do: error
  defp normalize_source(other), do: {:error, {:invalid_http_executor_response, other}}

  defp next_file_chunk(file) when is_pid(file) or is_port(file) do
    case IO.binread(file, 64 * 1024) do
      :eof ->
        File.close(file)
        :eof

      {:error, reason} ->
        File.close(file)
        raise File.Error, reason: reason, action: "read Git HTTP spool"

      bytes ->
        {:ok, bytes, file}
    end
  end

  defp next_file_chunk({:unopened, path}) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} -> next_file_chunk(file)
      {:error, reason} -> raise File.Error, reason: reason, action: "open Git HTTP spool"
    end
  end

  defp materialize_callback_body(body) when is_binary(body), do: {:ok, body}
  defp materialize_callback_body({:file, path}), do: File.read(path)

  defp write_spool(file, path, bytes) do
    :ok = IO.binwrite(file, bytes)
  rescue
    error ->
      File.close(file)
      File.rm(path)
      {:error, {:spool_write_failed, error}}
  end

  defp spool_path(kind) do
    Path.join(
      System.tmp_dir!(),
      "agentos-git-http-#{kind}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end
end
