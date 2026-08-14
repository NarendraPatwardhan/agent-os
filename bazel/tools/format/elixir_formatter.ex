defmodule AgentOS.Formatter do
  @moduledoc false

  def main(args) do
    case Enum.map(args, &to_string/1) do
      [mode | files] when mode in ["check", "write"] -> run(mode, files)
      _args -> usage()
    end
  end

  defp run(mode, files) do
    changed = Enum.filter(files, &format(&1, mode))

    if mode == "check" and changed != [] do
      IO.puts(:stderr, "Elixir files require formatting:")
      Enum.each(changed, &IO.puts(:stderr, "  #{&1}"))
      System.halt(1)
    end
  end

  defp usage do
    IO.puts(:stderr, "usage: elixir-fmt <check|write> <file>...")
    System.halt(2)
  end

  defp format(file, mode) do
    source = File.read!(file)

    formatted =
      source
      |> Code.format_string!(file: file)
      |> IO.iodata_to_binary()
      |> Kernel.<>("\n")

    if source == formatted do
      false
    else
      if mode == "write", do: File.write!(file, formatted)
      true
    end
  end
end
