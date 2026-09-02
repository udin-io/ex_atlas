defmodule ExAtlas.Orchestrator.TrackingStoreConformance do
  @moduledoc """
  Shared ExUnit suite every `ExAtlas.Orchestrator.TrackingStore` implementation
  must pass.

  Covers the `put/1` / `get/1` / `delete/1` / `all/0` contract, including the
  parts an adopting boot depends on: a record survives round-tripping with
  every field intact, `all/0` enumerates exactly what is stored, and `all/0`
  answers `{:ok, records}` on a store that can account for its contents.

  A host swapping in a Postgres- or Redis-backed store can `use` this suite to
  inherit parity tests for free — the behaviour, not the DETS default, is the
  contract this feature ships.

  ## Usage

      defmodule MyApp.AtlasStoreTest do
        use ExUnit.Case, async: false

        use ExAtlas.Orchestrator.TrackingStoreConformance,
          store: MyApp.AtlasStore,
          setup: {__MODULE__, :start, []}
      end

  ### Options

    * `:store` (required) — the module implementing
      `ExAtlas.Orchestrator.TrackingStore`.
    * `:setup` — `{mod, fun, args}` called from the suite's `setup` block with
      the ExUnit context appended to `args`, so an implementation backed by the
      filesystem can isolate itself with `@moduletag :tmp_dir`. Use it to
      `start_supervised!/1` the implementation. Defaults to a no-op.
  """

  @doc false
  def build_setup_call(nil), do: quote(do: _ = var!(context))

  def build_setup_call({:{}, _, [mod, fun, args]}) do
    quote do: apply(unquote(mod), unquote(fun), unquote(args) ++ [var!(context)])
  end

  def build_setup_call({mod, fun, args})
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    quote do: apply(unquote(mod), unquote(fun), unquote(args) ++ [var!(context)])
  end

  defmacro __using__(opts) do
    store = Keyword.fetch!(opts, :store)
    setup_call = build_setup_call(Keyword.get(opts, :setup))

    quote do
      @store unquote(store)

      setup var!(context) do
        unquote(setup_call)
        :ok
      end

      defp conformance_record(id, overrides \\ %{}) do
        %{
          v: 1,
          id: id,
          provider: :mock,
          opts: [gpu: :h100, image: "trainer:latest", mode: :task],
          spawned_at_ms: 1_700_000_000_000,
          max_runtime_ms: 90 * 60 * 1_000,
          respawns: 0,
          callback_task_id: "task-" <> id,
          report: nil,
          mode: :task,
          user_id: nil
        }
        |> Map.merge(overrides)
      end

      describe "conformance: put/1, get/1, delete/1" do
        test "get/1 on empty storage returns :error" do
          assert :error = @store.get("never-stored")
        end

        test "put/1 then get/1 round-trips every field" do
          record = conformance_record("compute-a")
          assert :ok = @store.put(record)

          assert {:ok, ^record} = @store.get("compute-a")
        end

        test "put/1 overwrites the record for an id" do
          :ok = @store.put(conformance_record("compute-b"))
          :ok = @store.put(conformance_record("compute-b", %{respawns: 3}))

          assert {:ok, %{respawns: 3}} = @store.get("compute-b")
        end

        test "put/1 round-trips a landed report" do
          :ok = @store.put(conformance_record("compute-r", %{report: %{exit_code: 0}}))

          assert {:ok, %{report: %{exit_code: 0}}} = @store.get("compute-r")
        end

        test "delete/1 removes the record" do
          :ok = @store.put(conformance_record("compute-c"))
          :ok = @store.delete("compute-c")

          assert :error = @store.get("compute-c")
        end

        test "delete/1 is a no-op on an absent id" do
          assert :ok = @store.delete("never-stored")
        end
      end

      describe "conformance: all/0" do
        test "returns {:ok, []} on empty storage" do
          assert {:ok, []} = @store.all()
        end

        test "enumerates every stored record" do
          :ok = @store.put(conformance_record("compute-d"))
          :ok = @store.put(conformance_record("compute-e"))

          assert {:ok, records} = @store.all()
          assert Enum.sort(Enum.map(records, & &1.id)) == ["compute-d", "compute-e"]
        end

        test "reflects deletes" do
          :ok = @store.put(conformance_record("compute-f"))
          :ok = @store.put(conformance_record("compute-g"))
          :ok = @store.delete("compute-f")

          assert {:ok, [%{id: "compute-g"}]} = @store.all()
        end
      end
    end
  end
end
