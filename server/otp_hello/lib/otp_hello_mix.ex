defmodule OtpHelloMix do
  @moduledoc """
  The MIX-backed hello-world — the same payload as `//:` OtpHello, but compiled and tested
  through real Mix (`mix compile` / `mix test` / `mix release`) on the hermetic toolchain.
  """

  @greeting "hello world from a MIX-backed app — hermetic Elixir + OTP via discord/rules_elixir"

  @doc "The greeting line. Pure, so the ExUnit test can assert on it."
  def greeting, do: @greeting

  @doc "Convenience entry point."
  def main(_args \\ []), do: IO.puts(greeting())
end
