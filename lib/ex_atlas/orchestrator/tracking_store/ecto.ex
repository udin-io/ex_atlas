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

    A row that decodes is still not trusted input. Its opts steer the provider
    calls an adopted task makes with this node's API key, `:base_url` among
    them (issue 125). Let only the app write `atlas_tracking_records`.

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

    alias ExAtlas.Orchestrator.TrackingStore.Ecto.Row

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

      :ignore
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
