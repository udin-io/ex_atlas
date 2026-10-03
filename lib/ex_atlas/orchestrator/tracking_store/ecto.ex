if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule ExAtlas.Orchestrator.TrackingStore.Ecto.Row do
    @moduledoc false
    # The table `ExAtlas.Orchestrator.TrackingStore.Ecto.Migration` creates.

    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "atlas_tracking_records" do
      field(:owner, :string)
      field(:record, :binary)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule ExAtlas.Orchestrator.TrackingStore.Ecto.Lease do
    @moduledoc false
    # The table migration step 2 creates: one row per `:reap_owner`. Step 3
    # adds `mac`.

    use Ecto.Schema

    @primary_key {:owner, :string, autogenerate: false}
    schema "atlas_owner_leases" do
      field(:expires_at, :utc_datetime_usec)
      field(:mac, :binary)
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule ExAtlas.Orchestrator.TrackingStore.Ecto do
    @moduledoc """
    `ExAtlas.Orchestrator.TrackingStore` in a table of the host's own Ecto repo.

    A database outlives a deploy where a machine's filesystem does not: on a
    Fly machine with no volume, the DETS default comes up empty and the Reaper
    deletes the pods it should adopt. This store keeps the records where the
    host keeps the rest of its data.

    ## Setup

        # config/runtime.exs
        config :ex_atlas, start_orchestrator: false   # the host starts the tree
        config :ex_atlas, :orchestrator,
          tracking_store: ExAtlas.Orchestrator.TrackingStore.Ecto,
          repo: MyApp.Repo,
          reap_owner: "web-1"

        # priv/repo/migrations/20261002000000_add_atlas_tracking.exs
        def up, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up()
        def down, do: ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.down()

        # lib/my_app/application.ex
        children = [MyApp.Repo, ExAtlas.Orchestrator.Supervisor, MyAppWeb.Endpoint]

    The orchestrator must start after the repo, so the host starts
    `ExAtlas.Orchestrator.Supervisor` itself instead of setting
    `start_orchestrator: true`: ExAtlas's own tree boots before the host's, and
    the Adopter's `all/0` would find no repo. Shutdown runs in reverse, so the
    trackers write their records while the repo is still up.

    Starting the store with no `:repo` configured, or before the repo runs,
    raises `ArgumentError`.
    Postgres and SQLite work; MySQL does not, since its upsert takes no
    conflict target.

    ## Owner leases

    Migration step 2 adds `atlas_owner_leases`, one row per `:reap_owner`.
    With `:reap_owner` set, `ExAtlas.Orchestrator.Lease` renews this node's
    row every `lease_ttl_ms / 3` (every 30 s at the default 90 s) and takes over the signed
    records of an owner whose lease expired. Each record is claimed by one
    conditional `UPDATE` that re-checks the old owner and its expired lease,
    so two live nodes never both adopt it. `expired_leases/1` lists the
    expired rows for the Lease's dead-owner watch, and the Reaper deletes the
    untracked pods of an owner that stays dead (`:reap_dead_owner_after_ms`).
    A host that ran step 1 adds a
    migration calling `Migration.up(version: 2)`; until then the lease
    renewal logs a warning every tick and claims nothing.

    Step 3 adds a `mac` column: each renewal writes
    `ExAtlas.Orchestrator.TrackingStore.lease_mac/2` beside the expiry, and
    the Lease reads an owner as dead only from a row its key verifies. On a
    table without step 3 the renewal writes no `mac`, every row reads
    unsigned so no owner is dead, and `start_link/1` logs one warning per
    boot.

    ## What a row holds

    The whole record is one `:erlang.term_to_binary/1` blob in `record`, so
    every field and nested opt round-trips and a new record version needs no
    migration. `owner` repeats the record's `:owner` for queries.

    ## Reading a row is a boundary

    Anyone who can write the host's database can write these rows. A row is
    decoded with `Plug.Crypto.non_executable_binary_to_term/2` and `[:safe]`,
    which refuses atoms this node does not have and any function. A row that
    is not a map with its own `id` is refused too, and so is a compressed row
    or one over 1 MiB (1,048,576 bytes): a compressed term declares its own decoded
    size, up to 4 GB. `put/1` logs a record over that size and writes nothing.

    A row that decodes is still not trusted input. An adopted task takes its
    provider's URL and Req options from config, never from the row, and runs
    only a provider that declares `ExAtlas.Provider` (see "Where an adopted
    task's calls go" in `ExAtlas.Orchestrator.TrackingStore`). The row still
    chooses what a respawn after adoption rents. Let only the app write
    `atlas_tracking_records`.

      * `all/0` answers `{:error, {:undecodable, ids}}` when any row is
        refused. The Adopter then adopts nothing and the Reaper reaps nothing
        this boot, as for a corrupt DETS file. Skipping the row instead would
        leave its pod with no record, and the Reaper would delete it.
      * `get/1` raises on a refused row. The Reaper reads a raise as "ours,
        leave it alone"; `:error` would read as "not ours".

    ## When the database is down

      * `all/0` answers `{:error, _}`, with the same effect as above.
      * `get/1` raises, so the Reaper leaves the pod alone.
      * `put/1` and `delete/1` log the failure and return `:ok`, so a running
        tracker carries on. A record that was not written is not adopted at
        the next boot, as with the DETS store when it is not running.
    """

    @behaviour ExAtlas.Orchestrator.TrackingStore

    import Ecto.Query, only: [from: 2]

    require Logger

    alias ExAtlas.Orchestrator.TrackingStore
    alias ExAtlas.Orchestrator.TrackingStore.Ecto.{Lease, Row}

    # A record is a few KB. The cap bounds what one row costs to decode.
    @max_record_bytes 1_048_576

    @impl ExAtlas.Orchestrator.TrackingStore
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
    end

    @doc """
    Checks that `:repo` is configured and running, and starts no process.

    Raises `ArgumentError` otherwise, so a host finds a missing repo, or an
    orchestrator started before it, at boot rather than at its first deploy.
    `start_orchestrator: true` boots ExAtlas's tree before the host's repo, so
    it fails here too.
    """
    @spec start_link(keyword()) :: :ignore
    def start_link(_opts \\ []) do
      repo = repo!()

      unless GenServer.whereis(repo.get_dynamic_repo()) do
        raise ArgumentError,
              "#{inspect(repo)} is not running, and #{inspect(__MODULE__)} reads it at " <>
                "boot. Set `config :ex_atlas, start_orchestrator: false` and start " <>
                "ExAtlas.Orchestrator.Supervisor after #{inspect(repo)} in your " <>
                "application's children."
      end

      warn_unsigned_leases(repo)
      :ignore
    end

    # Once per boot: a lease table from step 2 renews unsigned rows, and no
    # owner reads as dead. Silent when the table is missing or unreadable;
    # the lease's own calls log that.
    defp warn_unsigned_leases(repo) do
      if readable?(repo, :owner) and not readable?(repo, :mac) do
        Logger.warning(
          "[ExAtlas.Orchestrator.TrackingStore.Ecto] atlas_owner_leases has no mac column, so " <>
            "lease rows are unsigned and no owner reads as dead. Add a migration calling " <>
            "ExAtlas.Orchestrator.TrackingStore.Ecto.Migration.up(version: 3)."
        )
      end
    end

    defp readable?(repo, column) do
      _ = repo.all(from(l in Lease, select: field(l, ^column), limit: 0), log: false)
      true
    rescue
      _error -> false
    end

    @impl ExAtlas.Orchestrator.TrackingStore
    def put(%{id: id} = record) do
      repo = repo!()
      blob = :erlang.term_to_binary(record)

      if byte_size(blob) > @max_record_bytes do
        Logger.error(
          "[ExAtlas.Orchestrator.TrackingStore.Ecto] the tracking record for #{id} is " <>
            "#{byte_size(blob)} bytes, over the #{@max_record_bytes} bytes a row may hold; " <>
            "it is not written, and the row keeps its previous version, if any."
        )
      else
        write(repo, id, record, blob)
      end

      :ok
    end

    defp write(repo, id, record, blob) do
      now = DateTime.utc_now()

      row = %{
        id: id,
        owner: owner_column(record),
        record: blob,
        inserted_at: now,
        updated_at: now
      }

      outside_transaction(fn ->
        try do
          repo.insert_all(Row, [row],
            on_conflict: {:replace, [:owner, :record, :updated_at]},
            conflict_target: [:id]
          )

          :ok
        rescue
          error ->
            Logger.error(
              "[ExAtlas.Orchestrator.TrackingStore.Ecto] could not write the tracking record " <>
                "for #{id} (#{Exception.message(error)}). It will not be adopted at the next " <>
                "boot, and the Reaper will treat it as an orphan."
            )

            :ok
        end
      end)
    end

    @impl ExAtlas.Orchestrator.TrackingStore
    def get(id) do
      case repo!().one(from(r in Row, where: r.id == ^id, select: r.record)) do
        nil ->
          :error

        blob ->
          case decode(id, blob) do
            {:ok, record} ->
              {:ok, record}

            :error ->
              raise ArgumentError,
                    "the tracking record row #{id} will not decode safely; it is kept"
          end
      end
    end

    @impl ExAtlas.Orchestrator.TrackingStore
    def delete(id) do
      repo = repo!()

      outside_transaction(fn ->
        try do
          _ = repo.delete_all(from(r in Row, where: r.id == ^id))
          :ok
        rescue
          error ->
            Logger.error(
              "[ExAtlas.Orchestrator.TrackingStore.Ecto] could not delete the tracking record " <>
                "for #{id} (#{Exception.message(error)}). The next boot finds the pod gone " <>
                "and deletes the record then."
            )

            :ok
        end
      end)
    end

    # `spawn/1` writes from the caller's process, and a repo call in a process
    # that is inside a transaction joins it. A host that rolls back would erase
    # the record of a running pod, so every write runs in its own process.
    # The repo's own timeout bounds the wait.
    defp outside_transaction(fun), do: fun |> Task.async() |> Task.await(:infinity)

    @impl ExAtlas.Orchestrator.TrackingStore
    def all do
      rows = repo!().all(from(r in Row, select: {r.id, r.record}))

      case Enum.reduce(rows, {[], []}, &decode_row/2) do
        {records, []} -> {:ok, records}
        {_records, refused} -> {:error, {:undecodable, Enum.sort(refused)}}
      end
    rescue
      error -> {:error, error}
    end

    defp decode_row({id, blob}, {records, refused}) do
      case decode(id, blob) do
        {:ok, record} -> {[record | records], refused}
        :error -> {records, [id | refused]}
      end
    end

    # `[:safe]` refuses atoms this node does not have; the Plug.Crypto walk
    # refuses functions. Neither error is logged: its message prints the term.
    defp decode(_id, blob) when not is_binary(blob) or byte_size(blob) > @max_record_bytes,
      do: :error

    defp decode(_id, <<131, 80, _compressed::binary>>), do: :error

    defp decode(id, blob) do
      case Plug.Crypto.non_executable_binary_to_term(blob, [:safe]) do
        %{id: ^id} = record -> {:ok, record}
        _not_this_record -> :error
      end
    rescue
      _error -> :error
    end

    @impl ExAtlas.Orchestrator.TrackingStore
    def renew_lease(owner, expires_at_ms) when is_binary(owner) and is_integer(expires_at_ms) do
      repo = repo!()
      now = DateTime.utc_now()
      expires_at = usec(expires_at_ms)
      row = %{owner: owner, expires_at: expires_at, inserted_at: now, updated_at: now}
      signed = Map.put(row, :mac, TrackingStore.lease_mac(owner, expires_at_ms))

      # The write runs in a linked task, so its raise is caught there. A
      # table without step 3 has no `mac`: renew unsigned rather than not
      # at all, or this node would lose its records to a claimer.
      outside_transaction(fn ->
        with {:error, _no_mac_column} <- upsert_lease(repo, signed, [:expires_at, :mac]) do
          upsert_lease(repo, row, [:expires_at])
        end
      end)
    end

    defp upsert_lease(repo, row, columns) do
      repo.insert_all(Lease, [row],
        on_conflict: {:replace, columns ++ [:updated_at]},
        conflict_target: [:owner]
      )

      :ok
    rescue
      error -> {:error, error}
    end

    defp usec(ms), do: DateTime.from_unix!(ms * 1_000, :microsecond)

    @impl ExAtlas.Orchestrator.TrackingStore
    def expired_leases(now_ms) when is_integer(now_ms) do
      repo = repo!()
      expired = from(l in Lease, where: l.expires_at < ^usec(now_ms))

      # A table without step 3 has no `mac`: every row reads unsigned.
      leases =
        try do
          repo.all(from(l in expired, select: {l.owner, l.expires_at, l.mac}))
        rescue
          _no_mac_column -> repo.all(from(l in expired, select: {l.owner, l.expires_at, nil}))
        end

      {:ok,
       Map.new(leases, fn {owner, at, mac} ->
         {owner, {DateTime.to_unix(at, :millisecond), mac}}
       end)}
    rescue
      error -> {:error, error}
    end

    # Each row is claimed by its own conditional UPDATE, which sets the owner
    # column and the record together: the record holds `:owner` too, under
    # its signature. The WHERE re-checks the old owner and its expired lease,
    # so of two claimers one writes the row and the other matches nothing,
    # and an owner that renewed since the read keeps it.
    @impl ExAtlas.Orchestrator.TrackingStore
    def claim_expired(claimer, now_ms, rewrite)
        when is_binary(claimer) and is_integer(now_ms) and is_function(rewrite, 1) do
      repo = repo!()
      now = usec(now_ms)

      candidates =
        repo.all(
          from(r in Row,
            where: r.owner in subquery(expired_owners(claimer, now)),
            select: {r.id, r.owner, r.record}
          )
        )

      {:ok, Enum.flat_map(candidates, &claim_row(repo, &1, claimer, now, rewrite))}
    rescue
      error -> {:error, error}
    end

    defp expired_owners(claimer, now) do
      from(l in Lease, where: l.expires_at < ^now and l.owner != ^claimer, select: l.owner)
    end

    # The column is only a copy for queries; the record's own `:owner` sits
    # under its signature. A row whose column was moved to another owner is
    # not that owner's to hand over.
    defp claim_row(repo, {id, old_owner, blob}, claimer, now, rewrite) do
      with {:ok, %{owner: ^old_owner} = record} <- decode(id, blob),
           {:ok, %{id: ^id, owner: ^claimer} = claimed} <- safe_rewrite(rewrite, record),
           new_blob = :erlang.term_to_binary(claimed),
           true <- byte_size(new_blob) <= @max_record_bytes,
           1 <- update_claimed(repo, id, old_owner, claimer, new_blob, now) do
        [claimed]
      else
        _skipped_or_lost -> []
      end
    end

    # Rows claimed before a raise are already written; one bad record must not
    # turn the whole claim into an error that hides them.
    defp safe_rewrite(rewrite, record) do
      rewrite.(record)
    rescue
      _error -> :skip
    catch
      _kind, _reason -> :skip
    end

    defp update_claimed(repo, id, old_owner, claimer, blob, now) do
      query =
        from(r in Row,
          where:
            r.id == ^id and r.owner == ^old_owner and
              r.owner in subquery(expired_owners(claimer, now))
        )

      outside_transaction(fn ->
        try do
          {count, _} =
            repo.update_all(query,
              set: [owner: claimer, record: blob, updated_at: DateTime.utc_now()]
            )

          count
        rescue
          _error -> 0
        end
      end)
    end

    defp owner_column(%{owner: owner}) when is_binary(owner), do: owner
    defp owner_column(_record), do: nil

    defp repo! do
      case Keyword.get(Application.get_env(:ex_atlas, :orchestrator, []), :repo) do
        nil ->
          raise ArgumentError,
                "#{inspect(__MODULE__)} needs a repo: set " <>
                  "`config :ex_atlas, :orchestrator, repo: MyApp.Repo`"

        repo when is_atom(repo) ->
          repo

        _other ->
          raise ArgumentError,
                "#{inspect(__MODULE__)} needs `config :ex_atlas, :orchestrator, repo:` " <>
                  "to name an Ecto repo module"
      end
    end
  end
end
