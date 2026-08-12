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

  @spec perform(map(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def perform(effect, request_body, opts)
      when is_map(effect) and is_binary(request_body) and is_list(opts) do
    with {:ok, policy} <- Transport.resolve_policy(effect.path, opts) do
      case Keyword.get(opts, :http_effect) do
        callback when is_function(callback, 3) ->
          normalize(callback.(effect, request_body, Keyword.put(opts, :http_policy, policy)))

        nil ->
          perform_httpc(effect, request_body, opts, policy)

        _ ->
          {:error, :invalid_http_effect_handler}
      end
    end
  rescue
    error -> {:error, {:http_effect_exception, error}}
  end

  defp perform_httpc(effect, request_body, opts, policy) do
    with {:ok, method} <- method(effect.method),
         {:ok, request} <- request(method, effect.path, effect.headers, request_body, policy),
         {:ok, {{_version, status, _reason}, headers, body}} <-
           :httpc.request(method, request, [autoredirect: false], body_format: :binary),
         :ok <- reject_redirect(status),
         :ok <- enforce_size(body, opts) do
      {:ok, %{status: status, headers: response_headers(headers), body: body}}
    end
  end

  defp request(:get, url, headers, <<>>, policy),
    do: {:ok, {String.to_charlist(url), request_headers(headers, policy)}}

  defp request(:head, url, headers, <<>>, policy),
    do: {:ok, {String.to_charlist(url), request_headers(headers, policy)}}

  defp request(:post, url, headers, body, policy) do
    headers = request_headers(headers, policy)
    {content_type, headers} = take_content_type(headers)
    {:ok, {String.to_charlist(url), headers, content_type, body}}
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
end
