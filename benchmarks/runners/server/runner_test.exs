Code.require_file("result.exs", __DIR__)

defmodule AgentOSBenchmarkTest do
  use ExUnit.Case, async: false
  alias AgentOS.ControlPlane
  alias AgentOS.Benchmarks.{Json, Result}

  @moduletag timeout: 900_000

  test "OTP control-plane performance matrix" do
    profile = System.get_env("AGENTOS_BENCHMARK_PROFILE", "smoke")
    samples = positive_env("AGENTOS_BENCHMARK_SAMPLES", profile_samples(profile))
    kernel = runfile!("memcontainers/kernel/rust/kernel.wasm")
    posix = runfile!("memcontainers/images/posix.tar")
    atlas = runfile!("memcontainers/images/atlas.tar")
    initial_result = %Result{}

    result = first_exec_population(initial_result, kernel, posix, samples)
    vm_id = id("work")

    assert {:ok, _pid} =
             ControlPlane.create(vm_id,
               wasm: kernel,
               base_image: posix,
               deterministic: true,
               workers: 0
             )

    if perf_enabled?() do
      assert :ok = ControlPlane.set_perf_enabled(vm_id, true)
    end

    try do
      result =
        measure_exec(result, vm_id, "exec.shell_builtin.steady", "true", samples, %{
          image: "posix",
          host: "beam-nif",
          temperature: "steady-state"
        })

      result =
        measure_exec(
          result,
          vm_id,
          "exec.pipeline.three_stage",
          "printf 'c\\na\\nb\\n' | sort | wc -l",
          samples,
          %{image: "posix", host: "beam-nif", stages: 3}
        )

      result =
        measure_run(
          result,
          vm_id,
          "exec.direct_minimal.steady",
          "true",
          [],
          samples,
          %{image: "posix", host: "beam-nif", temperature: "steady-state"}
        )

      result =
        measure_run(
          result,
          vm_id,
          "exec.direct_external.steady",
          "echo",
          ["agentos"],
          samples,
          %{image: "posix", host: "beam-nif", temperature: "steady-state"}
        )

      {result, snapshot} =
        Enum.reduce(0..(samples - 1), {result, nil}, fn iteration, {result, baseline} ->
          case :timer.tc(fn -> ControlPlane.snapshot(vm_id) end) do
            {snapshot_us, {:ok, value}} ->
              result =
                result
                |> Result.sample("snapshot.full.latency", "ms", snapshot_us / 1000, %{
                  image: "posix",
                  host: "beam-nif"
                })
                |> Result.sample("snapshot.full.size", "bytes", byte_size(value), %{
                  image: "posix",
                  host: "beam-nif"
                })

              {result, baseline || value}

            {_snapshot_us, error} ->
              {Result.failure(
                 result,
                 "snapshot.full.latency",
                 "ms",
                 iteration,
                 RuntimeError.exception(inspect(error)),
                 %{image: "posix", host: "beam-nif"}
               ), baseline}
          end
        end)

      assert is_binary(snapshot)

      {result, restore_ids} =
        Enum.reduce(0..(samples - 1), {result, []}, fn iteration, {result, ids} ->
          child = id("restore")
          started = System.monotonic_time()

          case ControlPlane.create(child,
                 wasm: kernel,
                 snapshot: snapshot,
                 deterministic: true,
                 workers: 0
               ) do
            {:ok, _pid} ->
              {Result.sample(
                 result,
                 "snapshot.restore_full",
                 "ms",
                 elapsed_ms(started),
                 %{image: "posix", host: "beam-nif"}
               ), [child | ids]}

            {:error, error} ->
              {Result.failure(
                 result,
                 "snapshot.restore_full",
                 "ms",
                 iteration,
                 RuntimeError.exception(inspect(error)),
                 %{image: "posix", host: "beam-nif"}
               ), ids}
          end
        end)

      Enum.each(restore_ids, &ControlPlane.dispose/1)

      result = resident_sqlite(result, kernel, atlas, samples)

      bad_id = id("malformed")
      malformed = ControlPlane.create(bad_id, wasm: <<0, 1, 2, 3>>)

      result =
        Result.check(
          result,
          "robustness.malformed_kernel.rejected",
          match?({:error, _}, malformed),
          inspect(malformed)
        )

      document = %{
        schema: "agentos.benchmark.v1",
        run: %{
          id: "#{System.system_time(:millisecond)}-beam",
          timestamp: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
          runner: "benchmarks/runners/server/runner_test.exs",
          runtime: "OTP #{System.otp_release()} / Elixir #{System.version()} / release host NIF",
          profile: profile,
          sampleCount: samples,
          system: %{
            architecture: :erlang.system_info(:system_architecture) |> to_string(),
            logicalCpus: :erlang.system_info(:logical_processors_available),
            schedulers: :erlang.system_info(:schedulers_online),
            beamMemory: Map.new(:erlang.memory())
          },
          artifacts: [
            artifact("kernel.wasm", kernel),
            artifact("posix", posix),
            artifact("atlas", atlas)
          ],
          semantics: %{
            coldStart: "first command on a fresh machine",
            wasmtimeCompilationMode: "opt",
            perfTracing: perf_enabled?()
          }
        },
        measurements: result.measurements,
        checks: result.checks,
        skips: result.skips
      }

      json = Json.encode(document) <> "\n"
      IO.puts(json)
      output_dir = System.get_env("TEST_UNDECLARED_OUTPUTS_DIR")
      if output_dir, do: File.write!(Path.join(output_dir, "server.json"), json)
    after
      ControlPlane.dispose(vm_id)
    end
  end

  defp measure_exec(result, id, name, command, samples, dimensions) do
    Enum.reduce(0..(samples - 1), result, fn iteration, result ->
      # Direct Vm.exec uses the host drive_exec path (PERF-013 stages). Interleaved
      # ControlPlane.exec is for egress-yielding production traffic, not stage attribution.
      started = System.monotonic_time()

      case with_vm_exec(id, fn pid -> AgentOS.Vm.exec(pid, command) end) do
        {:ok, %{exit_code: 0}} ->
          result
          |> Result.sample(name, "ms", elapsed_ms(started), dimensions)
          |> maybe_sample_command_perf(id, name, dimensions)

        other ->
          Result.failure(
            result,
            name,
            "ms",
            iteration,
            RuntimeError.exception(inspect(other)),
            dimensions
          )
      end
    end)
  end

  defp measure_run(result, id, name, program, args, samples, dimensions) do
    Enum.reduce(0..(samples - 1), result, fn iteration, result ->
      started = System.monotonic_time()

      case with_vm_exec(id, fn pid -> AgentOS.Vm.run(pid, program, args) end) do
        {:ok, %{exit_code: 0}} ->
          result
          |> Result.sample(name, "ms", elapsed_ms(started), dimensions)
          |> maybe_sample_command_perf(id, name, dimensions)

        other ->
          Result.failure(
            result,
            name,
            "ms",
            iteration,
            RuntimeError.exception(inspect(other)),
            dimensions
          )
      end
    end)
  end

  # Prefer direct Vm.exec/run so PERF-013 stages come from host drive_exec (not the
  # interleaved ControlPlane path used for production egress yielding).
  defp with_vm_exec(id, fun) do
    case ControlPlane.whereis(id) do
      pid when is_pid(pid) -> fun.(pid)
      nil -> {:error, :not_found}
    end
  end

  defp maybe_sample_command_perf(result, id, parent, dimensions) do
    if perf_enabled?() do
      case ControlPlane.take_command_perf(id) do
        {:ok, %{pace_ms: pace, tick_ms: tick, host_ticks: ticks} = perf} ->
          dims = Map.put(dimensions, :parent, parent)

          result
          |> Result.sample("perf.pace_ms", "ms", pace, dims)
          |> Result.sample("perf.tick_ms", "ms", tick, dims)
          |> Result.sample("perf.host_ticks", "count", ticks, dims)
          |> Result.sample(
            "perf.module_cache_misses",
            "count",
            Map.get(perf, :module_cache_misses, 0),
            dims
          )
          |> Result.sample("perf.tasks_spawned", "count", Map.get(perf, :tasks_spawned, 0), dims)
          |> Result.sample("perf.pipes_created", "count", Map.get(perf, :pipes_created, 0), dims)

        _ ->
          result
      end
    else
      result
    end
  end

  defp perf_enabled? do
    case System.get_env("MC_PERF") do
      nil -> false
      v -> String.downcase(String.trim(v)) in ["1", "true", "yes"]
    end
  end

  defp first_exec_population(result, kernel, posix, samples) do
    Enum.reduce(0..(samples - 1), result, fn iteration, result ->
      id = id("first-exec")

      case ControlPlane.create(id,
             wasm: kernel,
             base_image: posix,
             deterministic: true,
             workers: 0
           ) do
        {:ok, _pid} ->
          try do
            measure_exec(result, id, "cold_start.shell", "true", 1, %{
              image: "posix",
              host: "beam-nif",
              temperature: "cold"
            })
          after
            ControlPlane.dispose(id)
          end

        {:error, error} ->
          Result.failure(
            result,
            "cold_start.shell",
            "ms",
            iteration,
            RuntimeError.exception(inspect(error)),
            %{image: "posix", host: "beam-nif", temperature: "cold"}
          )
      end
    end)
  end

  defp resident_sqlite(result, kernel, atlas, samples) do
    command =
      "sqlite /tmp/bench.db \"CREATE TABLE IF NOT EXISTS t(n INTEGER); INSERT INTO t VALUES (1); SELECT count(*) FROM t\""

    result =
      Enum.reduce(0..(samples - 1), result, fn iteration, result ->
        id = id("sqlite-first")

        case ControlPlane.create(id,
               wasm: kernel,
               base_image: atlas,
               deterministic: true,
               workers: 0
             ) do
          {:ok, _pid} ->
            try do
              measure_exec(result, id, "resident.sqlite.first", command, 1, %{
                image: "atlas",
                host: "beam-nif",
                temperature: "cold"
              })
            after
              ControlPlane.dispose(id)
            end

          {:error, error} ->
            Result.failure(
              result,
              "resident.sqlite.first",
              "ms",
              iteration,
              RuntimeError.exception(inspect(error)),
              %{image: "atlas", host: "beam-nif", temperature: "cold"}
            )
        end
      end)

    id = id("sqlite-warm")

    case ControlPlane.create(id,
           wasm: kernel,
           base_image: atlas,
           deterministic: true,
           workers: 0
         ) do
      {:ok, _pid} ->
        try do
          {:ok, %{exit_code: 0}} = ControlPlane.exec(id, command)

          measure_exec(result, id, "resident.sqlite.warm", command, samples, %{
            image: "atlas",
            host: "beam-nif",
            temperature: "warm"
          })
        after
          ControlPlane.dispose(id)
        end

      {:error, error} ->
        Result.failure(
          result,
          "resident.sqlite.warm",
          "ms",
          0,
          RuntimeError.exception(inspect(error)),
          %{image: "atlas", host: "beam-nif"}
        )
    end
  end

  defp artifact(name, bytes) do
    %{
      name: name,
      bytes: byte_size(bytes),
      sha256: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    }
  end

  defp elapsed_ms(started) do
    System.monotonic_time()
    |> Kernel.-(started)
    |> System.convert_time_unit(:native, :microsecond)
    |> Kernel./(1000)
  end

  defp profile_samples("smoke"), do: 3
  defp profile_samples("standard"), do: 30
  defp profile_samples("stress"), do: 100
  defp profile_samples(other), do: raise("unknown benchmark profile #{inspect(other)}")

  defp positive_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> raise "#{name} must be a positive integer"
        end
    end
  end

  defp id(prefix),
    do: {"benchmark", "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"}

  defp runfile!(path) do
    roots = [
      Path.join([System.fetch_env!("TEST_SRCDIR"), System.fetch_env!("TEST_WORKSPACE")]),
      Path.join(System.fetch_env!("TEST_SRCDIR"), "_main")
    ]

    file =
      Enum.find_value(roots, fn root ->
        candidate = Path.join(root, path)
        if File.exists?(candidate), do: candidate
      end) || raise("runfile not found: #{path}")

    File.read!(file)
  end
end
