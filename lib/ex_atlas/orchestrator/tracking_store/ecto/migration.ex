if Code.ensure_loaded?(Ecto.Migration) do
  defmodule ExAtlas.Orchestrator.TrackingStore.Ecto.Migration do
    @moduledoc """
    Creates the `atlas_tracking_records` table that
    `ExAtlas.Orchestrator.TrackingStore.Ecto` reads and writes.

    Call it from a migration in the host's repo:

        defmodule MyApp.Repo.Migrations.AddAtlasTracking do
          use Ecto.Migration

          def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up()
          def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down()
        end

    One row per record: `id` (primary key), `owner` (nullable, indexed),
    `record` (the `:erlang.term_to_binary/1` blob) and timestamps. The types
    are portable, so the table works on Postgres and SQLite.

    ## Versions

    `up/1` and `down/1` take `version:`, which names the last step to run,
    2 by default:

      * Step 1 creates `atlas_tracking_records`.
      * Step 2 creates `atlas_owner_leases`: one row per `:reap_owner`, with
        the time its lease expires, so a live node can take over the records
        of a dead one.

    A host that ran step 1 writes a new migration that calls
    `up(version: 2)`. Every step creates only what is missing, so running
    step 1 again is harmless. `down(version: n)` reverses the steps from the
    newest down to `n`; `down/0` drops both tables.

    Both run only inside a migration: outside `Ecto.Migrator`'s runner,
    `Ecto.Migration`'s commands raise, so a `down/0` typed into a release
    console drops nothing.
    """

    import Ecto.Migration

    @table :atlas_tracking_records
    @leases :atlas_owner_leases
    @current 2

    @doc "Run the steps up to `version:` (default #{@current})."
    @spec up(keyword()) :: :ok
    def up(opts \\ []) do
      for step <- 1..version(opts, @current)//1, do: step(step, :up)
      :ok
    end

    @doc "Reverse the steps from the newest down to `version:` (default 1)."
    @spec down(keyword()) :: :ok
    def down(opts \\ []) do
      for step <- @current..version(opts, 1)//-1, do: step(step, :down)
      :ok
    end

    defp version(opts, default) do
      case Keyword.get(opts, :version, default) do
        version when is_integer(version) and version in 1..@current//1 ->
          version

        other ->
          raise ArgumentError,
                "#{inspect(__MODULE__)} has versions 1 to #{@current}, got version: #{inspect(other)}"
      end
    end

    defp step(1, :up) do
      create_if_not_exists table(@table, primary_key: false) do
        add(:id, :string, primary_key: true)
        add(:owner, :string)
        add(:record, :binary, null: false)
        timestamps(type: :utc_datetime_usec)
      end

      create_if_not_exists(index(@table, [:owner]))
    end

    defp step(1, :down), do: drop_if_exists(table(@table))

    defp step(2, :up) do
      create_if_not_exists table(@leases, primary_key: false) do
        add(:owner, :string, primary_key: true)
        add(:expires_at, :utc_datetime_usec, null: false)
        timestamps(type: :utc_datetime_usec)
      end
    end

    defp step(2, :down), do: drop_if_exists(table(@leases))
  end
end
