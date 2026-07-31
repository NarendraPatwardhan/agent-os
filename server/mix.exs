defmodule AgentOS.MixProject do
  use Mix.Project

  # The AgentOS control plane — the kubernetes-style supervisor over the wasm VMs
  # (SYSTEMS.md §13.1). Dependency-free on purpose: the NIF that drives VMs
  # (//memcontainers/hosts/wasmtime/nif:host_nif_release) is built by Bazel and staged into priv/, and
  # loaded manually (no `use Rustler`), so there is no rustler hex dependency to resolve.
  def project do
    [
      app: :agent_os,
      version: "0.1.0",
      elixir: "~> 1.16",
      deps: deps()
    ]
  end

  def application do
    [
      # :inets + :ssl — BEAM HTTPS for git remotes (K16; same host egress family as kernel HTTP).
      extra_applications: [:crypto, :logger, :inets, :ssl, :public_key]
    ]
  end

  defp deps, do: []
end
