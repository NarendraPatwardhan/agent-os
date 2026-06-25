defmodule AgentOS.Host.Nif do
  @moduledoc """
  Raw NIF binding to `libhost_nif.so` — the Rustler wrapper over the wasmtime
  `host::KernelHost` (CONTROL_PLANE.md §6.1). This is the ONLY module that touches the NIF;
  all process discipline (single-owner, crash-only, the tick loop) lives in `AgentOS.Vm`.
  Do not call these directly.

  ## Why manual loading (no `use Rustler`)

  Bazel builds the `.so` (`//memcontainers/hosts/wasmtime/nif:host_nif`) and stages it into
  this app's `priv/`. We therefore want Elixir to *load* a prebuilt artifact, never *compile*
  one — so we skip the `rustler` hex package entirely and load the NIF by hand via `@on_load`
  + `:erlang.load_nif/2`. The Rust `rustler::init!` still emits the standard `nif_init`
  entrypoint, so the manual load works unchanged and the app carries no extra dependency.

  ## Contract

  Every fallible call returns `{:ok, value} | {:error, reason}` — host failures are *values*,
  not raises (the owning `AgentOS.Vm` decides policy). Each runs on a DirtyCpu scheduler.
  `take_output/1` is infallible.
  """

  @on_load :load_nif

  @doc false
  def load_nif do
    priv = :code.priv_dir(:agent_os)

    # The exact sub-path under priv/ is decided by the mix_library `priv` staging, so locate
    # the cdylib by wildcard and hand `load_nif` the path with the OS extension stripped.
    base =
      case :filelib.wildcard(:filename.join([priv, ~c"**", ~c"libhost_nif.*"])) do
        [path | _] -> :filename.rootname(path)
        [] -> :filename.join(priv, ~c"libhost_nif")
      end

    :erlang.load_nif(base, 0)
  end

  @typedoc "Opaque handle to a live VM (a `ResourceArc<Vm>` on the Rust side)."
  @opaque vm :: reference()

  @typedoc "A host error message."
  @type reason :: binary()

  @doc "Boot a VM from a `kernel.wasm` + optional base image; ticks to the first prompt."
  @spec boot(binary(), binary() | nil) :: {:ok, vm()} | {:error, reason()}
  def boot(_wasm, _base_image), do: nif_not_loaded()

  @doc "Restore (or fork) a VM from a snapshot blob — the booted state IS the image (A8)."
  @spec restore(binary(), binary()) :: {:ok, vm()} | {:error, reason()}
  def restore(_wasm, _snapshot), do: nif_not_loaded()

  @doc "Drive one bounded `mc_tick`: `{:ok, true}` while running, `{:ok, false}` once exited."
  @spec tick(vm()) :: {:ok, boolean()} | {:error, reason()}
  def tick(_vm), do: nif_not_loaded()

  @doc "Feed bytes to the kernel as terminal input."
  @spec send_input(vm(), binary()) :: :ok | {:error, reason()}
  def send_input(_vm, _bytes), do: nif_not_loaded()

  @doc "Drain (and clear) the terminal output captured since the last call."
  @spec take_output(vm()) :: binary()
  def take_output(_vm), do: nif_not_loaded()

  @doc "Run a command to completion → `{:ok, {exit_code, stdout, stderr}}`."
  @spec exec(vm(), String.t(), non_neg_integer()) ::
          {:ok, {integer(), binary(), binary()}} | {:error, reason()}
  def exec(_vm, _cmd, _max_ticks), do: nif_not_loaded()

  @doc "Capture the whole VM (linear memory + header) into a portable blob (A8)."
  @spec snapshot(vm()) :: {:ok, binary()} | {:error, reason()}
  def snapshot(_vm), do: nif_not_loaded()

  # Replaced by the native implementations once the .so loads; raising this means the .so was
  # not found/staged (a deployment error, not a VM error).
  defp nif_not_loaded, do: :erlang.nif_error(:nif_not_loaded)
end
