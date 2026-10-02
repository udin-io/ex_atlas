defmodule ExAtlas.Orchestrator.TrackingStoreConformance do
  @moduledoc """
  Shared ExUnit suite every `ExAtlas.Orchestrator.TrackingStore` implementation
  must pass.

  Covers the `put/1` / `get/1` / `delete/1` / `all/0` contract, including the
  parts an adopting boot depends on: a record survives round-tripping with
  every field intact, `all/0` enumerates exactly what is stored, and `all/0`
  answers `{:ok, records}` on a store that can account for its contents.

  A host that writes its own store `use`s this suite in a test module, which
  must `use ExUnit.Case` first. The suite's tests expand there; this module
  calls no ExUnit function itself, so it compiles in a host's prod build.
  ExAtlas runs it against the DETS and Ecto stores.

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
  # A full current record for `id`. Outside the quote block, which credo
  # limits in length.
  def record(id, overrides \\ %{}) do
    %{
      v: 3,
      id: id,
      owner: "a",
      provider: :mock,
      opts: [gpu: :h100, image: "trainer:latest", mode: :task],
      spawned_at_ms: 1_700_000_000_000,
      max_runtime_ms: 90 * 60 * 1_000,
      respawns: 0,
      respawning: nil,
      callback_task_id: "task-" <> id,
      report: nil,
      mode: :task,
      user_id: nil,
      max_cost: 2.5,
      spent_usd: 0.75,
      cost_rate: 1.5,
      cost_since_ms: 1_700_000_600_000
    }
    |> Map.merge(overrides)
  end

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

      defp conformance_record(id, overrides \\ %{}),
        do: ExAtlas.Orchestrator.TrackingStoreConformance.record(id, overrides)

      describe "conformance: put/1, get/1, delete/1" do
        test "get/1 on empty storage returns :error" do
          assert :error = @store.get("never-stored")
        end

        test "put/1 then get/1 round-trips every field" do
          record = conformance_record("compute-a")
          assert :ok = @store.put(record)

          assert {:ok, ^record} = @store.get("compute-a")
        end

        # An adopted task respawns only from a record whose `:mac` checks,
        # over every field (issue 131). Every byte value, so a store that
        # keeps it as text fails here, not at a respawn.
        test "put/1 round-trips the node's signature, byte for byte" do
          record =
            Map.put(
              conformance_record("compute-signed"),
              :mac,
              :binary.list_to_bin(Enum.to_list(0..255))
            )

          assert :ok = @store.put(record)

          assert {:ok, ^record} = @store.get("compute-signed")
        end

        test "put/1 round-trips the owner, including none" do
          :ok = @store.put(conformance_record("compute-o1", %{owner: "b"}))
          :ok = @store.put(conformance_record("compute-o2", %{owner: nil}))

          assert {:ok, %{owner: "b"}} = @store.get("compute-o1")
          assert {:ok, %{owner: nil}} = @store.get("compute-o2")
        end

        # A respawn writes the attempt it starts before it rents. A store that
        # drops it adopts a task interrupted mid-respawn as if it never started
        # one, and the orphan's reports pass (risk 51).
        test "put/1 round-trips a respawn in progress, including none" do
          :ok = @store.put(conformance_record("compute-r1", %{respawns: 1, respawning: 2}))
          :ok = @store.put(conformance_record("compute-r2"))

          assert {:ok, %{respawns: 1, respawning: 2}} = @store.get("compute-r1")
          assert {:ok, %{respawning: nil}} = @store.get("compute-r2")
        end

        test "put/1 round-trips the cost fields, including no cap" do
          :ok = @store.put(conformance_record("compute-m1"))

          :ok =
            @store.put(
              conformance_record("compute-m2", %{
                max_cost: false,
                spent_usd: 0.0,
                cost_rate: nil,
                cost_since_ms: nil
              })
            )

          assert {:ok,
                  %{
                    max_cost: 2.5,
                    spent_usd: 0.75,
                    cost_rate: 1.5,
                    cost_since_ms: 1_700_000_600_000
                  }} =
                   @store.get("compute-m1")

          assert {:ok, %{max_cost: false, spent_usd: +0.0, cost_rate: nil, cost_since_ms: nil}} =
                   @store.get("compute-m2")
        end

        # `ExAtlas.Spec.Staging.scrub/1` writes this inside `opts`. A store
        # that drops the nested map loses where the task's data lives.
        test "put/1 round-trips a scrubbed s3: inside opts" do
          s3 = %{
            endpoint: "https://t3.storage.dev",
            region: "auto",
            dataset_uri: "s3://bucket/datasets/abc/",
            artifact_uri: "s3://bucket/artifacts/run-123/",
            credentials: :not_stored
          }

          record = conformance_record("compute-s3", %{opts: [gpu: :h100, mode: :task, s3: s3]})
          :ok = @store.put(record)

          assert {:ok, ^record} = @store.get("compute-s3")
        end

        # `ExAtlas.Orchestrator.TrackingStore.scrub_opts/1` writes env names
        # with `:not_stored`, or the bare marker. A store that drops either
        # lets an adopted respawn run with no environment.
        test "put/1 round-trips a scrubbed env: inside opts" do
          for {id, env} <- [
                {"compute-env", %{"HF_TOKEN" => :not_stored, "WANDB_PROJECT" => :not_stored}},
                {"compute-env-bare", :not_stored},
                {"compute-env-empty", %{}}
              ] do
            record = conformance_record(id, %{opts: [gpu: :h100, mode: :task, env: env]})
            :ok = @store.put(record)

            assert {:ok, ^record} = @store.get(id)
          end
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
