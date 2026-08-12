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

  @doc "Resolve host-owned origin and credentials for one effect URL."
  @spec resolve_policy(String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def resolve_policy(url, opts) when is_binary(url) do
    connections = Keyword.get(opts, :connections, [])

    if is_list(connections) and connections != [] do
      resolve_connection_policy(url, connections)
    else
      with {:ok, origin} <- ensure_url_allowed(url, opts) do
        {:ok, %{origin: origin, auth: Keyword.get(opts, :auth)}}
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

  defp resolve_connection_policy(url, connections) do
    case origin(url) do
      {:ok, requested_origin} ->
        case Enum.filter(connections, &connection_allows?(&1, requested_origin)) do
          [connection] ->
            {:ok, %{origin: requested_origin, auth: map_field(connection, :auth)}}

          [] ->
            {:error, :origin_not_allowed}

          _ ->
            {:error, :ambiguous_connection_origin}
        end

      :error ->
        {:error, :bad_remote_url}
    end
  end

  defp connection_allows?(connection, requested_origin) when is_map(connection) do
    case map_field(connection, :origins) do
      origins when is_list(origins) -> allowed?(requested_origin, origins)
      _ -> false
    end
  end

  defp connection_allows?(_, _), do: false

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
