defmodule ExAtlas.Providers.LambdaLabsTest do
  # Bypass stands in for Lambda's Cloud API v1. A refusal test registers no
  # route for POST /instance-operations/launch, so a launch fails the test.
  use ExUnit.Case, async: false

  import ExAtlas.Test.FakeLambda

  alias ExAtlas.Orchestrator.UpstreamStatus
  alias ExAtlas.Spec

  setup do
    bypass = Bypass.open()

    opts = [
      provider: :lambda_labs,
      api_key: "lambda-test-key",
      base_url: "http://localhost:#{bypass.port}"
    ]

    {:ok, bypass: bypass, opts: opts}
  end

  describe "get_compute/2" do
    test "maps an active instance: IP, ports and URLs, created_at, price, region", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/instances/inst-1", fn conn ->
        assert ["Bearer lambda-test-key"] = Plug.Conn.get_req_header(conn, "authorization")
        json(conn, 200, %{"data" => instance(%{"id" => "inst-1"})})
      end)

      assert {:ok, compute} = ExAtlas.get_compute("inst-1", opts)

      assert %Spec.Compute{
               id: "inst-1",
               provider: :lambda_labs,
               status: :running,
               public_ip: "198.51.100.2",
               gpu_type: "gpu_1x_h100_pcie",
               gpu_count: 1,
               cost_per_hour: 2.49,
               region: "us-east-1",
               image: "vllm/vllm-openai:latest",
               name: "atlas-test",
               created_at: ~U[2026-10-02 09:30:00Z]
             } = compute

      assert compute.ports == [
               %{
                 internal: 8000,
                 external: 8000,
                 protocol: :http,
                 url: "http://198.51.100.2:8000"
               },
               %{internal: 22, external: 22, protocol: :tcp, url: "tcp://198.51.100.2:22"}
             ]
    end

    test "maps each of Lambda's six statuses", %{bypass: bypass, opts: opts} do
      expected = %{
        "booting" => :provisioning,
        "active" => :running,
        "unhealthy" => :running,
        "terminating" => :terminated,
        "terminated" => :terminated,
        "preempted" => :terminated
      }

      for {lambda_status, status} <- expected do
        Bypass.expect_once(bypass, "GET", "/instances/#{lambda_status}", fn conn ->
          json(conn, 200, %{
            "data" => instance(%{"id" => lambda_status, "status" => lambda_status})
          })
        end)

        assert {:ok, %Spec.Compute{status: ^status}} = ExAtlas.get_compute(lambda_status, opts),
               "#{lambda_status} should read #{status}"
      end
    end

    test "a booting instance with no IP yet has ports without URLs", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "GET", "/instances/inst-1", fn conn ->
        booting = instance(%{"status" => "booting"}) |> Map.delete("ip")
        json(conn, 200, %{"data" => booting})
      end)

      assert {:ok, %{status: :provisioning, public_ip: nil, ports: ports}} =
               ExAtlas.get_compute("inst-1", opts)

      assert Enum.map(ports, & &1.url) == [nil, nil]
    end

    test "raw holds no jupyter_token, and no jupyter_url that carries it", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/instances/inst-1", fn conn ->
        json(conn, 200, %{"data" => instance()})
      end)

      assert {:ok, %{raw: raw}} = ExAtlas.get_compute("inst-1", opts)

      # Control: raw is the instance body, not an empty map.
      assert raw["hostname"] == "198-51-100-2"
      refute inspect(raw) =~ "jt-0b7d30d9d3e4d8fa41657bc0d478c1b"
    end

    test "a 404 is :not_found, which UpstreamStatus reads as vanished", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/instances/gone", &json(&1, 404, not_found()))

      assert {:error, %ExAtlas.Error{kind: :not_found, provider: :lambda_labs} = error} =
               ExAtlas.get_compute("gone", opts)

      assert error.message == "Specified instance does not exist."
      assert {:dead, :vanished, _} = UpstreamStatus.classify({:error, error})
    end

    test "no API key anywhere raises :unauthorized naming LAMBDA_LABS_API_KEY", %{opts: opts} do
      opts = Keyword.delete(opts, :api_key)
      previous = System.get_env("LAMBDA_LABS_API_KEY")
      System.delete_env("LAMBDA_LABS_API_KEY")
      on_exit(fn -> previous && System.put_env("LAMBDA_LABS_API_KEY", previous) end)

      error = assert_raise ExAtlas.Error, fn -> ExAtlas.get_compute("inst-1", opts) end
      assert error.kind == :unauthorized
      assert error.message =~ "LAMBDA_LABS_API_KEY"
    end
  end

  describe "get_compute/2 ids" do
    test "an id is one path segment: a slash in it is escaped", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "GET", "/instances/a%2F..%2Fb", fn conn ->
        json(conn, 404, not_found())
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute("a/../b", opts)
    end
  end

  describe "list_compute/1" do
    test "follows page_token over two pages", %{bypass: bypass, opts: opts} do
      Bypass.expect(bypass, "GET", "/instances", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["page_token"] do
          nil ->
            json(conn, 200, %{"data" => [instance(%{"id" => "a"})], "page_token" => "next-1"})

          "next-1" ->
            json(conn, 200, %{"data" => [instance(%{"id" => "b"})], "page_token" => nil})
        end
      end)

      assert {:ok, computes} = ExAtlas.list_compute(opts)
      assert Enum.map(computes, & &1.id) == ["a", "b"]
    end

    test "a page token that does not advance fails the list", %{bypass: bypass, opts: opts} do
      Bypass.expect(bypass, "GET", "/instances", fn conn ->
        json(conn, 200, %{"data" => [instance()], "page_token" => "same"})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
               ExAtlas.list_compute(opts)

      assert message =~ "did not advance"
    end

    test "applies the status, name, region and gpu filters", %{bypass: bypass, opts: opts} do
      h100_8x =
        type_entry("gpu_8x_h100_pcie", 1992, 8, "H100 (80 GB PCIe)", [])["instance_type"]

      a10 = type_entry("gpu_1x_a10", 75, 1, "A10 (24 GB PCIe)", [])["instance_type"]

      instances = [
        instance(%{"id" => "running-h100", "name" => "a"}),
        instance(%{"id" => "booting-h100", "name" => "b", "status" => "booting"}),
        instance(%{
          "id" => "west-a10",
          "name" => "c",
          "instance_type" => a10,
          "region" => %{"name" => "us-west-1", "description" => "California"}
        }),
        instance(%{"id" => "running-8x", "name" => "a", "instance_type" => h100_8x})
      ]

      Bypass.expect(bypass, "GET", "/instances", fn conn ->
        json(conn, 200, %{"data" => instances, "page_token" => nil})
      end)

      ids = fn filters ->
        {:ok, computes} = ExAtlas.list_compute(opts ++ filters)
        computes |> Enum.map(& &1.id) |> Enum.sort()
      end

      assert ids.(status: :provisioning) == ["booting-h100"]
      assert ids.(name: "a") == ["running-8x", "running-h100"]
      assert ids.(region: "us-west-1") == ["west-a10"]
      assert ids.(gpu: :h100) == ["booting-h100", "running-8x", "running-h100"]
      assert ids.(gpu: :a10) == ["west-a10"]
    end
  end

  describe "terminate/2" do
    test "posts the instance id and returns :ok", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "POST", "/instance-operations/terminate", fn conn ->
        {body, conn} = read_json(conn)
        assert body == %{"instance_ids" => ["inst-1"]}
        json(conn, 200, %{"data" => %{"terminated_instances" => [instance(%{"id" => "inst-1"})]}})
      end)

      assert :ok = ExAtlas.terminate("inst-1", opts)
    end
  end

  describe "stop/2 and start/2" do
    test "return :unsupported naming terminate, with no request", %{opts: opts} do
      for result <- [ExAtlas.stop("inst-1", opts), ExAtlas.start("inst-1", opts)] do
        assert {:error, %ExAtlas.Error{kind: :unsupported, provider: :lambda_labs, message: m}} =
                 result

        assert m =~ "terminate"
      end
    end
  end

  describe "list_gpu_types/1" do
    test "maps name, canonical, description, memory, price and stock", %{
      bypass: bypass,
      opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/instance-types", fn conn ->
        json(conn, 200, %{"data" => instance_types()})
      end)

      assert {:ok, types} = ExAtlas.list_gpu_types(opts)
      by_id = Map.new(types, &{&1.id, &1})

      assert %Spec.GpuType{
               provider: :lambda_labs,
               canonical: :h100,
               display_name: "1x H100 (80 GB PCIe)",
               memory_gb: 80,
               lowest_price_per_hour: 2.49,
               stock: :unknown
             } = by_id["gpu_1x_h100_pcie"]

      assert %{canonical: :h100_sxm, stock: :unknown, lowest_price_per_hour: 23.92} =
               by_id["gpu_8x_h100_sxm5"]

      assert %{stock: :unavailable} = by_id["gpu_1x_h100_sxm5"]
      assert %{canonical: :a10, memory_gb: 24} = by_id["gpu_1x_a10"]
    end
  end

  describe "telemetry" do
    def forward(event, measurements, meta, pid), do: send(pid, {event, measurements, meta})

    test "every request emits [:ex_atlas, :lambda_labs, :request] without the key", %{
      bypass: bypass,
      opts: opts
    } do
      handler = "lambda-telemetry-#{System.unique_integer()}"

      :telemetry.attach(
        handler,
        [:ex_atlas, :lambda_labs, :request],
        &__MODULE__.forward/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Bypass.expect(bypass, "GET", "/instances", fn conn ->
        json(conn, 200, %{"data" => [], "page_token" => nil})
      end)

      assert {:ok, []} = ExAtlas.list_compute(opts)

      assert_received {[:ex_atlas, :lambda_labs, :request], %{status: 200}, meta}
      assert meta.url =~ "/instances"
      refute meta.url =~ "page_size"
      refute inspect(meta) =~ "lambda-test-key"
    end
  end
end
