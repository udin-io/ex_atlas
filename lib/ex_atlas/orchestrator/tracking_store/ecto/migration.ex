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
    3 by default:

      * Step 1 creates `atlas_tracking_records`.
      * Step 2 creates `atlas_owner_leases`: one row per `:reap_owner`, with
        the time its lease expires, so a live node can take over the records
        of a dead one.
      * Step 3 adds a nullable `mac` column to `atlas_owner_leases`: each
        node signs its lease row, so a database writer without the callback
        secret cannot fake a dead owner.

    A host whose migrations ran an earlier step writes a new migration that
    calls `up(version: 3)`. Every step creates only what is missing, so a
    fresh database that runs `up/0` and then that migration is fine.
    `down(version: n)` reverses the steps from the newest down to `n`;
    `down/0` drops both tables.

    Both run only inside a migration: outside `Ecto.Migrator`'s runner,
    `Ecto.Migration`'s commands raise, so a `down/0` typed into a release
    console drops nothing.
    """

    import Ecto.Migration

    @table :atlas_tracking_records
    @leases :atlas_owner_leases
    @current 3

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

    # SQLite has no `ADD COLUMN IF NOT EXISTS`, so it reads the table's
    # columns first; `flush/0` runs the steps queued before this one.
    defp step(3, :up) do
      if sqlite?() do
        flush()
        unless mac_column?(), do: alter(table(@leases), do: add(:mac, :binary))
      else
        alter(table(@leases), do: add_if_not_exists(:mac, :binary))
      end
    end

    defp step(3, :down) do
      if sqlite?() do
        if mac_column?(), do: alter(table(@leases), do: remove(:mac))
      else
        alter(table(@leases), do: remove_if_exists(:mac, :binary))
      end
    end

    defp sqlite?, do: repo().__adapter__() == Ecto.Adapters.SQLite3

    defp mac_column? do
      %{rows: rows} =
        repo().query!(
          "SELECT 1 FROM pragma_table_info('#{@leases}') WHERE name = 'mac'",
          [],
          log: false
        )

      rows != []
    end
  end
end
