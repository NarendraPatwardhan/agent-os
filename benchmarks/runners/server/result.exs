defmodule AgentOS.Benchmarks.Result do
  defstruct measurements: [], checks: [], skips: []

  def sample(result, name, unit, value, dimensions \\ %{}) do
    index =
      Enum.find_index(result.measurements, fn measurement ->
        measurement.name == name and measurement.unit == unit and
          measurement.dimensions == dimensions
      end)

    if index do
      update_in(result.measurements, fn values ->
        List.update_at(values, index, fn measurement ->
          samples = measurement.samples ++ [value]
          %{measurement | samples: samples, stats: stats(samples)}
        end)
      end)
    else
      measurement = %{
        name: name,
        unit: unit,
        dimensions: dimensions,
        samples: [value],
        failures: [],
        stats: stats([value])
      }

      %{result | measurements: result.measurements ++ [measurement]}
    end
  end

  def failure(result, name, unit, iteration, error, dimensions \\ %{}) do
    failure = %{iteration: iteration, error: Exception.message(error)}

    index =
      Enum.find_index(result.measurements, fn measurement ->
        measurement.name == name and measurement.unit == unit and
          measurement.dimensions == dimensions
      end)

    if index do
      update_in(result.measurements, fn values ->
        List.update_at(values, index, fn measurement ->
          %{measurement | failures: measurement.failures ++ [failure]}
        end)
      end)
    else
      measurement = %{
        name: name,
        unit: unit,
        dimensions: dimensions,
        samples: [],
        failures: [failure],
        stats: nil
      }

      %{result | measurements: result.measurements ++ [measurement]}
    end
  end

  def check(result, name, ok, detail \\ nil) do
    value = if detail, do: %{name: name, ok: ok, detail: detail}, else: %{name: name, ok: ok}
    %{result | checks: result.checks ++ [value]}
  end

  def skip(result, name, reason) do
    %{result | skips: result.skips ++ [%{name: name, reason: reason}]}
  end

  defp stats(samples) do
    sorted = Enum.sort(samples)

    %{
      count: length(sorted),
      p50: percentile(sorted, 0.50),
      p95: percentile(sorted, 0.95)
    }
  end

  defp percentile(sorted, quantile) do
    rank = max(1, ceil(quantile * length(sorted)))
    Enum.at(sorted, rank - 1)
  end
end

defmodule AgentOS.Benchmarks.Json do
  def encode(value) when is_map(value) do
    value
    |> then(fn map -> if Map.has_key?(map, :__struct__), do: Map.from_struct(map), else: map end)
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map_join(",", fn {key, item} -> encode(to_string(key)) <> ":" <> encode(item) end)
    |> then(&("{" <> &1 <> "}"))
  end

  def encode(value) when is_list(value), do: "[" <> Enum.map_join(value, ",", &encode/1) <> "]"
  def encode(value) when is_binary(value), do: "\"" <> escape(value) <> "\""
  def encode(nil), do: "null"
  def encode(value) when value in [true, false], do: to_string(value)
  def encode(value) when is_atom(value), do: encode(to_string(value))
  def encode(value) when is_integer(value), do: Integer.to_string(value)
  def encode(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact])

  defp escape(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end
