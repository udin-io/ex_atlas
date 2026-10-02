defmodule ExAtlas.Orchestrator.ComputeServerTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [put_req_header: 3]

  alias ExAtlas.Callback
  alias ExAtlas.Callback.Token
  alias ExAtlas.Orchestrator.{ComputeServer, ComputeSupervisor, Events}
  alias ExAtlas.Providers.Mock
  alias ExAtlas.Spec.ComputeRequest
  alias ExAtlas.Test.FaultyProvider

  setup do: ExAtlas.Test.Orchestrator.start!()

  # The Mock without `compute_spend/3`, so `ExAtlas.compute_spend/2` answers
  # `:unsupported` the way it does for a provider with no billing API.
  defmodule NoBillingProvider do
    @behaviour ExAtlas.Provider

    alias ExAtlas.Providers.Mock

    @impl true
    defdelegate spawn_compute(req, ctx), to: Mock
    @impl true
    defdelegate get_compute(id, ctx), to: Mock
    @impl true
    defdelegate list_compute(filters, ctx), to: Mock
    @impl true
    defdelegate stop(id, ctx), to: Mock
    @impl true
    defdelegate start(id, ctx), to: Mock
    @impl true
    defdelegate terminate(id, ctx), to: Mock
    @impl true
    defdelegate run_job(req, ctx), to: Mock
    @impl true
    defdelegate get_job(id, ctx), to: Mock
    @impl true
    defdelegate cancel_job(id, ctx), to: Mock
    @impl true
    defdelegate stream_job(id, ctx), to: Mock
    @impl true
    defdelegate list_gpu_types(ctx), to: Mock
    @impl true
    def capabilities, do: Mock.capabilities() -- [:billing]
  end

  test "spawn → touch → terminate teardown calls provider terminate" do
    {:ok, pid, compute} =
      ExAtlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000
      )

    assert Process.alive?(pid)
    assert {:ok, _} = ExAtlas.Orchestrator.info(compute.id)
    :ok = ExAtlas.Orchestrator.touch(compute.id)

    ref = Process.monitor(pid)
    :ok = ExAtlas.Orchestrator.stop_tracked(compute.id)

    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

    # Upstream terminate was called
    {:ok, gone} = ExAtlas.get_compute(compute.id, provider: :mock)
    assert gone.status == :terminated
  end

  test "stop_tracked/1 ends the tracker with its own reason, not a node stop's" do
    {:ok, _pid, compute} =
      ExAtlas.Orchestrator.spawn(provider: :mock, gpu: :h100, image: "x", status_poll_ms: false)

    id = compute.id
    Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

    :ok = ExAtlas.Orchestrator.stop_tracked(id)

    assert_receive {:atlas_compute, ^id, {:terminating, {:shutdown, :stopped}}}, 2_000
  end

  test "a crash log shows the tracker's state without its secrets" do
    key = "sk-crash-log-must-not-show"

    {:ok, pid, compute} =
      ExAtlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        status_poll_ms: false,
        api_key: key,
        auth: :bearer,
        req_options: [auth: {:bearer, key}]
      )

    log = ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(pid, :boom) end)

    # The state was logged at all, so the refutes below are not vacuous.
    assert log =~ "terminating"
    assert log =~ compute.id
    refute log =~ key
    assert is_binary(compute.auth.token)
    refute log =~ compute.auth.token
  end

  test "idle timeout triggers termination" do
    if Code.ensure_loaded?(Phoenix.PubSub),
      do: Phoenix.PubSub.subscribe(ExAtlas.PubSub, "compute:")

    {:ok, pid, compute} =
      ExAtlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 10,
        heartbeat_ms: 10
      )

    if Code.ensure_loaded?(Phoenix.PubSub),
      do: Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    {:ok, gone} = ExAtlas.get_compute(compute.id, provider: :mock)
    assert gone.status == :terminated
  end

  test "touch resets the idle timer" do
    {:ok, pid, compute} =
      ExAtlas.Orchestrator.spawn(
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 200,
        heartbeat_ms: 50
      )

    _ref = Process.monitor(pid)

    # Keep touching faster than the idle ttl — server must stay alive
    Enum.each(1..4, fn _ ->
      Process.sleep(50)
      :ok = ExAtlas.Orchestrator.touch(compute.id)
    end)

    assert Process.alive?(pid)

    # Now stop touching — should die
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
  end

  describe "a crash report of the tracker" do
    test "holds no s3: credential and still holds the compute id" do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "x",
          status_poll_ms: false,
          s3: %{
            access_key_id: "tid-test-4b1e",
            secret_access_key: "tsec-test-9f2c",
            session_token: "tses-test-0d7a",
            dataset_uri: "s3://bucket/datasets/abc/",
            artifact_url: "https://bucket.s3.amazonaws.com/a.tar.gz?X-Amz-Signature=putsig-a7e3b2"
          }
        )

      text = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)

      assert text =~ compute.id
      refute text =~ "tid-test-4b1e"
      refute text =~ "tsec-test-9f2c"
      refute text =~ "tses-test-0d7a"
      refute text =~ "putsig-a7e3b2"
    end
  end

  describe "s3: credentials beyond the State line" do
    @s3 %{
      access_key_id: "tid-test-4b1e",
      secret_access_key: "tsec-test-9f2c",
      session_token: "tses-test-0d7a",
      dataset_uri: "s3://bucket/datasets/abc/",
      dataset_url: "https://bucket.s3.amazonaws.com/d.tar.gz?X-Amz-Signature=getsig-5d0c91",
      artifact_url: "https://bucket.s3.amazonaws.com/a.tar.gz?X-Amz-Signature=putsig-a7e3b2"
    }

    defp refute_s3_secrets(text) do
      for secret <- [
            "tid-test-4b1e",
            "tsec-test-9f2c",
            "tses-test-0d7a",
            "getsig-5d0c91",
            "putsig-a7e3b2"
          ],
          do: refute(text =~ secret)
    end

    test "a function clause crash prints no credential in its stacktrace" do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "x",
          status_poll_ms: false,
          s3: @s3
        )

      ref = Process.monitor(pid)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          catch_exit(GenServer.call(pid, {:not_a_call, 1}))
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
        end)

      # The crash and its stacktrace were logged, so the refutes are not vacuous.
      assert log =~ "terminating"
      assert log =~ "handle_call"
      assert log =~ compute.id
      refute_s3_secrets(log)
    end

    test "the provider ctx of a status poll holds no s3:" do
      ctx = ExAtlas.Config.build_ctx(:mock, s3: @s3, endpoint: "abc123")

      refute Map.has_key?(ctx, :s3)
      # Control: other pass-through options still reach the provider.
      assert ctx.endpoint == "abc123"
    end

    test "an invalid s3: is an error from spawn/1, before the provider is called" do
      assert {:error, %NimbleOptions.ValidationError{key: :s3, value: nil} = error} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x-s3-invalid",
                 s3: Map.delete(@s3, :secret_access_key)
               )

      refute_s3_secrets(inspect(error))
      {:ok, computes} = ExAtlas.list_compute(provider: :mock)
      refute Enum.any?(computes, &(&1.image == "x-s3-invalid"))
    end

    test "spawn_compute/2 refuses s3: in its provider opts" do
      req = ExAtlas.Spec.ComputeRequest.new!(gpu: :h100, image: "x")

      error =
        assert_raise ArgumentError, fn ->
          ExAtlas.spawn_compute(req, provider: :mock, s3: @s3)
        end

      assert Exception.message(error) =~ "ComputeRequest"
      refute_s3_secrets(Exception.message(error))
    end
  end

  describe "env: values beyond the State line" do
    @env_secret "hf-tracker-probe-6c2d"
    @env %{"HF_TOKEN" => @env_secret, "WANDB_API_KEY" => "wandb-tracker-probe-91fe"}

    defp refute_env_values(text) do
      refute text =~ @env_secret
      refute text =~ "wandb-tracker-probe-91fe"
    end

    defp env_crash_log(pid) do
      ref = Process.monitor(pid)

      ExUnit.CaptureLog.capture_log(fn ->
        catch_exit(GenServer.call(pid, {:not_a_call, 1}))
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      end)
    end

    test "a function clause crash prints the names and no value" do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "x",
          status_poll_ms: false,
          env: @env
        )

      log = env_crash_log(pid)

      # The stacktrace printed the opts, so the refutes are not vacuous.
      assert log =~ "handle_call"
      assert log =~ compute.id
      assert log =~ "HF_TOKEN"
      refute_env_values(log)
    end

    test "a run_task/1 tracker prints no value either" do
      {:ok, pid, _compute} =
        ExAtlas.Orchestrator.run_task(
          provider: :mock,
          gpu: :h100,
          image: "x",
          status_poll_ms: false,
          env: @env
        )

      log = env_crash_log(pid)

      assert log =~ "HF_TOKEN"
      refute_env_values(log)
    end

    test "a tracker started without Orchestrator.spawn/1 prints no value" do
      {:ok, compute} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      opts = [provider: :mock, env: @env, status_poll_ms: false]

      {:ok, pid} =
        DynamicSupervisor.start_child(ComputeSupervisor, {ComputeServer, {compute, opts}})

      log = env_crash_log(pid)

      assert log =~ "HF_TOKEN"
      refute_env_values(log)
    end

    test "a crash on stop and :sys.get_status/1 print no value" do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "x",
          status_poll_ms: false,
          env: @env
        )

      status = inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity)
      assert status =~ compute.id
      assert status =~ "HF_TOKEN"
      refute_env_values(status)

      log = ExUnit.CaptureLog.capture_log(fn -> GenServer.stop(pid, :boom) end)

      assert log =~ "terminating"
      assert log =~ compute.id
      refute_env_values(log)
    end

    test "an env: that is not a map is refused by name, before the provider is called" do
      for spawn <- [&ExAtlas.Orchestrator.spawn/1, &ExAtlas.Orchestrator.run_task/1] do
        assert {:error, %NimbleOptions.ValidationError{key: :env, value: nil} = error} =
                 spawn.(
                   provider: :mock,
                   gpu: :h100,
                   image: "x-env-invalid",
                   env: [{"HF_TOKEN", @env_secret}]
                 )

        refute_env_values(inspect(error))
        refute_env_values(Exception.message(error))
      end

      {:ok, computes} = ExAtlas.list_compute(provider: :mock)
      refute Enum.any?(computes, &(&1.image == "x-env-invalid"))
    end

    test "control: the pod still gets every value" do
      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "x",
          status_poll_ms: false,
          env: @env
        )

      assert ExAtlas.Spec.ComputeRequest.container_env(compute.raw.request) == @env
    end
  end

  # The Mock, but each status poll sends its ctx to the pid in
  # `:key_echo_pid`, so a test sees what a tracker hands the provider.
  defmodule KeyEchoProvider do
    alias ExAtlas.Providers.Mock

    def capabilities, do: Mock.capabilities()
    defdelegate spawn_compute(req, ctx), to: Mock
    defdelegate terminate(id, ctx), to: Mock

    def get_compute(id, ctx) do
      send(Application.fetch_env!(:ex_atlas, :key_echo_pid), {:poll_ctx, ctx})
      Mock.get_compute(id, ctx)
    end
  end

  # The Mock, but a status poll and a billing read reveal the key and then
  # crash in a frame that takes it: a provider bug after the HTTP client
  # read the key.
  defmodule RevealCrashProvider do
    alias ExAtlas.Providers.Mock

    def capabilities, do: Mock.capabilities()
    defdelegate spawn_compute(req, ctx), to: Mock
    defdelegate terminate(id, ctx), to: Mock

    def get_compute(_id, ctx), do: send_with(ExAtlas.Secret.reveal(ctx.api_key))
    def compute_spend(_id, _opts, ctx), do: send_with(ExAtlas.Secret.reveal(ctx.api_key))

    defp send_with(:never), do: :ok
  end

  describe "credentials beyond the State line" do
    @api_key "sk-tracker-probe-7a3e"

    # Crashes the tracker with a FunctionClauseError. OTP prints the
    # callback's arguments, the state included, outside `format_status/1`.
    defp clause_crash_log(pid) do
      ref = Process.monitor(pid)

      ExUnit.CaptureLog.capture_log(fn ->
        catch_exit(GenServer.call(pid, {:not_a_call, 1}))
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      end)
    end

    defp spawn_tracked(extra) do
      [provider: :mock, gpu: :h100, image: "x", status_poll_ms: false]
      |> Keyword.merge(extra)
      |> ExAtlas.Orchestrator.spawn()
    end

    test "a function clause crash prints no api_key" do
      {:ok, pid, compute} = spawn_tracked(api_key: @api_key)

      log = clause_crash_log(pid)

      # The crash and its stacktrace were logged, so the refute is not vacuous.
      # Only the stacktrace frame prints the sealed key; `format_status/1`
      # drops it from the State line.
      assert log =~ "terminating"
      assert log =~ "#ExAtlas.Secret<redacted>"
      assert log =~ compute.id
      refute log =~ @api_key
    end

    test "a tracker started without Orchestrator.spawn/1 prints no api_key either" do
      {:ok, compute} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      opts = [provider: :mock, api_key: @api_key, status_poll_ms: false]

      {:ok, pid} =
        DynamicSupervisor.start_child(ComputeSupervisor, {ComputeServer, {compute, opts}})

      log = clause_crash_log(pid)

      assert log =~ "#ExAtlas.Secret<redacted>"
      refute log =~ @api_key
    end

    test "a function clause crash prints no compute auth token" do
      {:ok, pid, compute} = spawn_tracked(auth: :bearer)
      assert is_binary(compute.auth.token)

      log = clause_crash_log(pid)

      assert log =~ "handle_call"
      assert log =~ compute.id
      refute log =~ compute.auth.token
    end

    test "a function clause crash prints no req_options :auth or :headers" do
      header_secret = "hdr-tracker-probe-2b9d"

      {:ok, pid, compute} =
        spawn_tracked(
          req_options: [auth: {:bearer, @api_key}, headers: [{"x-api-key", header_secret}]]
        )

      log = clause_crash_log(pid)

      assert log =~ "handle_call"
      assert log =~ compute.id
      refute log =~ @api_key
      refute log =~ header_secret
    end

    # Runs `fun` under capture_log and returns the log and the event `fun` got.
    defp crash_event(fun) do
      log = ExUnit.CaptureLog.capture_log(fn -> send(self(), {:event, fun.()}) end)
      assert_received {:event, event}
      {log, event}
    end

    test "a provider crash in a status poll prints no key in the log or the event" do
      {:ok, _pid, compute} =
        spawn_tracked(provider: RevealCrashProvider, api_key: @api_key, status_poll_ms: 20)

      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

      {log, reason} =
        crash_event(fn ->
          assert_receive {:atlas_compute, ^id, {:poll_failed, reason}}, 2_000
          reason
        end)

      # The task's crash was logged and reported, so the refutes are not vacuous.
      assert log =~ "send_with"
      assert inspect(reason) =~ "send_with"
      refute log =~ @api_key
      refute inspect(reason) =~ @api_key
      refute :erlang.term_to_binary(reason) =~ @api_key
    end

    test "a provider crash in a billing read prints no key in the log or the event" do
      {:ok, _pid, compute} =
        spawn_tracked(
          provider: RevealCrashProvider,
          api_key: @api_key,
          max_cost: 1,
          reconcile_spend_ms: 20,
          provider_opts: %{cost_per_hour: 0.36}
        )

      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

      {log, reason} =
        crash_event(fn ->
          assert_receive {:atlas_compute, ^id, {:spend_reconcile_failed, reason}}, 2_000
          reason
        end)

      assert log =~ "send_with"
      assert inspect(reason) =~ "send_with"
      refute log =~ @api_key
      refute inspect(reason) =~ @api_key
      refute :erlang.term_to_binary(reason) =~ @api_key
    end

    test "control: the tracker's polls still hand the per-call key to the provider" do
      Application.put_env(:ex_atlas, :key_echo_pid, self())
      on_exit(fn -> Application.delete_env(:ex_atlas, :key_echo_pid) end)

      {:ok, _pid, _compute} =
        spawn_tracked(provider: KeyEchoProvider, api_key: @api_key, status_poll_ms: 20)

      assert_receive {:poll_ctx, ctx}, 2_000
      assert reveal(ctx.api_key) == @api_key
    end

    defp reveal(%{__struct__: _} = secret), do: ExAtlas.Secret.reveal(secret)
    defp reveal(value), do: value
  end

  describe "upstream status polling" do
    setup do
      # Idle TTL and heartbeat are pushed far out so nothing but the status
      # poller can end these sessions.
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 30
      ]

      {:ok, base: base}
    end

    test "an upstream failure ends the session and reports the real cause", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.set_status(id, :failed)

      assert_receive {:atlas_compute, ^id, {:status, :failed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a pod that vanished upstream is not deleted again", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:status, :vanished}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # Nothing left to terminate, so no doomed DELETE and no failure event.
      refute_received {:atlas_compute, ^id, {:terminate_failed, _}}
      assert_received {:atlas_compute, ^id, {:status, :terminated}}
    end

    test "a preempted spot pod is reported as preempted", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base ++ [spot: true])
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:status, :preempted}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "upstream status changes are broadcast while the pod is alive", %{base: base} do
      {:ok, _pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id

      :ok = Mock.set_status(id, :provisioning)
      assert_receive {:atlas_compute, ^id, {:status, :provisioning}}, 2_000

      :ok = Mock.set_status(id, :running)
      assert_receive {:atlas_compute, ^id, {:status, :running}}, 2_000

      assert {:ok, %{compute: %{status: :running}}} = ExAtlas.Orchestrator.info(id)
    end

    test "a resource the provider reports as terminated is not deleted again" do
      base = [
        provider: FaultyProvider,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10
      ]

      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      # A provider that keeps terminated records still answers the poll with
      # the resource present — and refuses to delete it a second time.
      FaultyProvider.arm(:terminate, {:error, ExAtlas.Error.new(:not_found, provider: :mock)})
      :ok = Mock.set_status(id, :terminated)

      assert_receive {:atlas_compute, ^id, {:status, :terminated}}, 2_000
      assert_receive {:atlas_compute, ^id, {:terminating, :normal}}, 2_000

      # The end-of-session signal `ExAtlas.Orchestrator.Events` documents is
      # `{:terminating, _}` followed by `{:status, :terminated}`. A doomed
      # DELETE replaces the second half with `{:terminate_failed, _}`.
      assert_receive {:atlas_compute, ^id, {:status, :terminated}}, 2_000
      refute_received {:atlas_compute, ^id, {:terminate_failed, _}}
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "polling is off when :status_poll_ms is false", %{base: base} do
      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.spawn(Keyword.put(base, :status_poll_ms, false))

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id

      :ok = Mock.forget(id)

      refute_receive {:atlas_compute, ^id, {:status, _}}, 300
    end
  end

  describe "on_failure: {:respawn, max_attempts}" do
    setup do
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        spot: true,
        auth: :bearer,
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 30,
        on_failure: {:respawn, 1}
      ]

      {:ok, base: base}
    end

    test "a preempted pod is replaced and the session follows the new id", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(old_id)

      assert_receive {:atlas_compute, ^old_id, {:status, :preempted}}, 2_000
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000

      # The event carries an id, not the record: the replacement's auth handle
      # holds a live bearer token, which has no business on a PubSub topic.
      assert is_binary(new_id)
      refute new_id == old_id
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200

      # Re-keying happens before the broadcast, so the replacement — URL, token
      # and all — is readable the moment a subscriber sees the event.
      assert {:ok, %{compute: %{id: ^new_id, auth: %{token: token}}}} =
               ExAtlas.Orchestrator.info(new_id)

      assert is_binary(token)
      assert {:error, :not_tracked} = ExAtlas.Orchestrator.info(old_id)
      assert new_id in ExAtlas.Orchestrator.list_ids()
    end

    test "a replacement is spawned with the same s3: staging", %{base: base} do
      s3 = %{
        access_key_id: "tid-test-4b1e",
        secret_access_key: "tsec-test-9f2c",
        dataset_uri: "s3://bucket/datasets/abc/"
      }

      {:ok, _pid, compute} = ExAtlas.Orchestrator.spawn([s3: s3] ++ base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      # Control: the Mock records the staging it was asked for.
      assert %{dataset_uri: "s3://bucket/datasets/abc/"} = compute.raw.request.s3

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000

      assert {:ok, %{compute: replacement}} = ExAtlas.Orchestrator.info(new_id)

      assert %{
               "ATLAS_DATASET_URI" => "s3://bucket/datasets/abc/",
               "AWS_SECRET_ACCESS_KEY" => "tsec-test-9f2c"
             } =
               ExAtlas.Spec.Staging.env(replacement.raw.request.s3)
    end

    test "a persisted task respawned before any restart keeps its s3: credentials",
         %{base: base} do
      # The tracker still holds the full `s3:` in memory; only the record on
      # disk lacks the credentials.
      s3 = %{
        access_key_id: "tid-test-4b1e",
        secret_access_key: "tsec-test-9f2c",
        dataset_uri: "s3://bucket/datasets/abc/"
      }

      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.spawn([s3: s3, mode: :task, persist: true] ++ base)

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000

      assert {:ok, %{compute: replacement}} = ExAtlas.Orchestrator.info(new_id)

      assert %{
               "ATLAS_DATASET_URI" => "s3://bucket/datasets/abc/",
               "AWS_SECRET_ACCESS_KEY" => "tsec-test-9f2c"
             } = ExAtlas.Spec.Staging.env(replacement.raw.request.s3)
    end

    test "a respawn sends the env: values to the replacement", %{base: base} do
      env = %{"HF_TOKEN" => "hf-respawn-probe-07ab"}

      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.spawn([env: env, mode: :task, persist: true] ++ base)

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000

      assert {:ok, %{compute: replacement}} = ExAtlas.Orchestrator.info(new_id)
      assert ExAtlas.Spec.ComputeRequest.container_env(replacement.raw.request) == env
    end

    test "a preempted pod still present upstream is terminated, not abandoned", %{base: base} do
      {:ok, _pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      # A reclaimed spot pod reads as `desiredStatus: EXITED` — dead to us but
      # still present upstream, still billable, and invisible to the Reaper,
      # which only lists resources with `status: :running`. Every other respawn
      # test forgets the pod instead, which is the nil-upstream path.
      :ok = Mock.set_status(old_id, :stopped)

      assert_receive {:atlas_compute, ^old_id, {:status, :preempted}}, 2_000
      assert_receive {:atlas_compute, ^old_id, {:respawned, _new_id}}, 2_000

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(old_id, provider: :mock)
    end

    test "a replacement for a pod the provider forgot deletes nothing", %{base: base} do
      {:ok, _pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      :ok = Mock.forget(old_id)

      assert_receive {:atlas_compute, ^old_id, {:respawned, _new_id}}, 2_000
      refute_received {:atlas_compute, ^old_id, {:terminate_failed, _}}
    end

    test "the replacement is torn down with the session", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      :ok = Mock.forget(compute.id)

      assert_receive {:atlas_compute, _, {:respawned, new_id}}, 2_000

      ref = Process.monitor(pid)
      :ok = ExAtlas.Orchestrator.stop_tracked(new_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000

      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(new_id, provider: :mock)
    end

    test "the session ends once the respawn budget is spent", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      ref = Process.monitor(pid)

      :ok = Mock.forget(compute.id)
      assert_receive {:atlas_compute, _, {:respawned, new_id}}, 2_000

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))
      :ok = Mock.forget(new_id)

      assert_receive {:atlas_compute, ^new_id, {:status, :preempted}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a replacement that cannot be spawned ends the session", %{base: base} do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(Keyword.put(base, :provider, FaultyProvider))

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      error = ExAtlas.Error.new(:provider, provider: :mock, message: "no capacity")
      FaultyProvider.arm(:spawn_compute, {:error, error})
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:respawn_failed, {:preempted, ^error}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # A failed respawn must not leave a half-rented session behind.
      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "a crashed tracker is not restarted onto the resource it replaced", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      old_id = compute.id

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, _new_id}}, 2_000

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000

      # A restart replays the original `{compute, opts}` — the id that was
      # already replaced, and `respawns: 0`, so the budget resets and the
      # tracker polls a resource that no longer exists.
      _ = :sys.get_state(Process.whereis(ComputeSupervisor))

      assert %{active: 0} = DynamicSupervisor.count_children(ComputeSupervisor)
      assert {:error, :not_tracked} = ExAtlas.Orchestrator.info(old_id)
    end

    test "a crash-looping image is not respawned", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      # An image that failed on this host will fail on the next one too, so
      # there is nothing to recover by renting more capacity.
      :ok = Mock.set_status(id, :failed)

      assert_receive {:atlas_compute, ^id, {:status, :failed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "without on_failure a preempted pod just ends the session", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(Keyword.delete(base, :on_failure))
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:respawned, _}}
    end
  end

  describe "upstream status polling when the provider API is failing" do
    setup do
      bypass = Bypass.open()

      Bypass.expect(bypass, "POST", "/pods", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(201, ~s({"id": "pod_1", "desiredStatus": "RUNNING"}))
      end)

      Bypass.stub(bypass, "DELETE", "/pods/pod_1", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      opts = [
        provider: :runpod,
        api_key: "test-key",
        base_url: "http://localhost:#{bypass.port}",
        req_options: [retry: false],
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 30
      ]

      {:ok, bypass: bypass, opts: opts}
    end

    test "a failing provider is reported but never ends the session", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.stub(bypass, "GET", "/pods/pod_1", fn conn ->
        Plug.Conn.resp(conn, 500, ~s({"error": "boom"}))
      end)

      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(opts)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id, {:poll_failed, %ExAtlas.Error{status: 500}}}, 2_000
      assert_receive {:atlas_compute, ^id, {:poll_failed, %ExAtlas.Error{status: 500}}}, 2_000

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
    end

    test "polls back off while the provider keeps failing", %{bypass: bypass, opts: opts} do
      test_pid = self()

      Bypass.stub(bypass, "GET", "/pods/pod_1", fn conn ->
        send(test_pid, {:polled, System.monotonic_time(:millisecond)})
        Plug.Conn.resp(conn, 500, ~s({"error": "boom"}))
      end)

      {:ok, _pid, _compute} = ExAtlas.Orchestrator.spawn(opts)

      assert_receive {:polled, first}, 2_000
      assert_receive {:polled, second}, 2_000
      assert_receive {:polled, third}, 2_000

      # 30ms base doubling per failure: the third gap must exceed the first.
      assert third - second > second - first
    end
  end

  describe "option validation" do
    test "a non-positive :status_poll_ms is refused before anything is rented" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 status_poll_ms: 0
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "a stringly-typed :status_poll_ms is refused" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 status_poll_ms: "30000"
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    # A delay over 4,294,967,295 ms raises in `Process.send_after/3` on older
    # OTP releases (and over about 2^57 on OTP 27), after the pod is rented.
    @timer_opts [
      :heartbeat_ms,
      :status_poll_ms,
      :max_runtime_ms,
      :ready_timeout_ms,
      :finish_grace_ms
    ]

    test "a timer option past the longest portable timer is refused before renting" do
      for key <- @timer_opts do
        assert {:error, %NimbleOptions.ValidationError{key: ^key}} =
                 ExAtlas.Orchestrator.spawn(
                   [provider: :mock, gpu: :h100, image: "x", mode: :task] ++
                     [{key, 4_294_967_296}]
                 ),
               "#{key} accepted 4_294_967_296"
      end

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "a timer option at the longest portable timer starts a tracker" do
      for key <- @timer_opts do
        assert {:ok, pid, _compute} =
                 ExAtlas.Orchestrator.spawn(
                   [provider: :mock, gpu: :h100, image: "x", mode: :task] ++
                     [{key, 4_294_967_295}]
                 )

        assert Process.alive?(pid)
      end
    end

    test "`on_failure: :respawn` — the plausible typo — is refused" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 on_failure: :respawn
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "a tracker that cannot start takes its resource down with it" do
      stop_supervised!(ComputeSupervisor)

      start_supervised!(
        {DynamicSupervisor, name: ComputeSupervisor, strategy: :one_for_one, max_children: 0}
      )

      assert {:error, {:tracker_start_failed, :max_children}} =
               ExAtlas.Orchestrator.spawn(provider: :mock, gpu: :h100, image: "x")

      # Nothing tracks it, so it must not survive the failure.
      assert {:ok, [%{status: :terminated}]} = ExAtlas.list_compute(provider: :mock)
    end
  end

  # Hold a poll open, then assert the tracker still answers. The alternative —
  # a poll done inline in the callback — parks the mailbox for as long as the
  # provider takes (up to ~120s of Req retries).
  defp block_a_poll(base) do
    {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
    FaultyProvider.arm(:get_compute, {:block, self()})
    assert_receive {:blocked, :get_compute, _task}, 2_000
    {pid, compute}
  end

  describe "a poll that blows up" do
    setup do
      base = [
        provider: FaultyProvider,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10
      ]

      {:ok, base: base}
    end

    test "a raise is reported like any other failed poll", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(base)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      # `Client.fetch_key!/1` raises on a key that resolves to nil, and a
      # malformed body can still raise in a translator. Neither is evidence
      # that the resource died — but a raise in the callback would run
      # `terminate/2` and DELETE it.
      FaultyProvider.arm(:get_compute, :raise)

      assert_receive {:atlas_compute, ^id, {:poll_failed, _reason}}, 2_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a stray message cannot end the session", %{base: base} do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(Keyword.put(base, :status_poll_ms, false))
      ref = Process.monitor(pid)

      send(pid, :a_message_from_somewhere_else)

      # The call is handled after the stray message, so a reply proves the
      # server survived it.
      assert {:ok, _} = ExAtlas.Orchestrator.info(compute.id)
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end
  end

  describe "a poll the provider never answers" do
    setup do
      base = [
        provider: FaultyProvider,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10
      ]

      {:ok, base: base}
    end

    test "does not delay teardown, so the resource is still deleted", %{base: base} do
      {pid, compute} = block_a_poll(base)

      ref = Process.monitor(pid)
      :ok = ExAtlas.Orchestrator.stop_tracked(compute.id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(compute.id, provider: :mock)
    end

    test "does not delay info/1 or touch/1", %{base: base} do
      {_pid, compute} = block_a_poll(base)

      assert {:ok, before} = ExAtlas.Orchestrator.info(compute.id)
      assert :ok = ExAtlas.Orchestrator.touch(compute.id)
      assert {:ok, touched} = ExAtlas.Orchestrator.info(compute.id)
      assert touched.last_activity_ms >= before.last_activity_ms
    end
  end

  describe "task mode" do
    setup do
      # Idle TTL and heartbeat are set aggressively short on purpose: task mode
      # must ignore both, and an interactive server with these numbers would be
      # dead within a few tens of milliseconds.
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        command: ["/app/train.sh"],
        mode: :task,
        idle_ttl_ms: 10,
        heartbeat_ms: 10,
        status_poll_ms: 10,
        max_runtime_ms: 60_000
      ]

      {:ok, base: base}
    end

    defp start_task(base, overrides \\ []) do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(Keyword.merge(base, overrides))
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      {pid, compute}
    end

    test "the idle clock never runs — an unattended task outlives its idle ttl", %{base: base} do
      {pid, compute} = start_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      refute_receive {:atlas_compute, ^id, {:heartbeat, _}}, 200
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "touch/1 is meaningless but harmless in task mode", %{base: base} do
      {_pid, compute} = start_task(base)

      assert :ok = ExAtlas.Orchestrator.touch(compute.id)
      assert {:ok, %{mode: :task}} = ExAtlas.Orchestrator.info(compute.id)
    end

    test "a self-terminated container completes, and nothing is deleted twice", %{base: base} do
      {pid, compute} = start_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      # The self-termination wrapper DELETEs the pod from inside the container,
      # so the next poll 404s. That 404 is the only container-exit signal
      # RunPod's REST API can produce.
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, first}, 2_000
      assert_receive {:atlas_compute, ^id, second}, 2_000
      assert_receive {:atlas_compute, ^id, third}, 2_000
      assert_receive {:atlas_compute, ^id, fourth}, 2_000

      # The task outcome precedes the end-of-session pair, so a subscriber that
      # ignores {:task, _} still sees a correct lifecycle.
      assert [
               {:status, :vanished},
               {:task, :completed},
               {:terminating, _},
               {:status, :terminated}
             ] =
               [first, second, third, fourth]

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a container that never self-terminated is killed at the deadline", %{base: base} do
      # Covers both the crash-before-the-cleanup-line case and a hung process:
      # the pod stays desiredStatus RUNNING forever, so no observation will ever
      # end this task and only the wall clock can.
      {pid, compute} = start_task(base, max_runtime_ms: 50)
      id = compute.id
      ref = Process.monitor(pid)

      refute_receive {:atlas_compute, ^id, {:task, :completed}}, 0
      assert_receive {:atlas_compute, ^id, {:task, :timed_out}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # The meter is actually stopped, not just the tracker.
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a resource that never leaves provisioning fails as :never_ready", %{base: base} do
      {pid, compute} = start_task(base, ready_timeout_ms: 300)
      id = compute.id
      ref = Process.monitor(pid)

      # An image that will not pull: the pod is rented and billing, but no
      # container ever starts.
      :ok = Mock.set_status(id, :provisioning)
      assert_receive {:atlas_compute, ^id, {:status, :provisioning}}, 2_000

      assert_receive {:atlas_compute, ^id, {:task, {:failed, :never_ready}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a task that did become ready is never failed as :never_ready", %{base: base} do
      {pid, compute} = start_task(base, ready_timeout_ms: 50)
      id = compute.id
      ref = Process.monitor(pid)

      refute_receive {:atlas_compute, ^id, {:task, _}}, 300
      refute_received {:DOWN, ^ref, :process, ^pid, _}
    end

    test "a failed poll ends nothing — the task keeps running", %{base: base} do
      {pid, compute} =
        start_task(base, provider: FaultyProvider, status_poll_ms: 10)

      id = compute.id
      ref = Process.monitor(pid)

      FaultyProvider.arm(
        :get_compute,
        {:error, ExAtlas.Error.new(:provider, provider: :mock, status: 500)}
      )

      assert_receive {:atlas_compute, ^id, {:poll_failed, _}}, 2_000
      refute_receive {:atlas_compute, ^id, {:task, _}}, 200
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a preempted spot task with no respawn budget reports the cause", %{base: base} do
      {pid, compute} = start_task(base, spot: true)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, {:failed, :preempted}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "the deadline is wall clock from spawn and carries across a respawn", %{base: base} do
      # A caller who asked for 90 minutes must not be able to spend 360 by
      # being preempted three times, so the replacement inherits what is left
      # of the original budget rather than starting a fresh one.
      {_pid, compute} = start_task(base, spot: true, on_failure: {:respawn, 1})
      id = compute.id

      assert {:ok, %{max_runtime_remaining_ms: before_ms}} = ExAtlas.Orchestrator.info(id)

      :ok = Mock.forget(id)
      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000

      assert {:ok, %{max_runtime_remaining_ms: after_ms}} = ExAtlas.Orchestrator.info(new_id)

      # A re-armed deadline would have jumped back up to the full budget.
      assert after_ms < before_ms
    end

    test "an interactive session gets no task events at all" do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.spawn(
          provider: :mock,
          gpu: :h100,
          image: "x",
          idle_ttl_ms: 60_000,
          heartbeat_ms: 60_000,
          status_poll_ms: 10
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:status, :vanished}}, 2_000
      refute_receive {:atlas_compute, ^id, {:task, _}}, 200
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "an interactive session past max_runtime_ms terminates with no task event",
         %{base: base} do
      {pid, compute} =
        start_task(base,
          mode: :interactive,
          idle_ttl_ms: 60_000,
          heartbeat_ms: 60_000,
          max_runtime_ms: 50
        )

      id = compute.id
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id, {:terminating, :max_runtime}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:task, _}}
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "an interactive session stuck provisioning terminates :never_ready, no task event",
         %{base: base} do
      {pid, compute} =
        start_task(base,
          mode: :interactive,
          idle_ttl_ms: 60_000,
          heartbeat_ms: 60_000,
          ready_timeout_ms: 300
        )

      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.set_status(id, :provisioning)
      assert_receive {:atlas_compute, ^id, {:status, :provisioning}}, 2_000

      assert_receive {:atlas_compute, ^id, {:terminating, :never_ready}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:task, _}}
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end
  end

  describe "task option validation" do
    test "rejects a bad mode before renting anything" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(provider: :mock, gpu: :h100, image: "x", mode: :batch)

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "rejects a bad max_runtime_ms or ready_timeout_ms before renting anything" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 mode: :task,
                 max_runtime_ms: 0
               )

      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.spawn(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 mode: :task,
                 ready_timeout_ms: "10s"
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end
  end

  describe "run_task/1" do
    test "runs a command to completion and reports the outcome" do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.run_task(
          provider: :mock,
          gpu: :h100,
          image: "ghcr.io/acme/trainer:latest",
          command: ["/app/train.sh"],
          name: "atlas-task-42",
          status_poll_ms: 10,
          max_runtime_ms: 60_000
        )

      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      id = compute.id
      ref = Process.monitor(pid)

      assert {:ok, %{mode: :task}} = ExAtlas.Orchestrator.info(id)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "always has a deadline, even when the caller forgets to ask for one" do
      # An unattended task with no wall-clock cap is the billing trap this
      # whole feature exists to close, so the wrapper supplies one.
      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.run_task(
          provider: :mock,
          gpu: :h100,
          image: "x",
          command: ["/app/train.sh"],
          status_poll_ms: false
        )

      assert {:ok, info} = ExAtlas.Orchestrator.info(compute.id)
      assert is_integer(info.max_runtime_remaining_ms)
      assert info.max_runtime_remaining_ms > 0
    end

    test "validates its options before renting anything" do
      assert {:error, %NimbleOptions.ValidationError{}} =
               ExAtlas.Orchestrator.run_task(
                 provider: :mock,
                 gpu: :h100,
                 image: "x",
                 max_runtime_ms: -1
               )

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end
  end

  describe "pod callbacks" do
    setup do
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        command: ["/app/train.sh"],
        mode: :task,
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10,
        max_runtime_ms: 60_000,
        callback: "https://app.example.com/atlas/cb"
      ]

      {:ok, base: base}
    end

    defp start_reporting_task(base, overrides \\ []) do
      opts = Keyword.merge(base, overrides)
      {:ok, prepared} = Callback.prepare(opts)
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(prepared)
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      {pid, compute, prepared[:callback].task_id}
    end

    test "a progress report reaches subscribers on the compute topic", %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base)
      id = compute.id

      assert :ok = Callback.ingest(task_id, :progress, %{"seq" => 1, "pct" => 42})

      assert_receive {:atlas_compute, ^id, {:progress, %{"pct" => 42}}}, 2_000
    end

    test "a log batch reaches subscribers and is retained nowhere", %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base)
      id = compute.id

      assert :ok = Callback.ingest(task_id, :log, %{"lines" => ["epoch 1", "epoch 2"]})

      assert_receive {:atlas_compute, ^id, {:log, %{"lines" => ["epoch 1", "epoch 2"]}}}, 2_000

      # Nothing about the tracked state grew: the boundary is a bus, not a store.
      assert {:ok, info} = ExAtlas.Orchestrator.info(id)
      refute Map.has_key?(info, :logs)
    end

    test "progress does not postpone the idle clock", %{base: base} do
      # An authenticated but compromised pod must not be able to keep itself
      # alive against the idle TTL just by talking.
      {_pid, compute, task_id} = start_reporting_task(base, mode: :interactive)
      id = compute.id
      {:ok, %{last_activity_ms: before}} = ExAtlas.Orchestrator.info(id)

      :ok = Callback.ingest(task_id, :progress, %{"pct" => 1})
      assert_receive {:atlas_compute, ^id, {:progress, _}}, 2_000

      assert {:ok, %{last_activity_ms: ^before}} = ExAtlas.Orchestrator.info(id)
    end

    test "a finish report is announced the moment it lands", %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base)
      id = compute.id

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})

      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000
    end

    test "a clean exit followed by the pod vanishing completes, provably", %{base: base} do
      {pid, compute, task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a non-zero exit fails the task with the code the container reported", %{base: base} do
      {pid, compute, task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 3})
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 3}}}, 2_000
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, {:failed, {:exit_code, 3}}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a report from a pod that never vanishes finishes on the grace timer", %{base: base} do
      # self_terminate: false, a skipped trap, a DELETE that failed. Today this
      # can only ever end as :timed_out, an hour later.
      {pid, compute, task_id} = start_reporting_task(base, finish_grace_ms: 50)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # And the meter is actually stopped — terminate/2 issued the DELETE the
      # container's own trap evidently did not.
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "the grace window waits for the 404 rather than pre-empting it", %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base, finish_grace_ms: 60_000)
      id = compute.id

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000

      refute_receive {:atlas_compute, ^id, {:task, _}}, 200
    end

    test "a second finish report does not restart the grace window", %{base: base} do
      {pid, compute, task_id} = start_reporting_task(base, finish_grace_ms: 80)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000
      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 9})

      # First report wins: a replayed or retried finish cannot rewrite the
      # outcome, and cannot buy the pod another grace window either.
      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "the deadline stays authoritative when nothing ever calls back", %{base: base} do
      {pid, compute, _task_id} = start_reporting_task(base, max_runtime_ms: 50)
      id = compute.id
      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id, {:task, :timed_out}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a configured callback nobody uses behaves exactly like no callback", %{base: base} do
      {pid, compute, _task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a callback for a task that is not this one is ignored", %{base: base} do
      {pid, compute, _task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      assert {:error, :not_tracked} =
               Callback.ingest("some-other-task", :finish, %{"exit_code" => 1})

      refute_receive {:atlas_compute, ^id, {:task_report, _}}, 200
      refute_received {:DOWN, ^ref, :process, ^pid, _}
    end

    test "an interactive session with a self-terminating command ends on the report",
         %{base: base} do
      {pid, compute, task_id} =
        start_reporting_task(base, mode: :interactive, finish_grace_ms: 100)

      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000

      # The report says the command is over: activity does not buy more time.
      :ok = ExAtlas.Orchestrator.touch(id)

      assert_receive {:atlas_compute, ^id, {:terminating, :finished}}, 2_000
      assert_receive {:atlas_compute, ^id, {:terminating, :normal}}, 2_000
      assert_receive {:atlas_compute, ^id, {:status, :terminated}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:task, _}}
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "an interactive session ends on a non-zero exit report too", %{base: base} do
      {pid, compute, task_id} =
        start_reporting_task(base, mode: :interactive, finish_grace_ms: 50)

      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 3})

      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 3}}}, 2_000
      assert_receive {:atlas_compute, ^id, {:terminating, :finished}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:task, _}}
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "control: self_terminate: false keeps an interactive session up after the report",
         %{base: base} do
      {pid, compute, task_id} =
        start_reporting_task(base,
          mode: :interactive,
          self_terminate: false,
          finish_grace_ms: 50
        )

      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      refute_received {:atlas_compute, ^id, {:terminating, _}}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "control: an interactive session with no command stays up after a report",
         %{base: base} do
      {pid, compute, task_id} =
        start_reporting_task(Keyword.delete(base, :command),
          mode: :interactive,
          finish_grace_ms: 50
        )

      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      refute_received {:atlas_compute, ^id, {:terminating, _}}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    # `command: []` runs the image's own command, which nothing asked to end.
    test "control: an interactive session with command: [] stays up after a report",
         %{base: base} do
      {pid, compute, task_id} =
        start_reporting_task(base, command: [], mode: :interactive, finish_grace_ms: 50)

      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, %{exit_code: 0}}}, 2_000

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      refute_received {:atlas_compute, ^id, {:terminating, _}}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end
  end

  describe "callbacks and spot capacity" do
    setup do
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        command: ["/app/train.sh"],
        mode: :task,
        spot: true,
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: 10,
        max_runtime_ms: 60_000,
        on_failure: {:respawn, 1},
        callback: "https://app.example.com/atlas/cb"
      ]

      {:ok, base: base}
    end

    test "a task that reported finish is never respawned", %{base: base} do
      # The ambiguity #25 exists to kill: on spot capacity a 404 means both
      # "self-terminated fine" and "reclaimed", so respawn can re-run finished
      # work. A recorded report settles it.
      {pid, compute, task_id} = start_reporting_task(base)
      id = compute.id
      ref = Process.monitor(pid)

      :ok = Callback.ingest(task_id, :finish, %{"exit_code" => 0})
      assert_receive {:atlas_compute, ^id, {:task_report, _}}, 2_000
      :ok = Mock.forget(id)

      assert_receive {:atlas_compute, ^id, {:task, :completed}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:respawned, _}}
    end

    test "a genuine preemption with no report still respawns", %{base: base} do
      {pid, compute, _task_id} = start_reporting_task(base)
      old_id = compute.id
      ref = Process.monitor(pid)

      :ok = Mock.forget(old_id)

      assert_receive {:atlas_compute, ^old_id, {:respawned, _new_id}}, 2_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
    end

    test "the task id follows the replacement, so a respawned pod can still report",
         %{base: base} do
      {_pid, compute, task_id} = start_reporting_task(base)
      old_id = compute.id

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))

      # The credential is bound to the task, not to a compute id that no
      # longer exists, so the replacement reports under the same task id.
      assert :ok = Callback.ingest(task_id, :progress, %{"pct" => 50})

      assert_receive {:atlas_compute, ^new_id, {:progress, %{"pct" => 50}}}, 2_000
    end

    # The token each pod was rented with, read from the request its provider
    # received: what the container finds in `ATLAS_CALLBACK_TOKEN`.
    defp pod_token(%{raw: %{request: request}}),
      do: ComputeRequest.container_env(request)["ATLAS_CALLBACK_TOKEN"]

    defp post_report(path, token, body) do
      :post
      |> Plug.Test.conn(path, body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer " <> token)
      |> Callback.Plug.call([])
    end

    # Pod A is preempted and pod B replaces it. Returns both as the provider
    # rented them, and subscribes to B's topic.
    defp respawned_task(base) do
      {pid, pod_a, task_id} = start_reporting_task(base)
      old_id = pod_a.id

      :ok = Mock.forget(old_id)
      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))
      {:ok, pod_b} = Mock.get_compute(new_id, %{})

      {pid, pod_a, pod_b, task_id}
    end

    test "a finish from the pod a respawn replaced gets 410 and ends nothing",
         %{base: base} do
      {pid, pod_a, pod_b, _task_id} = respawned_task(base)
      new_id = pod_b.id
      ref = Process.monitor(pid)

      assert post_report("/finish", pod_token(pod_a), ~s({"exit_code":0})).status == 410

      refute_receive {:atlas_compute, ^new_id, {:task_report, _}}, 200
      refute_received {:atlas_compute, _, {:task, _}}
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{status: :running}} = Mock.get_compute(new_id, %{})
    end

    test "control: the replacement's own finish is accepted and ends the task on its code",
         %{base: base} do
      {pid, _pod_a, pod_b, _task_id} = respawned_task(base)
      new_id = pod_b.id
      ref = Process.monitor(pid)

      assert post_report("/finish", pod_token(pod_b), ~s({"exit_code":3})).status == 202
      assert_receive {:atlas_compute, ^new_id, {:task_report, %{exit_code: 3}}}, 2_000
      :ok = Mock.forget(new_id)

      assert_receive {:atlas_compute, ^new_id, {:task, {:failed, {:exit_code, 3}}}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "progress and logs from the replaced pod get 410 and reach no subscriber",
         %{base: base} do
      {_pid, pod_a, pod_b, _task_id} = respawned_task(base)
      new_id = pod_b.id

      assert post_report("/progress", pod_token(pod_a), ~s({"pct":99})).status == 410
      assert post_report("/logs", pod_token(pod_a), ~s({"lines":["stale"]})).status == 410

      refute_receive {:atlas_compute, ^new_id, {:progress, _}}, 200
      refute_received {:atlas_compute, ^new_id, {:log, _}}
    end

    test "control: progress and logs from the replacement reach subscribers",
         %{base: base} do
      {_pid, _pod_a, pod_b, _task_id} = respawned_task(base)
      new_id = pod_b.id

      assert post_report("/progress", pod_token(pod_b), ~s({"pct":50})).status == 202
      assert post_report("/logs", pod_token(pod_b), ~s({"lines":["fresh"]})).status == 202

      assert_receive {:atlas_compute, ^new_id, {:progress, %{"pct" => 50}}}, 2_000
      assert_receive {:atlas_compute, ^new_id, {:log, %{"lines" => ["fresh"]}}}, 2_000
    end

    # The report passes the Registry check before the tracker learns of the
    # preemption, and waits in its mailbox behind the poll that respawns.
    test "a finish from the replaced pod queued behind the respawn is dropped",
         %{base: base} do
      {pid, pod_a, _task_id} = start_reporting_task(base, provider: FaultyProvider)
      old_id = pod_a.id
      ref = Process.monitor(pid)

      FaultyProvider.arm(:get_compute, {:block, self()})
      assert_receive {:blocked, :get_compute, poller}, 2_000
      FaultyProvider.reset()
      :ok = Mock.forget(old_id)

      :sys.suspend(pid)
      send(poller, :release)
      await_mailbox(pid)

      assert post_report("/finish", pod_token(pod_a), ~s({"exit_code":0})).status == 202
      :sys.resume(pid)

      assert_receive {:atlas_compute, ^old_id, {:respawned, new_id}}, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))
      {:ok, pod_b} = Mock.get_compute(new_id, %{})

      assert post_report("/finish", pod_token(pod_b), ~s({"exit_code":3})).status == 202
      assert_receive {:atlas_compute, ^new_id, {:task_report, %{exit_code: 3}}}, 2_000
      refute_received {:atlas_compute, _, {:task, _}}
      refute_received {:DOWN, ^ref, :process, ^pid, _}
    end

    defp await_mailbox(pid, tries \\ 2_000) do
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} when n > 0 ->
          :ok

        _ when tries > 0 ->
          Process.sleep(1)
          await_mailbox(pid, tries - 1)
      end
    end

    # 0.8.0 minted no attempt, and a pod it rented may still be running. Its
    # report is accepted unchecked, even after a respawn: see #100.
    test "a token with no attempt, as 0.8.0 minted it, is still accepted after a respawn",
         %{base: base} do
      {_pid, _pod_a, pod_b, task_id} = respawned_task(base)
      new_id = pod_b.id
      token = Token.mint(task_id, Callback.kinds())

      assert post_report("/finish", token, ~s({"exit_code":0})).status == 202
      assert_receive {:atlas_compute, ^new_id, {:task_report, %{exit_code: 0}}}, 2_000
    end
  end

  describe "reconcile_spend_ms option validation" do
    test "an interval that is not a positive integer is refused before renting" do
      for bad <- [0, -1, "15", 1.5, 4_294_967_296] do
        assert {:error, %NimbleOptions.ValidationError{key: :reconcile_spend_ms}} =
                 ExAtlas.Orchestrator.spawn(
                   provider: :mock,
                   gpu: :h100,
                   image: "x",
                   max_cost: 1,
                   reconcile_spend_ms: bad
                 ),
               "reconcile_spend_ms accepted #{inspect(bad)}"
      end

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "false, the longest portable timer, and the 15-minute default are accepted" do
      for good <- [false, 1, 4_294_967_295] do
        assert {:ok, tracking} =
                 ComputeServer.validate_opts(max_cost: 1, reconcile_spend_ms: good)

        assert tracking[:reconcile_spend_ms] == good
      end

      assert {:ok, tracking} = ComputeServer.validate_opts(max_cost: 1)
      assert tracking[:reconcile_spend_ms] == :timer.minutes(15)
    end
  end

  describe "max_cost option validation" do
    test "a cap that is not a positive number is refused before anything is rented" do
      for bad <- [0, -1, "2.5"] do
        assert {:error, %NimbleOptions.ValidationError{key: :max_cost}} =
                 ExAtlas.Orchestrator.spawn(
                   provider: :mock,
                   gpu: :h100,
                   image: "x",
                   max_cost: bad
                 )
      end

      assert {:ok, []} = ExAtlas.list_compute(provider: :mock)
    end

    test "a persisted task is accepted with a cap and without one" do
      # The tracking record carries the spend, so an adopted task resumes its
      # budget instead of starting a fresh one.
      for max_cost <- [2.5, false] do
        assert {:ok, _tracking} =
                 ComputeServer.validate_opts(mode: :task, persist: true, max_cost: max_cost)
      end
    end
  end

  describe "max_cost" do
    # $1 per second, so a cap of a few cents fires in tens of milliseconds.
    @per_second 3600.0

    setup do
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: false,
        provider_opts: %{cost_per_hour: @per_second}
      ]

      {:ok, base: base}
    end

    defp spawn_capped(base, overrides) do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(Keyword.merge(base, overrides))
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      {pid, compute.id}
    end

    # Until a status poll has carried `rate` into the tracker's compute.
    defp await_tracked_rate(id, rate, tries \\ 400) do
      case ExAtlas.Orchestrator.info(id) do
        {:ok, %{compute: %{cost_per_hour: ^rate}}} ->
          :ok

        _ when tries > 0 ->
          Process.sleep(5)
          await_tracked_rate(id, rate, tries - 1)

        other ->
          flunk("no poll carried cost_per_hour #{inspect(rate)}: #{inspect(other)}")
      end
    end

    defp next_events(id, count) do
      for _ <- 1..count do
        assert_receive {:atlas_compute, ^id, event}, 2_000
        event
      end
    end

    test "an interactive session is deleted when its spend reaches the cap", %{base: base} do
      {pid, id} = spawn_capped(base, max_cost: 0.05)
      ref = Process.monitor(pid)

      assert [{:terminating, :cost_cap}, {:terminating, :normal}, {:status, :terminated}] =
               next_events(id, 3)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a task fails as :cost_cap before the end-of-session pair", %{base: base} do
      {:ok, pid, compute} =
        ExAtlas.Orchestrator.run_task(
          Keyword.merge(base, command: ["/app/train.sh"], max_cost: 0.05)
        )

      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))
      ref = Process.monitor(pid)

      assert [
               {:task, {:failed, :cost_cap}},
               {:terminating, :cost_cap},
               {:terminating, _},
               {:status, :terminated}
             ] = next_events(id, 4)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "info/1 reports the cap and a spend that grows", %{base: base} do
      {_pid, id} = spawn_capped(base, max_cost: 100)

      assert {:ok, %{max_cost: 100, spent_usd: first}} = ExAtlas.Orchestrator.info(id)
      Process.sleep(20)
      assert {:ok, %{spent_usd: second}} = ExAtlas.Orchestrator.info(id)

      assert is_float(first)
      assert second > first
    end

    test "a price that rises after spawn is charged from the next poll", %{base: base} do
      {pid, id} =
        spawn_capped(base,
          max_cost: 0.05,
          status_poll_ms: 10,
          provider_opts: %{cost_per_hour: 0.0}
        )

      ref = Process.monitor(pid)

      refute_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 100

      :ok = Mock.set_cost_per_hour(id, @per_second)

      assert_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a price that drops to zero before the cap cancels the armed timer", %{base: base} do
      # Armed at $1/s for 500 ms; the poll lands within a few tens of ms.
      started = System.monotonic_time(:millisecond)
      {pid, id} = spawn_capped(base, max_cost: 0.5, status_poll_ms: 10)

      :ok = Mock.set_cost_per_hour(id, 0.0)
      await_tracked_rate(id, 0.0)

      wait_past_original_cap = max(started + 700 - System.monotonic_time(:millisecond), 0)
      refute_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, wait_past_original_cap
      assert Process.alive?(pid)
      assert {:ok, %{spent_usd: spent}} = ExAtlas.Orchestrator.info(id)
      assert spent < 0.5
    end

    test "a poll that reports no price keeps the last one", %{base: base} do
      {pid, id} = spawn_capped(base, max_cost: 0.5, status_poll_ms: 10)
      ref = Process.monitor(pid)

      :ok = Mock.set_cost_per_hour(id, nil)
      await_tracked_rate(id, nil)

      assert_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "spend carries across a respawn", %{base: base} do
      {:ok, _pid, compute} =
        ExAtlas.Orchestrator.run_task(
          Keyword.merge(base,
            command: ["/app/train.sh"],
            spot: true,
            on_failure: {:respawn, 1},
            status_poll_ms: 10,
            max_cost: 100
          )
        )

      id = compute.id
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(id))

      # Let $0.10 accrue, so a budget that restarted at zero reads lower.
      Process.sleep(100)
      assert {:ok, %{spent_usd: before}} = ExAtlas.Orchestrator.info(id)

      :ok = Mock.forget(id)
      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000

      assert {:ok, %{spent_usd: after_respawn}} = ExAtlas.Orchestrator.info(new_id)
      assert after_respawn >= before
    end

    test "a capped spot session with respawn budget left is not respawned", %{base: base} do
      {pid, id} =
        spawn_capped(base,
          spot: true,
          on_failure: {:respawn, 1},
          status_poll_ms: 10,
          max_cost: 0.05
        )

      ref = Process.monitor(pid)

      assert_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      refute_received {:atlas_compute, ^id, {:respawned, _}}
    end

    test "a respawn charges the replacement's price before the next poll", %{base: base} do
      # The pod drops to $0 and is preempted; its replacement rents at $1/s.
      # Every poll after the respawn is held open, so only the respawn itself
      # can tell the meter about the new price.
      {_pid, id} =
        spawn_capped(base,
          provider: FaultyProvider,
          spot: true,
          on_failure: {:respawn, 1},
          status_poll_ms: 10,
          max_cost: 0.3
        )

      :ok = Mock.set_cost_per_hour(id, 0.0)
      await_tracked_rate(id, 0.0)

      FaultyProvider.arm(:get_compute, {:block, self()})
      assert_receive {:blocked, :get_compute, poll}, 2_000
      :ok = Mock.forget(id)
      send(poll, :release)

      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))
      assert_receive {:blocked, :get_compute, _held}, 2_000

      assert_receive {:atlas_compute, ^new_id, {:terminating, :cost_cap}}, 2_000
    end

    test "a cap on a provider that reports no price deletes the pod and says so",
         %{base: base} do
      assert {:error, %ExAtlas.Error{kind: :unsupported, message: message}} =
               ExAtlas.Orchestrator.spawn(
                 Keyword.merge(base, max_cost: 1, provider_opts: %{cost_per_hour: nil})
               )

      assert message =~ "price"
      assert {:ok, [%{status: :terminated}]} = ExAtlas.list_compute(provider: :mock)
      assert ExAtlas.Orchestrator.list_ids() == []
    end

    test "a provider that reports no price still spawns and tracks without a cap",
         %{base: base} do
      assert {:ok, pid, compute} =
               ExAtlas.Orchestrator.spawn(
                 Keyword.merge(base, provider_opts: %{cost_per_hour: nil})
               )

      assert Process.alive?(pid)
      assert compute.cost_per_hour == nil
      assert ExAtlas.Orchestrator.list_ids() == [compute.id]
    end

    test "a cap months away at a tiny price starts and keeps tracking", %{base: base} do
      {pid, id} =
        spawn_capped(base,
          max_cost: 1000,
          status_poll_ms: 10,
          provider_opts: %{cost_per_hour: 0.0001}
        )

      assert Process.alive?(pid)
      ref = Process.monitor(pid)

      # A poll that re-prices to a still tinier rate re-arms the timer too.
      :ok = Mock.set_cost_per_hour(id, 0.00001)
      await_tracked_rate(id, 0.00001)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a refused priceless pod that the provider fails to delete is reported as such",
         %{base: base} do
      FaultyProvider.arm(
        :terminate,
        {:error, ExAtlas.Error.new(:provider, provider: :mock, status: 500)}
      )

      assert {:error, %ExAtlas.Error{kind: :unsupported, message: message}} =
               ExAtlas.Orchestrator.spawn(
                 Keyword.merge(base,
                   provider: FaultyProvider,
                   max_cost: 1,
                   provider_opts: %{cost_per_hour: nil}
                 )
               )

      assert {:ok, [%{id: id, status: :running}]} = ExAtlas.list_compute(provider: :mock)
      assert message =~ "could not be deleted"
      assert message =~ id
      refute message =~ "was deleted"
    end

    test "without a cap the same price ends nothing", %{base: base} do
      {pid, id} = spawn_capped(base, [])
      ref = Process.monitor(pid)

      refute_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 200
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{max_cost: false, spent_usd: +0.0}} = ExAtlas.Orchestrator.info(id)
    end
  end

  describe "billing reconciliation" do
    # $0.0001 a second: the estimate alone needs hours to reach $1.
    @slow 0.36
    @per_second 3600.0

    setup do
      base = [
        provider: :mock,
        gpu: :h100,
        image: "x",
        idle_ttl_ms: 60_000,
        heartbeat_ms: 60_000,
        status_poll_ms: false,
        reconcile_spend_ms: 20,
        provider_opts: %{cost_per_hour: @slow}
      ]

      {:ok, base: base}
    end

    defp spawn_reconciled(base, overrides) do
      {:ok, pid, compute} = ExAtlas.Orchestrator.spawn(Keyword.merge(base, overrides))
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(compute.id))
      {pid, compute.id}
    end

    test "a bill above the estimate ends the session at the cap", %{base: base} do
      {pid, id} = spawn_reconciled(base, max_cost: 1)
      ref = Process.monitor(pid)
      :ok = Mock.set_spend(id, 5.0)

      assert_receive {:atlas_compute, ^id,
                      {:spend_reconciled, %{billed_usd: 5.0, spent_usd: spent}}},
                     2_000

      assert spent >= 5.0
      assert_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a bill over the cap ends a session whose pod reads $0 an hour", %{base: base} do
      {pid, id} = spawn_reconciled(base, max_cost: 1, provider_opts: %{cost_per_hour: 0.0})
      ref = Process.monitor(pid)
      :ok = Mock.set_spend(id, 1.2)

      assert_receive {:atlas_compute, ^id, {:terminating, :cost_cap}}, 2_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
    end

    test "a bill below the estimate leaves the spend at the estimate", %{base: base} do
      {pid, id} =
        spawn_reconciled(base, max_cost: 100, provider_opts: %{cost_per_hour: @per_second})

      # Spawned at $1 a second, so the estimate passes $0.001 within 2 ms.
      :ok = Mock.set_spend(id, 0.001)

      assert_receive {:atlas_compute, ^id,
                      {:spend_reconciled,
                       %{estimated_usd: estimated, billed_usd: 0.001, spent_usd: spent}}},
                     2_000

      assert estimated > 0.001
      assert spent == estimated
      assert Process.alive?(pid)
    end

    test "a raised spend shows in info/1", %{base: base} do
      {_pid, id} = spawn_reconciled(base, max_cost: 100)
      :ok = Mock.set_spend(id, 40.0)

      assert_receive {:atlas_compute, ^id, {:spend_reconciled, %{billed_usd: 40.0}}}, 2_000
      assert {:ok, %{spent_usd: spent}} = ExAtlas.Orchestrator.info(id)
      assert spent >= 40.0
    end

    test "a failing bill is reported, changes nothing, and is asked again", %{base: base} do
      {pid, id} = spawn_reconciled(base, provider: FaultyProvider, max_cost: 1)
      error = ExAtlas.Error.new(:transport, provider: :mock, message: "socket closed")
      FaultyProvider.arm(:compute_spend, {:error, error})

      assert_receive {:atlas_compute, ^id, {:spend_reconcile_failed, ^error}}, 2_000
      assert_receive {:atlas_compute, ^id, {:spend_reconcile_failed, ^error}}, 2_000
      assert Process.alive?(pid)
      assert {:ok, %{spent_usd: spent}} = ExAtlas.Orchestrator.info(id)
      assert spent < 1
    end

    test "a billing call that raises is reported and the session stays", %{base: base} do
      {pid, id} = spawn_reconciled(base, provider: FaultyProvider, max_cost: 1)
      ref = Process.monitor(pid)
      FaultyProvider.arm(:compute_spend, :raise)

      assert_receive {:atlas_compute, ^id, {:spend_reconcile_failed, _reason}}, 2_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a provider with no billing API runs the session on the estimate, silently",
         %{base: base} do
      {pid, id} = spawn_reconciled(base, provider: NoBillingProvider, max_cost: 1)
      ref = Process.monitor(pid)

      # Ten intervals: no failure event each 20 ms, and no stop.
      refute_receive {:atlas_compute, ^id, {:spend_reconcile_failed, _}}, 200
      refute_received {:atlas_compute, ^id, {:spend_reconciled, _}}
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{max_cost: 1}} = ExAtlas.Orchestrator.info(id)
    end

    test "an :unsupported answer is asked for once", %{base: base} do
      unsupported = ExAtlas.Error.new(:unsupported, provider: :mock, message: "no billing")
      FaultyProvider.arm(:compute_spend, {:notify, self(), {:error, unsupported}})
      {_pid, id} = spawn_reconciled(base, provider: FaultyProvider, max_cost: 1)

      assert_receive {:called, :compute_spend, _task}, 2_000
      refute_receive {:called, :compute_spend, _task}, 200
      refute_received {:atlas_compute, ^id, {:spend_reconcile_failed, _}}
    end

    test "after a respawn the bill is compared with the replacement's spend alone",
         %{base: base} do
      {_pid, id} =
        spawn_reconciled(base,
          spot: true,
          on_failure: {:respawn, 1},
          status_poll_ms: 10,
          max_cost: 10
        )

      :ok = Mock.set_spend(id, 3.0)
      assert_receive {:atlas_compute, ^id, {:spend_reconciled, %{billed_usd: 3.0}}}, 2_000

      :ok = Mock.forget(id)
      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))
      :ok = Mock.set_spend(new_id, 2.0)

      # $3 billed for the first pod, then $2 for the replacement.
      assert_receive {:atlas_compute, ^new_id,
                      {:spend_reconciled,
                       %{estimated_usd: estimated, billed_usd: 2.0, spent_usd: spent}}},
                     2_000

      assert estimated < 1.0
      assert spent >= 5.0
    end

    test "a bill for the pod a respawn replaced is ignored", %{base: base} do
      {_pid, id} =
        spawn_reconciled(base,
          provider: FaultyProvider,
          spot: true,
          on_failure: {:respawn, 1},
          status_poll_ms: 10,
          max_cost: 1
        )

      FaultyProvider.arm(:compute_spend, {:block, self()})
      assert_receive {:blocked, :compute_spend, held}, 2_000

      # The old pod's bill is over the cap, but it lands after the respawn.
      :ok = Mock.set_spend(id, 5.0)
      :ok = Mock.forget(id)
      assert_receive {:atlas_compute, ^id, {:respawned, new_id}}, 2_000
      Phoenix.PubSub.subscribe(ExAtlas.PubSub, Events.topic(new_id))
      send(held, :release)

      refute_receive {:atlas_compute, ^new_id, {:terminating, :cost_cap}}, 200
      refute_received {:atlas_compute, ^new_id, {:spend_reconciled, _}}
      assert {:ok, %{spent_usd: spent}} = ExAtlas.Orchestrator.info(new_id)
      assert spent < 1
    end

    test "a bill with no total is reported and changes nothing", %{base: base} do
      {pid, id} = spawn_reconciled(base, max_cost: 1)
      :ok = Mock.set_spend(id, nil)

      assert_receive {:atlas_compute, ^id,
                      {:spend_reconcile_failed, %ExAtlas.Error{kind: :provider, raw: nil}}},
                     2_000

      refute_received {:atlas_compute, ^id, {:spend_reconciled, _}}
      assert Process.alive?(pid)
    end

    test "teardown kills a billing call still in flight", %{base: base} do
      {pid, id} = spawn_reconciled(base, provider: FaultyProvider, max_cost: 1)
      FaultyProvider.arm(:compute_spend, {:block, self()})
      assert_receive {:blocked, :compute_spend, held}, 2_000
      held_ref = Process.monitor(held)
      ref = Process.monitor(pid)

      :ok = ExAtlas.Orchestrator.stop_tracked(id)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      assert_receive {:DOWN, ^held_ref, :process, ^held, :killed}, 2_000
      assert {:ok, %{status: :terminated}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a stray reconcile message cannot end an uncapped session", %{base: base} do
      {pid, id} = spawn_reconciled(base, [])
      ref = Process.monitor(pid)

      send(pid, :reconcile_spend)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      assert Mock.spend_requests(id) == []
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a bill too large for a float is reported, and the session stays", %{base: base} do
      {pid, id} = spawn_reconciled(base, max_cost: 1)
      ref = Process.monitor(pid)
      :ok = Mock.set_spend(id, Integer.pow(10, 400))

      assert_receive {:atlas_compute, ^id, {:spend_reconcile_failed, %ExAtlas.Error{}}}, 2_000
      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert {:ok, %{status: :running}} = ExAtlas.get_compute(id, provider: :mock)
    end

    test "a session without max_cost never asks for its bill", %{base: base} do
      {_pid, uncapped} = spawn_reconciled(base, [])
      {_pid, switched_off} = spawn_reconciled(base, max_cost: 1, reconcile_spend_ms: false)
      {_pid, capped} = spawn_reconciled(base, max_cost: 1)

      # The control: a capped session asks within a few intervals.
      assert_receive {:atlas_compute, ^capped, {:spend_reconciled, _}}, 2_000
      assert_receive {:atlas_compute, ^capped, {:spend_reconciled, _}}, 2_000

      assert length(Mock.spend_requests(capped)) >= 2
      assert Mock.spend_requests(uncapped) == []
      assert Mock.spend_requests(switched_off) == []
      refute_received {:atlas_compute, ^uncapped, {:spend_reconciled, _}}
    end

    test "asks for the bill from the pod's spawn", %{base: base} do
      before = DateTime.utc_now()
      {_pid, id} = spawn_reconciled(base, max_cost: 1)

      assert_receive {:atlas_compute, ^id, {:spend_reconciled, _}}, 2_000
      assert [%{from: %DateTime{} = from, to: nil} | _] = Mock.spend_requests(id)
      assert {:ok, %{created_at: created_at}} = ExAtlas.get_compute(id, provider: :mock)

      # No later than the pod's own spawn, and not hours before this test.
      assert DateTime.compare(from, created_at) != :gt
      assert DateTime.diff(before, from, :second) < 5
    end
  end
end
