defmodule ExAtlas.Fly.Tokens.ETSOwner do
  @moduledoc """
  Owns the shared `:public` `:named_table` ETS table used by every
  `ExAtlas.Fly.Tokens.AppServer`.

  The table outlives individual AppServer crashes. Only `:rest_for_one` on the
  parent `ExAtlas.Fly.Tokens.Supervisor` can wipe it — by design, because that
  path also rebuilds every AppServer under the DynamicSupervisor, so the cache
  and its writers restart together.

  ## ETS schema

      {app_name, token, expires_at_unix_seconds}

  `:public` so multiple AppServers can write concurrently. `read_concurrency`
  and `write_concurrency` are both on — cache reads are the hot path and
  parallel writes are expected under a cold-start thundering herd.
  """

  use GenServer

  @default_table :ex_atlas_fly_tokens

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the ETS table name this owner is managing."
  @spec table_name(GenServer.server()) :: atom()
  def table_name(server \\ __MODULE__) do
    GenServer.call(server, :table_name)
  end

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @default_table)

    table =
      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        existing ->
          existing
      end

    {:ok, %{table: table, table_name: table_name}}
  end

  @impl GenServer
  def handle_call(:table_name, _from, state) do
    {:reply, state.table_name, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Mirror the PR-13 H1 hygiene: a named ETS table would otherwise survive
    # briefly and ArgumentError the next :ets.new on supervisor restart.
    if :ets.whereis(state.table_name) != :undefined do
      :ets.delete(state.table_name)
    end

    :ok
  end
end
