defmodule AgentOS.MixProject do
  use Mix.Project

  # The agent-os control plane — the kubernetes-style supervisor over the wasm VMs
  # (CONTROL_PLANE.md). Dependency-free on purpose: the NIF that drives VMs
  # (//memcontainers/hosts/wasmtime/nif:host_nif) is built by Bazel and staged into priv/, and
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
      mod: {AgentOS.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps, do: []
end
