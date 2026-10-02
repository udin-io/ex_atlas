defmodule AtlasTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Providers.Mock
  alias ExAtlas.Spec
  alias ExAtlas.Test.FaultyProvider

  setup do
    Mock.reset()
    :ok
  end

  describe "spawn_compute/1" do
    test "raises when no provider is given and no default is configured" do
      Application.delete_env(:ex_atlas, :default_provider)

      assert_raise ArgumentError, ~r/no :provider passed/, fn ->
        ExAtlas.spawn_compute(gpu: :h100, image: "x")
      end
    end

    test "dispatches to the provider module and returns a normalized Compute" do
      {:ok, compute} =
        ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "test", ports: [{8000, :http}])

      assert %Spec.Compute{provider: :mock, status: :running} = compute
      assert [%{internal: 8000, protocol: :http}] = compute.ports
    end

    test "accepts a pre-built ComputeRequest struct" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "test")
      {:ok, compute} = ExAtlas.spawn_compute(req, provider: :mock)
      assert compute.provider == :mock
    end

    test "does not hand serverless job options to a ComputeRequest" do
      # `:mode` belongs to `JobRequest`. Routing every request key to whichever
      # request is being built made a compute spawn choke on it, which blocks
      # the orchestrator using `:mode` for anything of its own.
      assert {:ok, %Spec.Compute{}} =
               ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x", mode: :task)
    end

    test "sends :command and :self_terminate to the provider" do
      {:ok, compute} =
        ExAtlas.spawn_compute(
          provider: :mock,
          gpu: :h100,
          image: "x",
          command: ["/app/train.sh"],
          self_terminate: false
        )

      assert compute.raw.request.command == ["/app/train.sh"]
      assert compute.raw.request.self_terminate == false
    end

    test "accepts a user-provided provider module" do
      {:ok, compute} =
        ExAtlas.spawn_compute(provider: ExAtlas.Providers.Mock, gpu: :a100_80g, image: "x")

      assert compute.provider == :mock
    end
  end

  describe "get_compute / terminate / stop / start" do
    test "round-trip through mock provider" do
      {:ok, %{id: id}} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")

      {:ok, fetched} = ExAtlas.get_compute(id, provider: :mock)
      assert fetched.id == id
      assert fetched.status == :running

      :ok = ExAtlas.stop(id, provider: :mock)
      {:ok, stopped} = ExAtlas.get_compute(id, provider: :mock)
      assert stopped.status == :stopped

      :ok = ExAtlas.start(id, provider: :mock)
      :ok = ExAtlas.terminate(id, provider: :mock)
      {:ok, gone} = ExAtlas.get_compute(id, provider: :mock)
      assert gone.status == :terminated
    end
  end

  describe "list_compute filters" do
    test "filters by status" do
      {:ok, a} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      {:ok, b} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      :ok = ExAtlas.stop(a.id, provider: :mock)

      {:ok, running} = ExAtlas.list_compute(provider: :mock, status: :running)
      assert Enum.map(running, & &1.id) == [b.id]
    end
  end

  describe "stub providers" do
    test "Fly returns :unsupported for spawn" do
      assert {:error, %ExAtlas.Error{kind: :unsupported}} =
               ExAtlas.spawn_compute(provider: :fly, gpu: :a100_80g, image: "x")
    end

    test "Fly still reports capabilities" do
      assert :http_proxy in ExAtlas.capabilities(:fly)
    end

    test "LambdaLabs returns :unsupported" do
      assert {:error, %ExAtlas.Error{kind: :unsupported}} =
               ExAtlas.spawn_compute(provider: :lambda_labs, gpu: :h100, image: "x")
    end

    test "Vast returns :unsupported" do
      assert {:error, %ExAtlas.Error{kind: :unsupported}} =
               ExAtlas.spawn_compute(provider: :vast, gpu: :h100, image: "x")
    end
  end

  describe "run_job" do
    test "echoes input through the mock provider" do
      {:ok, job} =
        ExAtlas.run_job(provider: :mock, endpoint: "abc", input: %{prompt: "hi"}, mode: :async)

      assert job.status == :completed
      assert job.output == %{"echo" => %{prompt: "hi"}}
    end

    test "does not hand compute options to a JobRequest" do
      assert {:ok, _job} =
               ExAtlas.run_job(
                 provider: :mock,
                 endpoint: "abc",
                 input: %{},
                 image: "not-a-job-option"
               )
    end
  end

  describe "list_gpu_types" do
    test "returns mock catalog" do
      {:ok, [gpu | _]} = ExAtlas.list_gpu_types(provider: :mock)
      assert %Spec.GpuType{provider: :mock, canonical: :h100} = gpu
    end
  end

  describe "await_ready/2" do
    setup do
      FaultyProvider.reset()
      on_exit(&FaultyProvider.reset/0)

      {:ok, compute} = ExAtlas.spawn_compute(provider: :mock, gpu: :h100, image: "x")
      {:ok, id: compute.id}
    end

    test "returns straight away when the resource is already running", %{id: id} do
      # A timeout too short to survive a single poll interval, so a wait that
      # slept even once would fail here.
      assert {:ok, %Spec.Compute{id: ^id, status: :running}} =
               ExAtlas.await_ready(id, provider: :mock, poll_interval_ms: 5_000, timeout_ms: 50)
    end

    test "keeps polling until the provider reports running", %{id: id} do
      :ok = Mock.set_status(id, :provisioning)
      FaultyProvider.arm(:get_compute, {:block, self()})

      task = Task.async(fn -> await(id) end)

      # First poll: still provisioning, so the wait must not resolve.
      assert_receive {:blocked, :get_compute, first}, 2_000
      send(first, :release)

      # Second poll: the cloud has finished provisioning.
      assert_receive {:blocked, :get_compute, second}, 2_000
      :ok = Mock.set_status(id, :running)
      send(second, :release)

      assert {:ok, %Spec.Compute{id: ^id, status: :running}} = Task.await(task, 5_000)
    end

    test "a poll that merely failed does not resolve the wait", %{id: id} do
      # A 5xx or a socket blip is "we could not tell", not "it will never be
      # ready". Resolving on one would turn a provider hiccup into a spurious
      # failure for every caller of this function.
      FaultyProvider.arm(
        :get_compute,
        {:error_once, ExAtlas.Error.new(:provider, provider: :mock, status: 500)}
      )

      assert {:ok, %Spec.Compute{id: ^id, status: :running}} = await(id)
    end

    test "gives up at the timeout and hands back the last compute it saw", %{id: id} do
      :ok = Mock.set_status(id, :provisioning)

      assert {:error, {:timeout, %Spec.Compute{id: ^id, status: :provisioning}}} =
               ExAtlas.await_ready(id, provider: :mock, poll_interval_ms: 5, timeout_ms: 40)

      # Nothing is terminated implicitly — the caller decides what a slow pod
      # is worth.
      assert {:ok, %Spec.Compute{status: :provisioning}} =
               ExAtlas.get_compute(id, provider: :mock)
    end

    test "a timeout with no successful poll at all hands back nothing", %{id: id} do
      FaultyProvider.arm(
        :get_compute,
        {:error, ExAtlas.Error.new(:provider, provider: :mock, status: 500)}
      )

      assert {:error, {:timeout, nil}} =
               ExAtlas.await_ready(id,
                 provider: FaultyProvider,
                 poll_interval_ms: 5,
                 timeout_ms: 40
               )
    end

    test "a resource that dies while waiting is reported with its cause", %{id: id} do
      :ok = Mock.set_status(id, :provisioning)
      FaultyProvider.arm(:get_compute, {:block, self()})

      task = Task.async(fn -> await(id) end)

      assert_receive {:blocked, :get_compute, first}, 2_000
      send(first, :release)

      assert_receive {:blocked, :get_compute, second}, 2_000
      :ok = Mock.set_status(id, :failed)
      send(second, :release)

      assert {:error, {:dead, :failed, %Spec.Compute{status: :failed}}} = Task.await(task, 5_000)
    end

    test "a resource the provider has forgotten is dead, with nothing to hand back", %{id: id} do
      :ok = Mock.forget(id)

      assert {:error, {:dead, :vanished, nil}} = await(id)
    end

    test "on spot capacity a disappearance is reported as preemption", %{id: id} do
      :ok = Mock.forget(id)

      assert {:error, {:dead, :preempted, nil}} =
               ExAtlas.await_ready(id,
                 provider: :mock,
                 spot: true,
                 poll_interval_ms: 5,
                 timeout_ms: 500
               )
    end

    defp await(id) do
      ExAtlas.await_ready(id, provider: FaultyProvider, poll_interval_ms: 1, timeout_ms: 5_000)
    end
  end

  defmodule BareProvider do
    @moduledoc false
    def capabilities, do: []
  end

  describe "network volumes" do
    setup do
      bypass = Bypass.open()

      {:ok,
       bypass: bypass,
       opts: [provider: :runpod, api_key: "k", base_url: "http://localhost:#{bypass.port}"]}
    end

    defp respond(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    @volume %{
      "id" => "vol_1",
      "name" => "datasets",
      "size" => 200,
      "dataCenter" => "EU-RO-1",
      "type" => "HIGH_PERFORMANCE"
    }

    test "create_network_volume/1 takes plain options, and provider config keys reach the ctx", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "POST", "/network-volumes", fn conn ->
        assert ["Bearer k"] = Plug.Conn.get_req_header(conn, "authorization")
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert %{"name" => "datasets", "size" => 200, "dataCenter" => "EU-RO-1"} =
                 Jason.decode!(raw)

        respond(conn, 201, @volume)
      end)

      assert {:ok, %Spec.NetworkVolume{id: "vol_1", provider: :runpod, size_gb: 200}} =
               ExAtlas.create_network_volume(
                 [name: "datasets", size_gb: 200, region: "EU-RO-1"] ++ opts
               )
    end

    test "create_network_volume/1 passes tier and provider_opts to the request", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "POST", "/network-volumes", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"type" => "STANDARD", "extra" => 1} = Jason.decode!(raw)
        respond(conn, 201, %{@volume | "type" => "STANDARD"})
      end)

      assert {:ok, %Spec.NetworkVolume{tier: :standard}} =
               ExAtlas.create_network_volume(
                 [
                   name: "d",
                   size_gb: 10,
                   region: "r",
                   tier: :standard,
                   provider_opts: %{extra: 1}
                 ] ++
                   opts
               )
    end

    test "create_network_volume/1 raises on a missing name like spawn_compute/1 does", %{
      opts: opts
    } do
      assert_raise NimbleOptions.ValidationError, fn ->
        ExAtlas.create_network_volume([size_gb: 10] ++ opts)
      end
    end

    test "list, get and delete go to the provider", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "GET", "/network-volumes", fn conn ->
        respond(conn, 200, %{"networkVolumes" => [@volume]})
      end)

      Bypass.expect_once(bypass, "GET", "/network-volumes/vol_1", fn conn ->
        respond(conn, 200, @volume)
      end)

      Bypass.expect_once(bypass, "DELETE", "/network-volumes/vol_1", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, [%Spec.NetworkVolume{id: "vol_1"}]} = ExAtlas.list_network_volumes(opts)
      assert {:ok, %Spec.NetworkVolume{id: "vol_1"}} = ExAtlas.get_network_volume("vol_1", opts)
      assert :ok = ExAtlas.delete_network_volume("vol_1", opts)
    end

    test "a provider without the callbacks returns :unsupported for all four calls" do
      for provider <- [:mock, :lambda_labs, BareProvider] do
        opts = [provider: provider, api_key: "k"]

        for result <- [
              ExAtlas.list_network_volumes(opts),
              ExAtlas.get_network_volume("v", opts),
              ExAtlas.create_network_volume([name: "d", size_gb: 10, region: "r"] ++ opts),
              ExAtlas.delete_network_volume("v", opts)
            ] do
          assert {:error, %ExAtlas.Error{kind: :unsupported}} = result
        end
      end
    end

    test "the :unsupported error names the provider and the call" do
      assert {:error, %ExAtlas.Error{provider: :lambda_labs, message: message}} =
               ExAtlas.list_network_volumes(provider: :lambda_labs, api_key: "k")

      assert message =~ "list_network_volumes"
    end

    test "capabilities: runpod manages network volumes, mock does not" do
      assert :manage_network_volumes in ExAtlas.capabilities(:runpod)
      refute :manage_network_volumes in ExAtlas.capabilities(:mock)
    end
  end

  describe "templates" do
    setup do
      bypass = Bypass.open()

      {:ok,
       bypass: bypass,
       opts: [provider: :runpod, api_key: "k", base_url: "http://localhost:#{bypass.port}"]}
    end

    @template %{
      "id" => "tpl_7",
      "name" => "trainer-v7",
      "image" => "ghcr.io/acme/trainer:7",
      "ports" => ["8000/http"],
      "env" => %{"A" => "1"},
      "disk" => 80
    }

    defp template_respond(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    test "create_template/1 takes plain options, and provider config keys reach the ctx", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "POST", "/templates", fn conn ->
        assert ["Bearer k"] = Plug.Conn.get_req_header(conn, "authorization")
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert %{
                 "name" => "trainer-v7",
                 "image" => "ghcr.io/acme/trainer:7",
                 "ports" => ["8000/http"],
                 "startSsh" => false,
                 "extra" => 1
               } = Jason.decode!(raw)

        template_respond(conn, 201, @template)
      end)

      assert {:ok, %Spec.Template{id: "tpl_7", provider: :runpod, ports: [{8000, :http}]}} =
               ExAtlas.create_template(
                 [
                   name: "trainer-v7",
                   image: "ghcr.io/acme/trainer:7",
                   ports: [{8000, :http}],
                   ssh: false,
                   provider_opts: %{extra: 1}
                 ] ++ opts
               )
    end

    test "create_template/1 raises on a missing image like spawn_compute/1 does", %{opts: opts} do
      assert_raise NimbleOptions.ValidationError, fn ->
        ExAtlas.create_template([name: "t"] ++ opts)
      end
    end

    test "list, get and delete go to the provider", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "GET", "/templates", fn conn ->
        template_respond(conn, 200, %{
          "templates" => [@template],
          "pagination" => %{"nextCursor" => nil, "hasNextPage" => false}
        })
      end)

      Bypass.expect_once(bypass, "GET", "/templates/tpl_7", fn conn ->
        template_respond(conn, 200, @template)
      end)

      Bypass.expect_once(bypass, "DELETE", "/templates/tpl_7", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, [%Spec.Template{id: "tpl_7"}]} = ExAtlas.list_templates(opts)
      assert {:ok, %Spec.Template{id: "tpl_7"}} = ExAtlas.get_template("tpl_7", opts)
      assert :ok = ExAtlas.delete_template("tpl_7", opts)
    end

    test "a provider without the callbacks returns :unsupported for all four calls" do
      for provider <- [:mock, :lambda_labs, :fly, BareProvider] do
        opts = [provider: provider, api_key: "k"]

        for result <- [
              ExAtlas.list_templates(opts),
              ExAtlas.get_template("t", opts),
              ExAtlas.create_template([name: "t", image: "i"] ++ opts),
              ExAtlas.delete_template("t", opts)
            ] do
          assert {:error, %ExAtlas.Error{kind: :unsupported}} = result
        end
      end
    end

    test "capabilities: runpod manages templates, mock does not" do
      assert :manage_templates in ExAtlas.capabilities(:runpod)
      refute :manage_templates in ExAtlas.capabilities(:mock)
    end
  end

  describe "serverless endpoints" do
    setup do
      bypass = Bypass.open()

      {:ok,
       bypass: bypass,
       opts: [provider: :runpod, api_key: "k", base_url: "http://localhost:#{bypass.port}"]}
    end

    @endpoint %{
      "id" => "ep_1",
      "name" => "image-generator",
      "type" => "QUEUE",
      "workers" => %{"min" => 0, "max" => 3}
    }

    defp endpoint_respond(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    test "list, get and delete go to the provider", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "GET", "/serverless", fn conn ->
        assert ["Bearer k"] = Plug.Conn.get_req_header(conn, "authorization")

        endpoint_respond(conn, 200, %{
          "endpoints" => [@endpoint],
          "pagination" => %{"nextCursor" => nil, "hasNextPage" => false}
        })
      end)

      Bypass.expect_once(bypass, "GET", "/serverless/ep_1", fn conn ->
        endpoint_respond(conn, 200, @endpoint)
      end)

      Bypass.expect_once(bypass, "DELETE", "/serverless/ep_1", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert {:ok, [%Spec.Endpoint{id: "ep_1", type: :queue}]} = ExAtlas.list_endpoints(opts)

      assert {:ok, %Spec.Endpoint{id: "ep_1", workers_max: 3}} =
               ExAtlas.get_endpoint("ep_1", opts)

      assert :ok = ExAtlas.delete_endpoint("ep_1", opts)
    end

    test "a provider without the callbacks returns :unsupported for all three calls" do
      for provider <- [:mock, :lambda_labs, :fly, BareProvider] do
        opts = [provider: provider, api_key: "k"]

        for result <- [
              ExAtlas.list_endpoints(opts),
              ExAtlas.get_endpoint("e", opts),
              ExAtlas.delete_endpoint("e", opts)
            ] do
          assert {:error, %ExAtlas.Error{kind: :unsupported}} = result
        end
      end
    end

    test "capabilities: runpod manages endpoints, mock does not" do
      assert :manage_endpoints in ExAtlas.capabilities(:runpod)
      refute :manage_endpoints in ExAtlas.capabilities(:mock)
    end
  end

  describe "compute_spend/2" do
    setup do
      bypass = Bypass.open()

      {:ok,
       bypass: bypass,
       opts: [provider: :runpod, api_key: "k", base_url: "http://localhost:#{bypass.port}"]}
    end

    defp spend_respond(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end

    @spend_body %{
      "records" => [],
      "metadata" => %{
        "query" => %{
          "startTime" => "2026-09-01T00:00:00Z",
          "endTime" => "2026-10-02T00:00:00Z",
          "bucketSize" => "day",
          "podId" => "pod_9"
        },
        "totals" => %{
          "totalAmount" => 12.34,
          "gpuAmount" => 11.1,
          "cpuAmount" => 0,
          "diskAmount" => 1.24
        }
      }
    }

    test "returns one pod's spend, and provider config keys reach the ctx", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/billing/pods", fn conn ->
        assert ["Bearer k"] = Plug.Conn.get_req_header(conn, "authorization")
        assert conn.query_string == "podId=pod_9"
        spend_respond(conn, 200, @spend_body)
      end)

      assert {:ok,
              %Spec.Spend{
                compute_id: "pod_9",
                provider: :runpod,
                total_usd: 12.34,
                gpu_usd: 11.1,
                cpu_usd: +0.0,
                disk_usd: 1.24,
                from: ~U[2026-09-01 00:00:00Z],
                to: ~U[2026-10-02 00:00:00Z]
              }} = ExAtlas.compute_spend("pod_9", opts)
    end

    test "from: and to: reach RunPod as startTime and endTime, not as ctx keys", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/billing/pods", fn conn ->
        assert %{"startTime" => "2026-09-30T00:00:00Z", "endTime" => "2026-10-01T00:00:00Z"} =
                 URI.decode_query(conn.query_string)

        spend_respond(conn, 200, @spend_body)
      end)

      assert {:ok, %Spec.Spend{}} =
               ExAtlas.compute_spend(
                 "pod_9",
                 [from: ~U[2026-09-30 00:00:00Z], to: ~U[2026-10-01 00:00:00Z]] ++ opts
               )
    end

    test "a from: or to: that is not a DateTime is a :validation error and sends no request", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.down(bypass)

      for bad <- [[from: "2026-09-30"], [to: 1_759_000_000], [from: ~D[2026-09-30]]] do
        assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
                 ExAtlas.compute_spend("pod_9", bad ++ opts)

        assert message =~ "DateTime"
      end
    end

    test "a provider without the callback returns :unsupported" do
      for provider <- [:lambda_labs, :fly, BareProvider] do
        assert {:error, %ExAtlas.Error{kind: :unsupported, message: message}} =
                 ExAtlas.compute_spend("pod_9", provider: provider, api_key: "k")

        assert message =~ "compute_spend"
      end
    end

    test "capabilities: runpod reports billing, lambda_labs does not" do
      assert :billing in ExAtlas.capabilities(:runpod)
      refute :billing in ExAtlas.capabilities(:lambda_labs)
    end
  end
end
