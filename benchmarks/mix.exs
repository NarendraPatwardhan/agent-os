defmodule AgentOSBenchmark.MixProject do
  use Mix.Project

  # This project is only the hermetic benchmark entrypoint. Bazel supplies the already-compiled
  # AgentOS application and release NIF through //server:lib_test.
  def project do
    [app: :agent_os, version: "0.1.0", elixir: "~> 1.16", deps: []]
  end

  def application, do: [extra_applications: [:crypto, :logger]]
end
