defmodule ExAtlas.Orchestrator.AdopterEndpointTest do
  @moduledoc """
  Where an adopted task's provider calls go (issue 125).

  Whoever can write the tracking store (the DETS file, or a row in the host's
  database) writes the record the next boot adopts. The adopted task calls its
  provider with this node's API key, so the endpoint of those calls must come
  from the node's config, never from the record.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ExAtlas.Orchestrator
  alias ExAtlas.Orchestrator.{Adopter, TrackingStore}
  alias ExAtlas.Test.Orchestrator, as: TestOrchestrator
  alias ExAtlas.Test.Repo

  @moduletag :tmp_dir

  @node_key "node-key-5c1f"
  @pod_id "pod-forged"
  # The records here are unsigned, so they adopt only a pod named as this
  # node's Reaper would delete it (issue 138): with the prefix, and with the
  # owner "m1" that some tests set.
  @pod_name "atlas-m1-forged"

  # Exports `capabilities/0`, which `ExAtlas.Config.provider_module/1` takes,
  # and declares no `ExAtlas.Provider`.
  defmodule NotAProvider do
    @moduledoc false
    def capabilities, do: []

    def get_compute(_id, _ctx) do
      send(:adopter_endpoint_test, :not_a_provider_called)
      {:error, ExAtlas.Error.new(:not_found)}
    end
  end

  setup do
    Process.register(self(), :adopter_endpoint_test)
    configured = Bypass.open()
    forged = Bypass.open()

    previous = Application.get_env(:ex_atlas, :runpod)
    Application.put_env(:ex_atlas, :runpod, api_key: @node_key, base_url: url(configured))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ex_atlas, :runpod, previous),
        else: Application.delete_env(:ex_atlas, :runpod)
    end)

    serve(configured, :configured)
    serve(forged, :forged)

    {:ok, configured: configured, forged: forged}
  end

  defp url(bypass), do: "http://localhost:#{bypass.port}"

  # Answers RunPod's status read and delete for the pod, and reports each
  # request, with the key it carried, to the test.
  defp serve(bypass, label) do
    test_pid = self()

    for method <- ["GET", "DELETE"] do
      Bypass.stub(bypass, method, "/pods/#{@pod_id}", fn conn ->
        auth = conn |> Plug.Conn.get_req_header("authorization") |> List.first()
        send(test_pid, {label, conn.method, auth})

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          200,
          ~s({"id": "#{@pod_id}", "name": "#{@pod_name}", "desiredStatus": "RUNNING"})
        )
      end)
    end
  end

  # A record as any writer of the store can lay it down: existing atoms only,
  # no function, so DETS and the Ecto store's `[:safe]` decode both take it.
  defp record(overrides \\ %{}) do
    {opts, overrides} = Map.pop(overrides, :opts, [])

    Map.merge(
      %{
        v: TrackingStore.version(),
        owner: nil,
        id: @pod_id,
        provider: :runpod,
        opts:
          Keyword.merge(
            [provider: :runpod, gpu: :h100, image: "x", mode: :task, persist: true],
            opts
          ),
        spawned_at_ms: System.system_time(:millisecond),
        max_runtime_ms: false,
        respawns: 0,
        respawning: nil,
        callback_task_id: nil,
        report: nil,
        mode: :task,
        user_id: nil,
        max_cost: false,
        spent_usd: 0.0,
        cost_rate: nil,
        cost_since_ms: nil
      },
      overrides
    )
  end

  defp start_dets!(dir) do
    TestOrchestrator.start!(tracking_store: {TrackingStore.Dets, [storage_path: dir]})
    TrackingStore.Dets
  end

  defp start_ecto!(dir) do
    Repo.start!(dir)
    TestOrchestrator.start!(tracking_store: TrackingStore.Ecto)
    TrackingStore.Ecto
  end

  # What a writer of the host's database leaves, bypassing the app.
  defp insert_row!(record) do
    now = DateTime.to_iso8601(DateTime.utc_now())

    Repo.query!(
      "INSERT INTO atlas_tracking_records (id, owner, record, inserted_at, updated_at) " <>
        "VALUES (?1, NULL, ?2, ?3, ?3)",
      [record.id, {:blob, :erlang.term_to_binary(record)}, now]
    )
  end

  defp adopt! do
    log = capture_log(fn -> :ok = Adopter.run(notify: self()) end)
    assert_receive :adoption_complete, 2_000
    log
  end

  # Adoption reads the pod once, and the adopted tracker polls at once.
  defp assert_adopted_against_configured do
    assert_receive {:configured, "GET", "Bearer " <> @node_key}, 2_000
    assert_receive {:configured, "GET", "Bearer " <> @node_key}, 2_000
    assert @pod_id in Orchestrator.list_ids()
    refute_received {:forged, _method, _auth}
  end

  describe "a forged record's base_url" do
    test "in a DETS file: every call goes to the configured host", %{
      tmp_dir: dir,
      forged: forged
    } do
      store = start_dets!(dir)
      :ok = store.put(record(%{opts: [base_url: url(forged)]}))

      adopt!()

      assert_adopted_against_configured()
    end

    test "in an Ecto row: every call goes to the configured host", %{
      tmp_dir: dir,
      forged: forged
    } do
      start_ecto!(dir)
      insert_row!(record(%{opts: [base_url: url(forged)]}))

      adopt!()

      assert_adopted_against_configured()
    end

    test "inside req_options: every call goes to the configured host", %{
      tmp_dir: dir,
      forged: forged
    } do
      start_ecto!(dir)
      insert_row!(record(%{opts: [req_options: [base_url: url(forged)]]}))

      adopt!()

      assert_adopted_against_configured()
    end

    # A key of the writer's own account would point every call, and a
    # respawn's rent, at that account (review finding on PR 130).
    test "beside a forged api_key: every call carries the node's key", %{tmp_dir: dir} do
      store = start_ecto!(dir)
      TestOrchestrator.put_env(reap_owner: "m1")
      insert_row!(record(%{opts: [api_key: "attacker-key-0b7e"]}))

      adopt!()

      assert_adopted_against_configured()
      assert {:ok, %{opts: opts}} = store.get(@pod_id)
      refute Keyword.has_key?(opts, :api_key)
    end

    test "the delete at a spent deadline goes to the configured host", %{
      tmp_dir: dir,
      forged: forged
    } do
      start_ecto!(dir)

      insert_row!(
        record(%{
          opts: [base_url: url(forged), max_runtime_ms: 60_000],
          max_runtime_ms: 60_000,
          spawned_at_ms: System.system_time(:millisecond) - 60 * 60 * 1_000
        })
      )

      adopt!()

      assert_receive {:configured, "DELETE", "Bearer " <> @node_key}, 2_000
      refute_received {:forged, _method, _auth}
    end

    test "is named in a warning, its value is not", %{tmp_dir: dir, forged: forged} do
      start_ecto!(dir)
      insert_row!(record(%{opts: [base_url: url(forged), req_options: [retry: false]]}))

      log = adopt!()

      assert log =~ @pod_id
      assert log =~ ":base_url"
      assert log =~ ":req_options"
      refute log =~ url(forged)
    end

    test "is dropped from the record when a node claims it", %{tmp_dir: dir, forged: forged} do
      store = start_ecto!(dir)
      TestOrchestrator.put_env(reap_owner: "m1")
      insert_row!(record(%{opts: [base_url: url(forged), req_options: [retry: false]]}))

      adopt!()

      assert {:ok, %{owner: "m1", opts: opts}} = store.get(@pod_id)
      refute Keyword.has_key?(opts, :base_url)
      refute Keyword.has_key?(opts, :req_options)
      # Control: the claim kept the rest of the opts.
      assert opts[:image] == "x"
    end
  end

  describe "a record from 0.8.0 with no forged endpoint" do
    test "without the keys, adopts against the configured host", %{tmp_dir: dir} do
      start_ecto!(dir)
      insert_row!(record())

      adopt!()

      assert_adopted_against_configured()
    end

    test "with the keys nil, adopts against the configured host", %{tmp_dir: dir} do
      start_ecto!(dir)
      insert_row!(record(%{opts: [base_url: nil, req_options: nil]}))

      adopt!()

      assert_adopted_against_configured()
    end
  end

  describe "a fresh spawn (control)" do
    test "uses its per-call base_url, not the configured one", %{tmp_dir: dir} do
      start_dets!(dir)
      per_call = Bypass.open()
      test_pid = self()

      Bypass.expect_once(per_call, "POST", "/pods", fn conn ->
        send(test_pid, {:per_call, "POST"})

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(201, ~s({"id": "pod-fresh", "desiredStatus": "RUNNING"}))
      end)

      Bypass.stub(per_call, "DELETE", "/pods/pod-fresh", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      {:ok, _pid, _compute} =
        Orchestrator.spawn(
          provider: :runpod,
          base_url: url(per_call),
          gpu: :h100,
          image: "x",
          mode: :task,
          max_runtime_ms: 60_000,
          status_poll_ms: false,
          persist: true
        )

      assert_received {:per_call, "POST"}
      refute_received {:configured, _method, _auth}
    end
  end

  describe "a record's provider" do
    test "that declares no ExAtlas.Provider is not adopted, and its record is kept", %{
      tmp_dir: dir
    } do
      store = start_ecto!(dir)
      insert_row!(record(%{provider: NotAProvider, opts: [provider: NotAProvider]}))

      log = adopt!()

      refute_received :not_a_provider_called
      assert log =~ "not adopting #{@pod_id}"
      assert {:ok, _record} = store.get(@pod_id)
      assert Orchestrator.list_ids() == []
    end

    # The opts' provider wins over the record's, as it did before the gate: a
    # host store may keep the record's as a string.
    test "named in the opts and declaring no ExAtlas.Provider is not called either", %{
      tmp_dir: dir
    } do
      store = start_ecto!(dir)
      insert_row!(record(%{opts: [provider: NotAProvider]}))

      log = adopt!()

      refute_received :not_a_provider_called
      assert log =~ "not adopting #{@pod_id}"
      assert {:ok, _record} = store.get(@pod_id)
    end

    test "control: a provider module that declares ExAtlas.Provider is adopted", %{
      tmp_dir: dir
    } do
      store = start_ecto!(dir)
      # The record is unsigned, so its provider must be one the Reaper covers.
      TestOrchestrator.put_env(reap_providers: [:mock])

      {:ok, compute} =
        ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x", name: @pod_name)

      :ok =
        store.put(
          record(%{
            id: compute.id,
            provider: ExAtlas.Providers.Mock,
            opts: [provider: ExAtlas.Providers.Mock]
          })
        )

      adopt!()

      assert compute.id in Orchestrator.list_ids()
    end
  end
end
