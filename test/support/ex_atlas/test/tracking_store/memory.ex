defmodule ExAtlas.Test.TrackingStore.Memory do
  @moduledoc """
  In-memory `ExAtlas.Orchestrator.TrackingStore` for tests.

  Exists for two reasons. It runs the adoption and reaping suites without
  touching the filesystem, and — more importantly — it is a second
  implementation of the behaviour, so the conformance suite proves the contract
  is really pluggable rather than a description of what DETS happens to do.

  `all/0` can be made to fail with `fail_all/1`, which is how a store that
  cannot account for its own contents is simulated. That is the state in which
  reaping stays off until a read succeeds; `fail_all(nil)` restores it.
  """

  @behaviour ExAtlas.Orchestrator.TrackingStore

  use Agent

  @impl ExAtlas.Orchestrator.TrackingStore
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{records: %{}, all_error: nil, get_raises: false} end,
      name: __MODULE__
    )
  end

  @doc """
  The record for `id` once `fun` returns true for it. Polls every 5 ms for up to
  2 s, because a tracker writes its record from its own mailbox after a status
  poll it starts on a timer, and sends no message a test could wait on.
  """
  def await(id, fun, tries \\ 400) do
    {:ok, record} = get(id)

    cond do
      fun.(record) ->
        record

      tries > 0 ->
        Process.sleep(5)
        await(id, fun, tries - 1)

      true ->
        raise ExUnit.AssertionError, message: "the record never matched: #{inspect(record)}"
    end
  end

  @doc "Make `all/0` answer `{:error, reason}`, as an unreadable store does."
  def fail_all(reason) do
    Agent.update(__MODULE__, &%{&1 | all_error: reason})
  end

  @doc """
  Make `get/1` raise, as a host store does when its database is down or a row
  will not decode. `fail_get(false)` restores it.
  """
  def fail_get(raises?) do
    Agent.update(__MODULE__, &%{&1 | get_raises: raises?})
  end

  @impl ExAtlas.Orchestrator.TrackingStore
  def put(record) do
    Agent.update(__MODULE__, &put_in(&1, [:records, record.id], record))
  end

  @impl ExAtlas.Orchestrator.TrackingStore
  def get(id) do
    state = Agent.get(__MODULE__, & &1)

    if state.get_raises, do: raise(RuntimeError, "simulated tracking store outage on get/1")

    case Map.fetch(state.records, id) do
      {:ok, record} -> {:ok, record}
      :error -> :error
    end
  end

  @impl ExAtlas.Orchestrator.TrackingStore
  def delete(id) do
    Agent.update(__MODULE__, &%{&1 | records: Map.delete(&1.records, id)})
  end

  @impl ExAtlas.Orchestrator.TrackingStore
  def all do
    Agent.get(__MODULE__, fn
      %{all_error: nil} = state -> {:ok, Map.values(state.records)}
      %{all_error: reason} -> {:error, reason}
    end)
  end
end
