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
  not raises (the owning `AgentOS.Vm` decides policy). The public functions below validate the
  small Elixir-facing option surface, then call raw `*_nif` entries that run host work on a
  DirtyCpu scheduler.
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

  @type contract :: {tier :: integer(), budget_mib :: integer(), fuel :: integer()}
  @type relay_mode :: :deny | :relay
  @type persist_mode :: :deny | :stub
  @type boot_opt ::
          {:layers, [binary()]}
          | {:deterministic, boolean()}
          | {:contract, contract() | nil}
          | {:workers, non_neg_integer() | nil}
          | {:net, relay_mode()}
          | {:host_call, relay_mode()}
          | {:persist, persist_mode()}

  @type relay_event ::
          %{kind: :http, handle: pos_integer(), request: binary()}
          | %{kind: :host_call, handle: pos_integer(), name: String.t(), body: binary()}
          | %{kind: :ws_connect, handle: pos_integer(), url: String.t()}
          | %{kind: :ws_send, handle: pos_integer(), data: binary()}
          | %{kind: :ws_close, handle: pos_integer()}

  @doc """
  Boot a VM from a `kernel.wasm` plus either one base image or an ordered layer stack.

  Options intentionally mirror the production host builder rather than the whole Rust host:
  deterministic clock/RNG for parity tests, boot contract, worker count, and the explicit P2
  relay switches.

  `:net` and `:host_call` accept `:deny` or `:relay`. `:persist` accepts `:deny` or `:stub`;
  the stub is intentionally deny-only until the persistence ABI is made asynchronous.
  """
  @spec boot(binary(), binary() | nil, [boot_opt()]) :: {:ok, vm()} | {:error, reason()}
  def boot(wasm, base_image, opts \\ [])

  def boot(wasm, base_image, opts)
      when is_binary(wasm) and (is_binary(base_image) or is_nil(base_image)) and is_list(opts) do
    with {:ok, layers, deterministic, contract, workers, net, host_call, persist} <-
           boot_args(base_image, opts) do
      boot_nif(wasm, base_image, layers, deterministic, contract, workers, net, host_call, persist)
    end
  end

  def boot(_wasm, _base_image, _opts),
    do: {:error, "boot expects binary wasm, binary-or-nil base image, and keyword options"}

  @doc "Restore (or fork) a VM from a snapshot blob — the booted state IS the image (A8)."
  @spec restore(binary(), binary(), [boot_opt()]) :: {:ok, vm()} | {:error, reason()}
  def restore(wasm, snapshot, opts \\ [])

  def restore(wasm, snapshot, opts)
      when is_binary(wasm) and is_binary(snapshot) and is_list(opts) do
    with {:ok, deterministic, workers, net, host_call, persist} <- restore_args(opts) do
      restore_nif(wasm, snapshot, deterministic, workers, net, host_call, persist)
    end
  end

  def restore(_wasm, _snapshot, _opts),
    do: {:error, "restore expects binary wasm, binary snapshot, and keyword options"}

  @doc "Drive one bounded `mc_tick`: `{:ok, true}` while running, `{:ok, false}` once exited."
  @spec tick(vm()) :: {:ok, boolean()} | {:error, reason()}
  def tick(vm), do: tick_nif(vm)

  @doc "Feed bytes to the kernel as terminal input."
  @spec send_input(vm(), binary()) :: :ok | {:error, reason()}
  def send_input(vm, bytes) when is_binary(bytes), do: send_input_nif(vm, bytes)
  def send_input(_vm, _bytes), do: {:error, "send_input expects binary bytes"}

  @doc "Drain (and clear) the terminal output captured since the last call."
  @spec take_output(vm()) :: binary()
  def take_output(_vm), do: nif_not_loaded()

  @doc "Run a command to completion → `{:ok, {exit_code, stdout, stderr}}`."
  @spec exec(vm(), String.t(), non_neg_integer()) ::
          {:ok, {integer(), binary(), binary()}} | {:error, reason()}
  def exec(vm, cmd, max_ticks) when is_binary(cmd) and is_integer(max_ticks) and max_ticks >= 0,
    do: exec_nif(vm, cmd, max_ticks)

  def exec(_vm, _cmd, _max_ticks),
    do: {:error, "exec expects a binary command and non-negative max_ticks"}

  @doc "Start a structured exec job without driving it to completion."
  @spec exec_start(vm(), String.t()) :: {:ok, integer()} | {:error, reason()}
  def exec_start(vm, cmd) when is_binary(cmd), do: exec_start_nif(vm, cmd)
  def exec_start(_vm, _cmd), do: {:error, "exec_start expects a binary command"}

  @doc "Poll a structured exec job; `nil` means still running."
  @spec exec_poll(vm(), integer()) ::
          {:ok, nil | {integer(), binary(), binary()}} | {:error, reason()}
  def exec_poll(vm, job) when is_integer(job) and job > 0, do: exec_poll_nif(vm, job)
  def exec_poll(_vm, _job), do: {:error, "exec_poll expects a positive job id"}

  @doc "Read stdout produced so far by a running exec job."
  @spec exec_stdout_peek(vm(), integer()) :: {:ok, binary()} | {:error, reason()}
  def exec_stdout_peek(vm, job) when is_integer(job) and job > 0,
    do: exec_stdout_peek_nif(vm, job)

  def exec_stdout_peek(_vm, _job), do: {:error, "exec_stdout_peek expects a positive job id"}

  @doc "Cancel a structured exec job."
  @spec exec_cancel(vm(), integer()) :: :ok | {:error, reason()}
  def exec_cancel(vm, job) when is_integer(job) and job > 0, do: exec_cancel_nif(vm, job)
  def exec_cancel(_vm, _job), do: {:error, "exec_cancel expects a positive job id"}

  @doc "Read a whole file through the Rust host control channel."
  @spec read_file(vm(), String.t()) :: {:ok, binary()} | {:error, reason()}
  def read_file(vm, path) when is_binary(path), do: read_file_nif(vm, path)
  def read_file(_vm, _path), do: {:error, "read_file expects a binary path"}

  @doc "Write a whole file through the Rust host control channel."
  @spec write_file(vm(), String.t(), binary()) :: :ok | {:error, reason()}
  def write_file(vm, path, data) when is_binary(path) and is_binary(data),
    do: write_file_nif(vm, path, data)

  def write_file(_vm, _path, _data), do: {:error, "write_file expects a binary path and data"}

  @type dir_entry :: %{name: String.t(), type: :directory | :symlink | :file}

  @doc "List a directory through the Rust host control channel."
  @spec readdir(vm(), String.t()) :: {:ok, [dir_entry()]} | {:error, reason()}
  def readdir(vm, path) when is_binary(path) do
    case readdir_nif(vm, path) do
      {:ok, entries} -> {:ok, Enum.map(entries, &dir_entry/1)}
      {:error, _reason} = err -> err
    end
  end

  def readdir(_vm, _path), do: {:error, "readdir expects a binary path"}

  @type file_stat :: %{
          size: non_neg_integer(),
          type: :directory | :symlink | :file,
          nlink: non_neg_integer()
        }

  @doc "Stat a path through the Rust host control channel."
  @spec stat(vm(), String.t()) :: {:ok, file_stat()} | {:error, reason()}
  def stat(vm, path) when is_binary(path) do
    case stat_nif(vm, path) do
      {:ok, {size, is_dir, is_symlink, nlink}} ->
        {:ok, %{size: size, type: file_type(is_dir, is_symlink), nlink: nlink}}

      {:error, _reason} = err ->
        err
    end
  end

  def stat(_vm, _path), do: {:error, "stat expects a binary path"}

  @doc "Create a directory through the Rust host control channel."
  @spec mkdir(vm(), String.t()) :: :ok | {:error, reason()}
  def mkdir(vm, path) when is_binary(path), do: mkdir_nif(vm, path)
  def mkdir(_vm, _path), do: {:error, "mkdir expects a binary path"}

  @doc "Remove a file or empty directory through the Rust host control channel."
  @spec unlink(vm(), String.t()) :: :ok | {:error, reason()}
  def unlink(vm, path) when is_binary(path), do: unlink_nif(vm, path)
  def unlink(_vm, _path), do: {:error, "unlink expects a binary path"}

  @doc "Create a symbolic link through the Rust host control channel."
  @spec symlink(vm(), String.t(), String.t()) :: :ok | {:error, reason()}
  def symlink(vm, target, link) when is_binary(target) and is_binary(link),
    do: symlink_nif(vm, target, link)

  def symlink(_vm, _target, _link),
    do: {:error, "symlink expects binary target and link paths"}

  @doc "Serialize the live CoW overlay into `{tar_bytes, digest}`."
  @spec commit_layer(vm()) :: {:ok, {binary(), String.t()}} | {:error, reason()}
  def commit_layer(vm), do: commit_layer_nif(vm)

  @type status :: %{
          bytes_written: non_neg_integer(),
          exit_code: integer() | nil,
          at_prompt: boolean(),
          workers: non_neg_integer(),
          has_worker_entry: boolean(),
          inflight_egress: non_neg_integer(),
          pending_commits: non_neg_integer()
        }

  @doc "Host-level VM status from the Rust host."
  @spec status(vm()) :: {:ok, status()} | {:error, reason()}
  def status(vm) do
    case status_nif(vm) do
      {:ok,
       {bytes_written, exit_code, at_prompt, workers, has_worker_entry, inflight_egress,
        pending_commits}} ->
        {:ok,
         %{
           bytes_written: bytes_written,
           exit_code: exit_code,
           at_prompt: at_prompt,
           workers: workers,
           has_worker_entry: has_worker_entry,
           inflight_egress: inflight_egress,
           pending_commits: pending_commits
         }}

      {:error, _reason} = err ->
        err
    end
  end

  @doc "Capture the whole VM (linear memory + header) into a portable blob (A8)."
  @spec snapshot(vm()) :: {:ok, binary()} | {:error, reason()}
  def snapshot(vm), do: snapshot_nif(vm)

  @doc "Drain the next outbound egress relay event, if any."
  @spec relay_next(vm()) :: {:ok, relay_event() | nil} | {:error, reason()}
  def relay_next(vm) do
    case relay_next_nif(vm) do
      {:ok, nil} -> {:ok, nil}
      {:ok, {kind, handle, a, b}} -> relay_event(kind, handle, a, b)
      {:error, _reason} = err -> err
    end
  end

  @doc "Answer an HTTP relay event with a complete buffered response."
  @spec relay_http_respond(vm(), integer(), non_neg_integer(), String.t(), [{String.t(), String.t()}], binary()) ::
          :ok | {:error, reason()}
  def relay_http_respond(vm, handle, status, reason, headers, body)
      when is_integer(handle) and handle > 0 and is_integer(status) and status >= 100 and
             status <= 999 and is_binary(reason) and is_list(headers) and is_binary(body) do
    with {:ok, head} <- http_head(status, reason, headers) do
      relay_http_respond_nif(vm, handle, true, head, body)
    end
  end

  def relay_http_respond(_vm, _handle, _status, _reason, _headers, _body),
    do: {:error, "relay_http_respond expects handle, status, reason, headers, and binary body"}

  @doc "Fail an HTTP relay event."
  @spec relay_http_fail(vm(), integer()) :: :ok | {:error, reason()}
  def relay_http_fail(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_http_respond_nif(vm, handle, false, "", "")

  def relay_http_fail(_vm, _handle), do: {:error, "relay_http_fail expects a positive handle"}

  @doc "Answer a host_call relay event."
  @spec relay_host_call_respond(vm(), integer(), binary()) :: :ok | {:error, reason()}
  def relay_host_call_respond(vm, handle, result) when is_integer(handle) and handle > 0 and is_binary(result),
    do: relay_host_call_respond_nif(vm, handle, true, result)

  def relay_host_call_respond(_vm, _handle, _result),
    do: {:error, "relay_host_call_respond expects a positive handle and binary result"}

  @doc "Fail a host_call relay event."
  @spec relay_host_call_fail(vm(), integer()) :: :ok | {:error, reason()}
  def relay_host_call_fail(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_host_call_respond_nif(vm, handle, false, "")

  def relay_host_call_fail(_vm, _handle), do: {:error, "relay_host_call_fail expects a positive handle"}

  @doc "Mark a WebSocket relay connection as opened."
  @spec relay_ws_open(vm(), integer()) :: :ok | {:error, reason()}
  def relay_ws_open(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_ws_open_nif(vm, handle, true)

  def relay_ws_open(_vm, _handle), do: {:error, "relay_ws_open expects a positive handle"}

  @doc "Fail a WebSocket relay connection."
  @spec relay_ws_fail(vm(), integer()) :: :ok | {:error, reason()}
  def relay_ws_fail(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_ws_open_nif(vm, handle, false)

  def relay_ws_fail(_vm, _handle), do: {:error, "relay_ws_fail expects a positive handle"}

  @doc "Push one received WebSocket message into a relay connection."
  @spec relay_ws_push(vm(), integer(), binary()) :: :ok | {:error, reason()}
  def relay_ws_push(vm, handle, data) when is_integer(handle) and handle > 0 and is_binary(data),
    do: relay_ws_push_nif(vm, handle, data)

  def relay_ws_push(_vm, _handle, _data),
    do: {:error, "relay_ws_push expects a positive handle and binary data"}

  @doc "Mark a WebSocket relay connection as closed by the peer."
  @spec relay_ws_close(vm(), integer()) :: :ok | {:error, reason()}
  def relay_ws_close(vm, handle) when is_integer(handle) and handle > 0,
    do: relay_ws_close_nif(vm, handle)

  def relay_ws_close(_vm, _handle), do: {:error, "relay_ws_close expects a positive handle"}

  @doc false
  def boot_nif(
        _wasm,
        _base_image,
        _layers,
        _deterministic,
        _contract,
        _workers,
        _net,
        _host_call,
        _persist
      ),
    do: nif_not_loaded()

  @doc false
  def restore_nif(_wasm, _snapshot, _deterministic, _workers, _net, _host_call, _persist),
    do: nif_not_loaded()

  @doc false
  def tick_nif(_vm), do: nif_not_loaded()

  @doc false
  def send_input_nif(_vm, _bytes), do: nif_not_loaded()

  @doc false
  def exec_nif(_vm, _cmd, _max_ticks), do: nif_not_loaded()

  @doc false
  def exec_start_nif(_vm, _cmd), do: nif_not_loaded()

  @doc false
  def exec_poll_nif(_vm, _job), do: nif_not_loaded()

  @doc false
  def exec_stdout_peek_nif(_vm, _job), do: nif_not_loaded()

  @doc false
  def exec_cancel_nif(_vm, _job), do: nif_not_loaded()

  @doc false
  def read_file_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def write_file_nif(_vm, _path, _data), do: nif_not_loaded()

  @doc false
  def readdir_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def stat_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def mkdir_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def unlink_nif(_vm, _path), do: nif_not_loaded()

  @doc false
  def symlink_nif(_vm, _target, _link), do: nif_not_loaded()

  @doc false
  def commit_layer_nif(_vm), do: nif_not_loaded()

  @doc false
  def status_nif(_vm), do: nif_not_loaded()

  @doc false
  def snapshot_nif(_vm), do: nif_not_loaded()

  @doc false
  def relay_next_nif(_vm), do: nif_not_loaded()

  @doc false
  def relay_http_respond_nif(_vm, _handle, _ok, _head, _body), do: nif_not_loaded()

  @doc false
  def relay_host_call_respond_nif(_vm, _handle, _ok, _result), do: nif_not_loaded()

  @doc false
  def relay_ws_open_nif(_vm, _handle, _ok), do: nif_not_loaded()

  @doc false
  def relay_ws_push_nif(_vm, _handle, _data), do: nif_not_loaded()

  @doc false
  def relay_ws_close_nif(_vm, _handle), do: nif_not_loaded()

  defp boot_args(base_image, opts) do
    with {:ok, layers} <- layers_arg(opts),
         :ok <- exclusive_base_or_layers(base_image, layers),
         {:ok, deterministic} <- boolean_arg(opts, :deterministic, false),
         {:ok, contract} <- contract_arg(opts),
         {:ok, workers} <- workers_arg(opts),
         {:ok, net, host_call, persist} <- relay_args(opts) do
      {:ok, layers, deterministic, contract, workers, net, host_call, persist}
    end
  end

  defp restore_args(opts) do
    with {:ok, deterministic} <- boolean_arg(opts, :deterministic, false),
         {:ok, workers} <- workers_arg(opts),
         {:ok, net, host_call, persist} <- relay_args(opts) do
      {:ok, deterministic, workers, net, host_call, persist}
    end
  end

  defp layers_arg(opts) do
    case Keyword.get(opts, :layers, []) do
      layers when is_list(layers) ->
        if Enum.all?(layers, &is_binary/1) do
          {:ok, layers}
        else
          {:error, "layers must be a list of binaries"}
        end

      _other -> {:error, "layers must be a list of binaries"}
    end
  end

  defp exclusive_base_or_layers(nil, _layers), do: :ok
  defp exclusive_base_or_layers(_base_image, []), do: :ok
  defp exclusive_base_or_layers(_base_image, _layers),
    do: {:error, "base_image and layers are mutually exclusive"}

  defp boolean_arg(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _other -> {:error, "#{key} must be a boolean"}
    end
  end

  defp contract_arg(opts) do
    case Keyword.get(opts, :contract, nil) do
      nil -> {:ok, nil}
      {tier, budget_mib, fuel} when is_integer(tier) and is_integer(budget_mib) and is_integer(fuel) ->
        {:ok, {tier, budget_mib, fuel}}

      _other ->
        {:error, "contract must be nil or {tier, budget_mib, fuel}"}
    end
  end

  defp workers_arg(opts) do
    case Keyword.get(opts, :workers, nil) do
      nil -> {:ok, nil}
      workers when is_integer(workers) and workers >= 0 -> {:ok, workers}
      _other -> {:error, "workers must be nil or a non-negative integer"}
    end
  end

  defp relay_args(opts) do
    with {:ok, net} <- relay_mode_arg(opts, :net),
         {:ok, host_call} <- relay_mode_arg(opts, :host_call),
         {:ok, persist} <- persist_mode_arg(opts) do
      {:ok, net == :relay, host_call == :relay, persist == :stub}
    end
  end

  defp relay_mode_arg(opts, key) do
    case Keyword.get(opts, key, :deny) do
      mode when mode in [:deny, :relay] -> {:ok, mode}
      _other -> {:error, "#{key} must be :deny or :relay"}
    end
  end

  defp persist_mode_arg(opts) do
    case Keyword.get(opts, :persist, :deny) do
      mode when mode in [:deny, :stub] -> {:ok, mode}
      :relay -> {:error, "persist relay requires an async persistence ABI; use :deny or :stub"}
      _other -> {:error, "persist must be :deny or :stub"}
    end
  end

  defp http_head(status, reason, headers) do
    with :ok <- headers_arg(headers) do
      head =
        IO.iodata_to_binary([
          Integer.to_string(status),
          " ",
          reason,
          "\r\n",
          Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
          "\r\n"
        ])

      {:ok, head}
    end
  end

  defp headers_arg(headers) do
    if Enum.all?(headers, fn
         {name, value} -> is_binary(name) and is_binary(value)
         _other -> false
       end) do
      :ok
    else
      {:error, "headers must be {binary_name, binary_value} pairs"}
    end
  end

  defp relay_event("http", handle, request, ""),
    do: {:ok, %{kind: :http, handle: handle, request: request}}

  defp relay_event("host_call", handle, name, body),
    do: {:ok, %{kind: :host_call, handle: handle, name: name, body: body}}

  defp relay_event("ws_connect", handle, url, ""),
    do: {:ok, %{kind: :ws_connect, handle: handle, url: url}}

  defp relay_event("ws_send", handle, data, ""),
    do: {:ok, %{kind: :ws_send, handle: handle, data: data}}

  defp relay_event("ws_close", handle, "", ""),
    do: {:ok, %{kind: :ws_close, handle: handle}}

  defp relay_event(kind, _handle, _a, _b), do: {:error, "unknown relay event kind #{inspect(kind)}"}

  defp dir_entry({name, is_dir, is_symlink}),
    do: %{name: name, type: file_type(is_dir, is_symlink)}

  defp file_type(true, _is_symlink), do: :directory
  defp file_type(false, true), do: :symlink
  defp file_type(false, false), do: :file

  # Replaced by the native implementations once the .so loads; raising this means the .so was
  # not found/staged (a deployment error, not a VM error).
  defp nif_not_loaded, do: :erlang.nif_error(:nif_not_loaded)
end
