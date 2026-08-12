defmodule AgentOS.Git.Transport do
  @moduledoc "Host HTTP policy used while servicing engine effects."

  @spec ensure_url_allowed(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def ensure_url_allowed(url, opts) when is_binary(url) do
    with {:ok, origin} <- origin(url),
         true <- allowed?(origin, Keyword.get(opts, :allowed_origins, [])) do
      {:ok, origin}
    else
      false -> {:error, :origin_not_allowed}
      :error -> {:error, :bad_remote_url}
    end
  end

  @doc """
  Resolve a guest remote the same way JS `resolveGitRemote` does.

  A named `connection` / `agentos` ref binds **that** connection's origins and
  auth. A bare URL requires `:allowed_origins` even when a connection catalog
  is attached — catalog secrets are never chosen by effect origin alone.
  """
  @spec resolve_remote(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def resolve_remote(args, opts) when is_map(args) and is_list(opts) do
    connections = Keyword.get(opts, :connections, [])
    connections = if is_list(connections), do: connections, else: []
    reference = connection_ref(args)

    with {:ok, connection} <- fetch_connection(reference, connections),
         {:ok, url} <- remote_locator(args, connection),
         {:ok, origin} <- require_origin(url),
         :ok <- authorize_binding(origin, connection, opts),
         :ok <- reject_query_auth(connection) do
      {:ok,
       %{
         url: url,
         origin: origin,
         connection_ref: reference,
         auth: binding_auth(connection, opts),
         origins: binding_origins(connection, opts)
       }}
    end
  end

  @doc "Resolve host-owned origin and credentials for one effect URL."
  @spec resolve_policy(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def resolve_policy(url, opts) when is_binary(url) do
    case Keyword.get(opts, :remote_binding, Keyword.get(opts, :remote_bindings)) do
      %{origins: origins, auth: auth} ->
        with {:ok, origin} <- require_origin(url),
             true <- allowed?(origin, origins) do
          {:ok, %{origin: origin, auth: auth}}
        else
          false -> {:error, :origin_not_allowed}
          {:error, _} = error -> error
        end

      bindings when is_list(bindings) ->
        resolve_prebound_policy(url, bindings)

      _ ->
        connections = Keyword.get(opts, :connections, [])

        cond do
          is_list(connections) and connections != [] ->
            {:error, :origin_not_allowed}

          true ->
            with {:ok, origin} <- ensure_url_allowed(url, opts) do
              {:ok, %{origin: origin, auth: Keyword.get(opts, :auth)}}
            end
        end
    end
  end

  @spec auth_headers(map() | nil) :: [{String.t(), String.t()}]
  def auth_headers(nil), do: []
  def auth_headers(%{kind: :none}), do: []
  def auth_headers(%{"kind" => "none"}), do: []

  def auth_headers(%{kind: :bearer, token: token}) when is_binary(token),
    do: [{"authorization", "Bearer " <> token}]

  def auth_headers(%{kind: :basic, username: username, password: password})
      when is_binary(username) and is_binary(password),
      do: [{"authorization", "Basic " <> Base.encode64(username <> ":" <> password)}]

  def auth_headers(%{kind: :header, name: name, value: value})
      when is_binary(name) and is_binary(value),
      do: [{validate_header_name!(name), validate_header_value!(value)}]

  def auth_headers(_), do: raise(ArgumentError, "invalid Git host authentication")

  @doc "Canonical http(s) origin with no userinfo. Default ports are omitted."
  @spec origin(String.t()) :: {:ok, String.t()} | :error
  def origin(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: nil, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        default = if scheme == "https", do: 443, else: 80
        suffix = if is_nil(port) or port == default, do: "", else: ":#{port}"
        {:ok, String.downcase(scheme) <> "://" <> String.downcase(host) <> suffix}

      _ ->
        :error
    end
  end

  def origin(_), do: :error

  @doc "Canonical origin equality. An empty allowlist fails closed."
  @spec allowed?(String.t(), [String.t()]) :: boolean()
  def allowed?(origin, origins) when is_binary(origin) and is_list(origins) and origins != [] do
    Enum.any?(origins, fn candidate ->
      case origin(candidate) do
        {:ok, ^origin} -> true
        _ -> false
      end
    end)
  end

  def allowed?(_, _), do: false

  defp require_origin(url) do
    case origin(url) do
      {:ok, origin} -> {:ok, origin}
      :error -> {:error, :bad_remote_url}
    end
  end

  defp resolve_prebound_policy(url, bindings) do
    with {:ok, origin} <- require_origin(url) do
      case Enum.filter(bindings, &effect_belongs_to_remote?(url, &1[:url] || &1["url"])) do
        [%{auth: auth}] ->
          {:ok, %{origin: origin, auth: auth}}

        [] ->
          {:error, :origin_not_allowed}

        _ ->
          {:error, :ambiguous_connection_origin}
      end
    end
  end

  defp effect_belongs_to_remote?(effect_url, remote_url) when is_binary(remote_url) do
    effect = URI.parse(effect_url)
    remote = URI.parse(remote_url)

    with {:ok, effect_origin} <- origin(effect_url),
         {:ok, remote_origin} <- origin(remote_url) do
      root = remote.path |> to_string() |> String.trim_trailing("/")
      path = effect.path |> to_string()
      effect_origin == remote_origin and (path == root or String.starts_with?(path, root <> "/"))
    else
      _ -> false
    end
  end

  defp effect_belongs_to_remote?(_, _), do: false

  defp connection_ref(args) do
    case args["connection"] || args["agentos"] || map_field(args, :connection) ||
           map_field(args, :agentos) do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> nil
    end
  end

  defp fetch_connection(nil, _connections), do: {:ok, nil}

  defp fetch_connection(ref, connections) do
    case Enum.find(connections, fn connection -> map_field(connection, :ref) == ref end) do
      nil -> {:error, :unknown_connection}
      connection -> {:ok, connection}
    end
  end

  defp remote_locator(args, connection) do
    case args["url"] do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      _ ->
        spec = if is_map(connection), do: map_field(connection, :spec) || %{}, else: %{}

        case map_field(spec, :url) || map_field(spec, :baseUrl) do
          url when is_binary(url) and url != "" -> {:ok, url}
          _ -> {:error, :remote_url_required}
        end
    end
  end

  # Named connection: that connection's origins only. Bare URL: host allowlist,
  # even when a catalog is attached (JS allowOrigins gate).
  defp authorize_binding(origin, connection, _opts) when is_map(connection) do
    origins = map_field(connection, :origins) || []
    if allowed?(origin, origins), do: :ok, else: {:error, :origin_not_allowed}
  end

  defp authorize_binding(origin, _connection, opts) do
    if allowed?(origin, Keyword.get(opts, :allowed_origins, [])),
      do: :ok,
      else: {:error, :origin_not_allowed}
  end

  defp binding_auth(connection, _opts) when is_map(connection),
    do: map_field(connection, :auth) || %{kind: :none}

  defp binding_auth(_connection, opts), do: Keyword.get(opts, :auth) || %{kind: :none}

  defp binding_origins(connection, _opts) when is_map(connection),
    do: map_field(connection, :origins) || []

  defp binding_origins(_connection, opts), do: Keyword.get(opts, :allowed_origins, [])

  defp reject_query_auth(connection) when is_map(connection) do
    case map_field(connection, :auth) do
      %{kind: kind} when kind in [:query, "query"] -> {:error, :query_auth_unsupported}
      %{"kind" => kind} when kind in [:query, "query"] -> {:error, :query_auth_unsupported}
      _ -> :ok
    end
  end

  defp reject_query_auth(_), do: :ok

  defp map_field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp validate_header_name!(name) do
    if byte_size(name) <= 256 and Regex.match?(~r/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/, name),
      do: String.downcase(name),
      else: raise(ArgumentError, "invalid Git authentication header name")
  end

  defp validate_header_value!(value) do
    if byte_size(value) <= 16_384 and not String.contains?(value, ["\r", "\n"]),
      do: value,
      else: raise(ArgumentError, "invalid Git authentication header value")
  end
end
