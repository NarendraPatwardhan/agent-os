defmodule OtpHelloMixTest do
  use ExUnit.Case, async: true

  test "greeting contains the hello-world line" do
    assert OtpHelloMix.greeting() =~ "hello world"
  end

  test "greeting advertises the mix-backed path" do
    assert OtpHelloMix.greeting() =~ "MIX"
  end

  test "the BEAM arithmetic still works (sanity)" do
    assert 21 * 2 == 42
  end
end
