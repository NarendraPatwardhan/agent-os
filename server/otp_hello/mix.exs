defmodule OtpHelloMix.MixProject do
  use Mix.Project

  # A minimal, dependency-free Mix project. mix_library compiles it with `mix compile`
  # (HEX_OFFLINE=true, Bazel-managed build root) on the hermetic Elixir 1.16.1 / OTP 26.2.5
  # toolchain — the "set-and-forget" discord path, vs the mixless elixirc path in //:.
  def project do
    [
      app: :otp_hello_mix,
      version: "0.1.0",
      elixir: "~> 1.16",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps, do: []
end
