defmodule AgentOS.Sidecars.Journal do
  @moduledoc "Durable intent log boundary used to reconcile provider resources after host loss."

  @callback append(map()) :: {:ok, reference() | binary()} | {:error, term()}
  @callback complete(reference() | binary(), map()) :: :ok | {:error, term()}
  @callback pending() :: [%{required(:journal_id) => reference() | binary(), optional(atom()) => term()}]

  def append(entry), do: implementation().append(entry)
  def complete(id, result), do: implementation().complete(id, result)
  def pending, do: implementation().pending()

  defp implementation do
    :persistent_term.get({__MODULE__, :implementation}, AgentOS.Sidecars.Journal.Memory)
  end
end

defmodule AgentOS.Sidecars.Journal.Memory do
  @moduledoc "Bounded development journal. Production hosts should configure a durable implementation."
  @behaviour AgentOS.Sidecars.Journal

  use GenServer

  @limit 4_096

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def append(entry), do: GenServer.call(__MODULE__, {:append, entry})
  @impl true
  def complete(id, result), do: GenServer.call(__MODULE__, {:complete, id, result})
  @impl true
  def pending, do: GenServer.call(__MODULE__, :pending)

  @impl true
  def init(_opts), do: {:ok, %{order: :queue.new(), entries: %{}}}

  @impl true
  def handle_call({:append, entry}, _from, state) do
    if map_size(state.entries) >= @limit do
      {:reply, {:error, :sidecar_journal_full}, state}
    else
      journal_id = make_ref()
      now = System.system_time(:millisecond)
      stored = Map.merge(entry, %{journal_id: journal_id, inserted_at_ms: now})

      next = %{
        state
        | order: :queue.in(journal_id, state.order),
          entries: Map.put(state.entries, journal_id, stored)
      }

      {:reply, {:ok, journal_id}, next}
    end
  end

  def handle_call({:complete, id, _result}, _from, state) do
    order = state.order |> :queue.to_list() |> Enum.reject(&(&1 == id)) |> :queue.from_list()
    {:reply, :ok, %{state | order: order, entries: Map.delete(state.entries, id)}}
  end

  def handle_call(:pending, _from, state) do
    entries =
      state.order
      |> :queue.to_list()
      |> Enum.flat_map(fn id -> if entry = state.entries[id], do: [entry], else: [] end)

    {:reply, entries, state}
  end
end
