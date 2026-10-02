defmodule ExAtlas.Test.Repo do
  @moduledoc """
  A SQLite repo for the `ExAtlas.Orchestrator.TrackingStore.Ecto` tests.

  Each test starts it on its own database file with `start!/1`, so no test
  needs a database server and no two tests share rows.
  """

  use Ecto.Repo, otp_app: :ex_atlas, adapter: Ecto.Adapters.SQLite3

  alias ExAtlas.Test.Repo.AddAtlasTracking

  @doc """
  Start the repo on `<dir>/atlas.db` under the test supervisor, migrate it
  unless `migrate: false`, and point `config :ex_atlas, :orchestrator, repo:`
  at it.
  """
  @spec start!(Path.t(), keyword()) :: Path.t()
  def start!(dir, opts \\ []) do
    database = Path.join(dir, "atlas.db")
    ExUnit.Callbacks.start_supervised!({__MODULE__, database: database, log: false})

    if Keyword.get(opts, :migrate, true), do: migrate!()

    ExAtlas.Test.Orchestrator.put_env(repo: __MODULE__)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:ex_atlas, :orchestrator) end)
    database
  end

  @doc "Run the host migration that calls the shipped migration module."
  @spec migrate!() :: :ok
  def migrate! do
    Ecto.Migrator.run(__MODULE__, [{20_261_002_000_000, AddAtlasTracking}], :up,
      all: true,
      log: false
    )

    :ok
  end

  defmodule AddAtlasTracking do
    @moduledoc false
    # What a host writes in priv/repo/migrations.
    use Ecto.Migration

    def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up()
    def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down()
  end
end
