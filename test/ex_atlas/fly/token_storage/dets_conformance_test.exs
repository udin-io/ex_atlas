defmodule ExAtlas.Fly.TokenStorage.DetsConformanceTest do
  @moduledoc """
  Runs the shared TokenStorage conformance suite against the DETS impl.

  Each test gets its own GenServer name + per-test DETS tables + storage
  dir, so it runs cleanly alongside the application-level singleton Dets
  instance started by `ExAtlas.Application`.
  """

  use ExUnit.Case, async: false

  alias ExAtlas.Fly.TokenStorage.Dets

  use ExAtlas.Fly.TokenStorageConformance,
    storage: __MODULE__.DetsProxy,
    setup: {__MODULE__, :__setup_dets__, []}

  @tmp_root "tmp/ex_atlas_fly_dets_conformance"

  # The conformance suite assumes a module with fixed get/put/delete/3 API.
  # Dets has it, but is a singleton-named GenServer. To run conformance
  # per-test with isolation, we redirect get/put/delete through a proxy
  # module that dispatches to the per-test Dets process name stashed in
  # the process dictionary.
  defmodule DetsProxy do
    @behaviour ExAtlas.Fly.TokenStorage

    @impl ExAtlas.Fly.TokenStorage
    def child_spec(_opts),
      do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}, type: :worker}

    def start_link, do: :ignore

    @impl ExAtlas.Fly.TokenStorage
    def get(app, key), do: lookup(cached_table(), manual_table(), app, key)

    @impl ExAtlas.Fly.TokenStorage
    def put(app, key, record) do
      GenServer.call(process_name(), {:put, table_for(key), app, record})
    end

    @impl ExAtlas.Fly.TokenStorage
    def delete(app, key) do
      GenServer.call(process_name(), {:delete, table_for(key), app})
    end

    defp lookup(cached, _manual, app, :cached), do: lookup_table(cached, app)
    defp lookup(_cached, manual, app, :manual), do: lookup_table(manual, app)

    defp lookup_table(table, app) do
      case :dets.lookup(table, app) do
        [{^app, token, expires_at}] -> {:ok, %{token: token, expires_at: expires_at}}
        _ -> :error
      end
    rescue
      ArgumentError -> :error
    end

    defp table_for(:cached), do: cached_table()
    defp table_for(:manual), do: manual_table()

    defp process_name, do: Process.get(:dets_proxy_process_name)
    defp cached_table, do: Process.get(:dets_proxy_cached_table)
    defp manual_table, do: Process.get(:dets_proxy_manual_table)
  end

  @doc false
  def __setup_dets__ do
    unique = System.unique_integer([:positive])

    storage_dir = Path.expand(Path.join(@tmp_root, "#{unique}"))
    File.rm_rf!(storage_dir)
    File.mkdir_p!(storage_dir)

    process_name = :"dets_conformance_#{unique}"
    cached_table = :"dets_conformance_cached_#{unique}"
    manual_table = :"dets_conformance_manual_#{unique}"

    Process.put(:dets_proxy_process_name, process_name)
    Process.put(:dets_proxy_cached_table, cached_table)
    Process.put(:dets_proxy_manual_table, manual_table)

    {:ok, pid} =
      Dets.start_link(
        name: process_name,
        storage_path: storage_dir,
        cached_table: cached_table,
        manual_table: manual_table
      )

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(storage_dir)
    end)

    :ok
  end
end
