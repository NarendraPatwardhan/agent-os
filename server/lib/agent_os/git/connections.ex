defmodule AgentOS.Git.Connections do
  @moduledoc """
  Connection-bound git remotes (SYSTEMS.md §11b / docs/connections.md).

  Host-owned catalog: guest may pass public `url` and/or `connection` /
  `agentos` ref only. Credential splice is host-only (SmartHttp headers).
  Empty connection `origins` fails closed — no credential to attacker URLs.

  Mirrors TS `sdk-js/core/src/git/connections.ts`.
  """

  alias AgentOS.Git.SmartHttp

  # Guest secret keys — prefer contracts/git.kdl via AgentOS.Contracts.Git.
  # Module attribute used at compile time; runtime MapSet from contract when available.
  @guest_secret_arg_keys AgentOS.Contracts.Git.guest_secret_arg_keys()

  @type auth :: map()
  @type connection :: map()
  @type policy_action :: :approve | :require_approval | :block
  @type policy_rule :: map()

  @type binding :: %{
          url: String.t(),
          connection_ref: String.t() | nil,
          origins: [String.t()],
          auth: auth(),
          push_action: policy_action()
        }

  @doc """
  Resolve guest/SDK remote `args` against host catalog opts.

  Options:
  * `:connections` — host connection list (`ref` / `auth` / `origins` / `spec?`)
  * `:policies` / `:connection_policies` — push policy rules
  * `:allowed_origins` — global bare-URL allowlist (also optional intersection
    when a connection is bound and the list is non-empty)
  * `:auth` — host fallback auth for **bare** URLs only (never from guest body)
  * `:remote_urls` / `:remote_connections` — named remote maps (optional)

  Guest `auth` / `token` fields are **rejected** (fail closed), never spliced.

  Returns:

  * `{:ok, binding}` with `url`, `connection_ref`, `origins`, `auth`, `push_action`
  * `{:error, reason}` atoms/tuples understood by `Orchestrator` error map
  """
  @spec resolve_remote(map() | nil, keyword()) ::
          {:ok, binding()} | {:error, term()}
  def resolve_remote(args, opts \\ [])

  def resolve_remote(args, opts) when is_list(opts) do
    a = stringify_keys(args || %{})

    if guest_args_carry_secrets?(a) do
      {:error, :guest_secrets_forbidden}
    else
      do_resolve_remote(a, opts)
    end
  end

  defp do_resolve_remote(a, opts) do
    connections = normalize_connections(Keyword.get(opts, :connections, []))

    policies =
      normalize_policies(
        Keyword.get(opts, :policies, Keyword.get(opts, :connection_policies, []))
      )

    remote_urls = Keyword.get(opts, :remote_urls, %{}) || %{}
    remote_connections = Keyword.get(opts, :remote_connections, %{}) || %{}

    url = string_or_empty(Map.get(a, "url"))
    connection_ref = connection_ref_of(a)
    remote_name = string_or_empty(Map.get(a, "remote"))

    {url, connection_ref} =
      if url == "" and remote_name != "" do
        resolved_url =
          Map.get(remote_urls, remote_name) ||
            Map.get(remote_urls, safe_atom(remote_name)) ||
            ""

        resolved_url = if is_binary(resolved_url), do: resolved_url, else: ""

        cref =
          connection_ref ||
            Map.get(remote_connections, remote_name) ||
            Map.get(remote_connections, safe_atom(remote_name))

        cref = if is_binary(cref) and cref != "", do: cref, else: nil
        {resolved_url, cref}
      else
        {url, connection_ref}
      end

    conn =
      if is_binary(connection_ref) do
        Enum.find(connections, fn c -> c.ref == connection_ref end)
      else
        nil
      end

    cond do
      is_binary(connection_ref) and is_nil(conn) ->
        {:error, {:unknown_connection, connection_ref}}

      true ->
        url =
          if url == "" and is_map(conn) do
            url_from_spec(conn) || ""
          else
            url
          end

        cond do
          url == "" ->
            {:error, :bad_url}

          SmartHttp.request_origin(url) == :error ->
            {:error, :bad_remote_url}

          true ->
            case public_remote_url(url) do
              nil ->
                {:error, :bad_remote_url}

              public_url ->
                bind_after_url(public_url, connection_ref, conn, policies, opts)
            end
        end
    end
  end

  @doc false
  def guest_args_carry_secrets?(args) when is_map(args) do
    Enum.any?(Map.keys(args), fn
      k when is_binary(k) ->
        String.downcase(k) in @guest_secret_arg_keys

      k when is_atom(k) ->
        String.downcase(Atom.to_string(k)) in @guest_secret_arg_keys

      _ ->
        false
    end)
  end

  def guest_args_carry_secrets?(_), do: false

  defp bind_after_url(public_url, connection_ref, conn, policies, opts)
       when is_binary(connection_ref) and is_map(conn) do
    allowed = conn.origins || []

    cond do
      allowed == [] or not SmartHttp.origin_allowed?(allowed, public_url) ->
        {:error, {:origin_not_allowlisted_for_connection, conn.ref}}

      true ->
        # Optional global allowlist further intersects when set (non-empty).
        case Keyword.get(opts, :allowed_origins) do
          list when is_list(list) and list != [] ->
            if SmartHttp.origin_allowed?(list, public_url) do
              ok_binding(public_url, connection_ref, allowed, conn.auth, policies)
            else
              {:error, :origin_not_allowed}
            end

          :any ->
            ok_binding(public_url, connection_ref, allowed, conn.auth, policies)

          _ ->
            ok_binding(public_url, connection_ref, allowed, conn.auth, policies)
        end
    end
  end

  defp bind_after_url(public_url, _connection_ref, _conn, policies, opts) do
    # Bare URL: R32 — require non-empty global allowed_origins match.
    # Host `:auth` only; guest auth/token already ignored (never read).
    case SmartHttp.ensure_url_allowed(public_url, opts) do
      {:ok, _origin} ->
        host_auth = normalize_auth(Keyword.get(opts, :auth))
        allowed = bare_origins(opts, public_url)

        ok_binding(public_url, nil, allowed, host_auth, policies)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bare_origins(opts, public_url) do
    case Keyword.get(opts, :allowed_origins) do
      list when is_list(list) and list != [] ->
        list

      :any ->
        case SmartHttp.request_origin(public_url) do
          {:ok, o} -> [o]
          _ -> []
        end

      _ ->
        case SmartHttp.request_origin(public_url) do
          {:ok, o} -> [o]
          _ -> []
        end
    end
  end

  defp ok_binding(url, connection_ref, origins, auth, policies) do
    ref_for_policy = connection_ref || "*"
    na = normalize_auth(auth)

    # Dual-host (contracts/git.kdl): query auth not supported for remotes.
    case na do
      %{kind: :query} ->
        {:error, :query_auth_unsupported}

      _ ->
        {:ok,
         %{
           url: url,
           connection_ref: connection_ref,
           origins: origins || [],
           auth: na,
           push_action: evaluate_push_policy(ref_for_policy, policies)
         }}
    end
  end

  defp connection_ref_of(a) do
    case Map.get(a, "connection") || Map.get(a, "agentos") do
      ref when is_binary(ref) and ref != "" -> ref
      _ -> nil
    end
  end

  defp url_from_spec(%{spec: %{url: u}}) when is_binary(u) and u != "", do: u
  defp url_from_spec(%{spec: %{"url" => u}}) when is_binary(u) and u != "", do: u
  defp url_from_spec(%{spec: %{baseUrl: u}}) when is_binary(u) and u != "", do: u
  defp url_from_spec(%{spec: %{"baseUrl" => u}}) when is_binary(u) and u != "", do: u
  defp url_from_spec(%{spec: %{base_url: u}}) when is_binary(u) and u != "", do: u
  defp url_from_spec(%{spec: nil}), do: nil
  defp url_from_spec(%{spec: _}), do: nil
  defp url_from_spec(_), do: nil

  @doc """
  Public git locator: http(s) only, no userinfo. Keeps path for repo URLs.
  """
  @spec public_remote_url(String.t()) :: String.t() | nil
  def public_remote_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, userinfo: userinfo} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        if userinfo not in [nil, ""] do
          nil
        else
          %URI{uri | userinfo: nil, fragment: nil}
          |> URI.to_string()
          |> String.trim_trailing("/")
        end

      _ ->
        nil
    end
  end

  def public_remote_url(_), do: nil

  @doc "Most-restrictive push policy for a connection ref."
  @spec evaluate_push_policy(String.t(), [policy_rule()]) :: policy_action()
  def evaluate_push_policy(connection_ref, policies)
      when is_binary(connection_ref) and is_list(policies) do
    policies
    |> Enum.reduce(:approve, fn rule, worst ->
      pattern = Map.get(rule, :pattern) || Map.get(rule, "pattern") || ""

      if match_connection_pattern?(pattern, connection_ref) do
        action = Map.get(rule, :action) || Map.get(rule, "action") || :approve
        action = normalize_action(action) || :approve
        more_restrictive(worst, action)
      else
        worst
      end
    end)
  end

  def evaluate_push_policy(_, _), do: :approve

  @doc "Glob-ish connection pattern: exact, `*`, or `prefix.*`."
  @spec match_connection_pattern?(String.t(), String.t()) :: boolean()
  def match_connection_pattern?("*", _ref), do: true
  def match_connection_pattern?(pattern, ref) when pattern == ref, do: true

  def match_connection_pattern?(pattern, ref)
      when is_binary(pattern) and is_binary(ref) do
    if String.ends_with?(pattern, ".*") do
      prefix = String.slice(pattern, 0, byte_size(pattern) - 2)
      ref == prefix or String.starts_with?(ref, prefix <> ".")
    else
      false
    end
  end

  def match_connection_pattern?(_, _), do: false

  # ── Normalization ──────────────────────────────────────────────────────────

  @doc false
  def normalize_connections(list) when is_list(list) do
    list
    |> Enum.map(&normalize_connection/1)
    |> Enum.reject(&is_nil/1)
  end

  def normalize_connections(_), do: []

  defp normalize_connection(%{ref: ref} = c) when is_binary(ref) and ref != "" do
    %{
      ref: ref,
      auth: normalize_auth(Map.get(c, :auth) || Map.get(c, "auth")),
      origins: normalize_origins(Map.get(c, :origins) || Map.get(c, "origins")),
      spec: Map.get(c, :spec) || Map.get(c, "spec")
    }
    |> drop_nil_spec()
  end

  defp normalize_connection(%{"ref" => ref} = c) when is_binary(ref) and ref != "" do
    normalize_connection(%{
      ref: ref,
      auth: Map.get(c, "auth") || Map.get(c, :auth),
      origins: Map.get(c, "origins") || Map.get(c, :origins),
      spec: Map.get(c, "spec") || Map.get(c, :spec)
    })
  end

  defp normalize_connection({ref, auth}) when is_binary(ref) do
    normalize_connection(%{ref: ref, auth: auth, origins: []})
  end

  defp normalize_connection({ref, auth, origins}) when is_binary(ref) do
    normalize_connection(%{ref: ref, auth: auth, origins: origins})
  end

  defp normalize_connection(_), do: nil

  defp drop_nil_spec(%{spec: nil} = c), do: Map.delete(c, :spec)
  defp drop_nil_spec(c), do: c

  defp normalize_policies(list) when is_list(list) do
    list
    |> Enum.map(&normalize_policy/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_policies(_), do: []

  defp normalize_policy(%{pattern: p, action: a} = r) when is_binary(p) do
    case normalize_action(a) do
      nil ->
        nil

      action ->
        base = %{pattern: p, action: action}

        case Map.get(r, :owner) || Map.get(r, "owner") do
          nil -> base
          owner -> Map.put(base, :owner, owner)
        end
    end
  end

  defp normalize_policy(%{"pattern" => p, "action" => a} = r) when is_binary(p) do
    normalize_policy(%{pattern: p, action: a, owner: Map.get(r, "owner")})
  end

  defp normalize_policy({owner, pattern, action}) when is_binary(pattern) do
    normalize_policy(%{owner: owner, pattern: pattern, action: action})
  end

  defp normalize_policy(_), do: nil

  defp normalize_action(a) when a in [:approve, :require_approval, :block], do: a
  defp normalize_action("approve"), do: :approve
  defp normalize_action("require_approval"), do: :require_approval
  defp normalize_action("block"), do: :block
  defp normalize_action(_), do: nil

  defp normalize_origins(nil), do: []
  defp normalize_origins(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp normalize_origins(_), do: []

  defp normalize_auth(nil), do: %{kind: :none}
  defp normalize_auth({:none}), do: %{kind: :none}
  defp normalize_auth(:none), do: %{kind: :none}
  defp normalize_auth({:bearer, token}) when is_binary(token), do: %{kind: :bearer, token: token}

  defp normalize_auth({:header, name, value}) when is_binary(name) and is_binary(value),
    do: %{kind: :header, name: name, value: value}

  defp normalize_auth({:basic, user, pass}) when is_binary(user) and is_binary(pass),
    do: %{kind: :basic, username: user, password: pass}

  defp normalize_auth(auth) when is_map(auth) do
    kind = Map.get(auth, :kind) || Map.get(auth, "kind") || :none

    case parse_kind(kind) do
      :none ->
        %{kind: :none}

      :bearer ->
        token = Map.get(auth, :token) || Map.get(auth, "token") || ""

        if is_binary(token) and token != "",
          do: %{kind: :bearer, token: token},
          else: %{kind: :none}

      :header ->
        name = Map.get(auth, :name) || Map.get(auth, "name")
        value = Map.get(auth, :value) || Map.get(auth, "value")

        if is_binary(name) and is_binary(value),
          do: %{kind: :header, name: name, value: value},
          else: %{kind: :none}

      :basic ->
        u = Map.get(auth, :username) || Map.get(auth, "username") || Map.get(auth, "user")
        p = Map.get(auth, :password) || Map.get(auth, "password") || Map.get(auth, "pass")

        if is_binary(u) and is_binary(p),
          do: %{kind: :basic, username: u, password: p},
          else: %{kind: :none}

      :query ->
        # Prefer header splice path; SmartHttp may ignore query kind.
        name = Map.get(auth, :name) || Map.get(auth, "name")
        value = Map.get(auth, :value) || Map.get(auth, "value")

        if is_binary(name) and is_binary(value),
          do: %{kind: :query, name: name, value: value},
          else: %{kind: :none}
    end
  end

  defp normalize_auth(auth) when is_list(auth), do: normalize_auth(Map.new(auth))
  defp normalize_auth(_), do: %{kind: :none}

  defp parse_kind(k) when k in [:none, :bearer, :header, :basic, :query], do: k
  defp parse_kind("none"), do: :none
  defp parse_kind("bearer"), do: :bearer
  defp parse_kind("header"), do: :header
  defp parse_kind("basic"), do: :basic
  defp parse_kind("query"), do: :query
  defp parse_kind(_), do: :none

  defp more_restrictive(a, b) do
    rank = %{approve: 0, require_approval: 1, block: 2}
    if Map.get(rank, b, 0) > Map.get(rank, a, 0), do: b, else: a
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) -> {k, v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp stringify_keys(_), do: %{}

  defp string_or_empty(s) when is_binary(s), do: s
  defp string_or_empty(_), do: ""

  # Only existing atoms — never String.to_atom on untrusted remote names.
  defp safe_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
