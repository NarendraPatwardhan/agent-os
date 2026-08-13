defmodule AgentOS.Git.Client do
  @moduledoc """
  Typed host client for the Git engine's public command surface.

  This module owns public request/response encoding only. Git protocol and repository
  semantics remain in the shared Zig/Gitz engine.
  """

  alias AgentOS.Git.{Json, Public}

  @type result :: %{stdout: String.t(), stderr: String.t(), exit_code: non_neg_integer()}

  @spec clone(pid(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def clone(engine, url, opts) when is_binary(url) do
    args =
      %{"url" => url}
      |> maybe_put("depth", opts[:depth])
      |> maybe_put("refspecs", opts[:refspecs])
      |> maybe_put("connection", opts[:connection])

    command(engine, "clone", args, opts)
  end

  @spec resolve(pid(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve(engine, revision, opts) when is_binary(revision) do
    with {:ok, result} <- command(engine, "rev-parse", %{"rev" => revision}, opts),
         oid when oid != "" <- String.trim(result.stdout) do
      {:ok, oid}
    else
      "" -> {:error, :missing_revision}
      {:error, _} = error -> error
    end
  end

  @spec checkout(pid(), String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def checkout(engine, revision, opts) when is_binary(revision) do
    args =
      %{"rev" => revision}
      |> maybe_put("flags", if(opts[:force], do: 1, else: nil))

    command(engine, "checkout", args, opts)
  end

  @spec status(pid(), keyword()) :: {:ok, result()} | {:error, term()}
  def status(engine, opts), do: command(engine, "status", %{}, opts)

  @spec command(pid(), String.t(), map(), keyword()) :: {:ok, result()} | {:error, term()}
  def command(engine, op, args, opts) when is_binary(op) and is_map(args) do
    body = Json.encode(%{"op" => op, "args" => args})

    with {:ok, response} <- Public.call(engine, body, opts),
         {:ok, decoded} <- Json.decode(response) do
      decode_result(decoded)
    end
  end

  defp decode_result(%{"ok" => true} = response) do
    {:ok,
     %{
       stdout: string(response["stdout"]),
       stderr: string(response["stderr"]),
       exit_code: integer(response["exitCode"])
     }}
  end

  defp decode_result(%{"ok" => false} = response) do
    error = if is_map(response["error"]), do: response["error"], else: %{}

    {:error,
     {:git,
      %{
        message: string(error["message"] || response["stderr"]),
        exit_code: integer(response["code"]),
        domain: error["domain"],
        code: error["code"],
        operation: error["operation"],
        retry: error["retry"]
      }}}
  end

  defp decode_result(_), do: {:error, :invalid_git_response}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp string(value) when is_binary(value), do: value
  defp string(_), do: ""
  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_), do: 0
end
