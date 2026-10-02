defmodule ExAtlas.Providers.VastTest do
  # Bypass stands in for Vast's API: get, list, terminate and the GPU catalog.
  use ExUnit.Case, async: false

  import ExAtlas.Test.FakeVast

  alias ExAtlas.Spec

  setup do
    bypass = Bypass.open()

    opts = [
      provider: :vast,
      api_key: "vast-test-key",
      base_url: "http://localhost:#{bypass.port}"
    ]

    {:ok, bypass: bypass, opts: opts}
  end

  defp expect_instance(bypass, instance) do
    Bypass.expect_once(bypass, "GET", "/api/v0/instances/28411907", fn conn ->
      json(conn, 200, %{"instances" => instance})
    end)
  end

  describe "get_compute/2" do
    test "reads a running instance with its port URLs", %{bypass: bypass, opts: opts} do
      expect_instance(bypass, instance())

      assert {:ok, %Spec.Compute{} = compute} = ExAtlas.get_compute("28411907", opts)

      assert compute.id == "28411907"
      assert compute.provider == :vast
      assert compute.status == :running
      assert compute.public_ip == "203.0.113.7"
      assert compute.gpu_type == "RTX 4090"
      assert compute.gpu_count == 1
      assert compute.cost_per_hour == 0.42
      assert compute.region == "Texas, US"
      assert compute.image == "vllm/vllm-openai:latest"
      assert compute.name == "atlas-test"
      assert compute.created_at == ~U[2026-09-21 14:13:20Z]

      assert compute.ports == [
               %{
                 internal: 8000,
                 external: 41_234,
                 protocol: :http,
                 url: "http://203.0.113.7:41234"
               },
               %{internal: 22, external: 41_022, protocol: :tcp, url: "tcp://203.0.113.7:41022"}
             ]
    end

    test "maps each actual_status", %{bypass: bypass, opts: opts} do
      for {vast, ours} <- [
            {"running", :running},
            {"exited", :stopped},
            {"offline", :failed},
            {"unknown", :failed},
            {"loading", :provisioning},
            {"created", :provisioning},
            {nil, :provisioning},
            {"something new", :provisioning}
          ] do
        expect_instance(bypass, instance(%{"actual_status" => vast}))

        assert {:ok, %{status: ^ours}} = ExAtlas.get_compute("28411907", opts),
               "expected #{inspect(vast)} to read #{inspect(ours)}"
      end
    end

    test "raw holds no env value, onstart script or jupyter token", %{bypass: bypass, opts: opts} do
      expect_instance(bypass, instance())

      assert {:ok, compute} = ExAtlas.get_compute("28411907", opts)

      # Control: raw is Vast's body, not an empty map.
      assert compute.raw["machine_id"] == 41_234
      refute inspect(compute.raw) =~ "hf-instance-secret"
      refute inspect(compute.raw) =~ "53fc448d6644aa7535c6fa5498cdbedc"
      refute Map.has_key?(compute.raw, "onstart")
    end

    # `list_compute/1` lists every instance on the account, ExAtlas's or not,
    # and a field Vast adds later may carry a value too, so raw keeps only
    # fields known to hold none.
    test "raw keeps no field it does not know: image_args, status_msg, a new one", %{
      bypass: bypass,
      opts: opts
    } do
      expect_instance(
        bypass,
        instance(%{
          "image_args" => ["serve", "--api-key", "args-secret-4e1"],
          "status_msg" => "pulled with token args-secret-4e1",
          "some_new_field" => "args-secret-4e1"
        })
      )

      assert {:ok, compute} = ExAtlas.get_compute("28411907", opts)

      assert compute.raw["gpu_name"] == "RTX 4090"
      refute inspect(compute.raw) =~ "args-secret-4e1"
    end

    test "a port Vast has not mapped yet has no URL", %{bypass: bypass, opts: opts} do
      expect_instance(bypass, instance(%{"ports" => %{}, "actual_status" => "loading"}))

      assert {:ok, %{ports: ports}} = ExAtlas.get_compute("28411907", opts)

      assert ports == [
               %{internal: 8000, external: nil, protocol: :http, url: nil},
               %{internal: 22, external: nil, protocol: :tcp, url: nil}
             ]
    end

    test "an instance ExAtlas did not start reads each mapped port as tcp", %{
      bypass: bypass,
      opts: opts
    } do
      expect_instance(bypass, instance(%{"extra_env" => []}))

      assert {:ok, %{ports: ports}} = ExAtlas.get_compute("28411907", opts)

      assert ports == [
               %{internal: 22, external: 41_022, protocol: :tcp, url: "tcp://203.0.113.7:41022"},
               %{internal: 8000, external: 41_234, protocol: :tcp, url: "tcp://203.0.113.7:41234"}
             ]
    end

    test "instances: null is :not_found, which UpstreamStatus reads as vanished", %{
      bypass: bypass,
      opts: opts
    } do
      expect_instance(bypass, nil)

      assert {:dead, :vanished, nil} =
               ExAtlas.Orchestrator.UpstreamStatus.observe("28411907", opts)
    end

    test "a 404 is :not_found", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "GET", "/api/v0/instances/28411907", fn conn ->
        json(conn, 404, refused("not_found", "Instance not found"))
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute("28411907", opts)
    end

    test "an id is sent path-encoded", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "GET", "/api/v0/instances/..%2Fx", fn conn ->
        json(conn, 200, %{"instances" => nil})
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute("../x", opts)
    end
  end

  describe "list_compute/1" do
    setup %{bypass: bypass} do
      test_pid = self()

      Bypass.expect(bypass, "GET", "/api/v1/instances", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:page, conn.query_params})

        case conn.query_params["after_token"] do
          nil ->
            json(conn, 200, %{
              "instances" => [
                instance(%{"id" => 1, "label" => "web", "actual_status" => "running"}),
                instance(%{"id" => 2, "label" => "batch", "actual_status" => "loading"})
              ],
              "next_token" => "page-2"
            })

          "page-2" ->
            json(conn, 200, %{
              "instances" => [
                instance(%{"id" => 3, "label" => "web", "actual_status" => "exited"})
              ],
              "next_token" => nil
            })
        end
      end)

      :ok
    end

    test "follows next_token across pages, 25 a page", %{opts: opts} do
      assert {:ok, computes} = ExAtlas.list_compute(opts)
      assert Enum.map(computes, & &1.id) == ["1", "2", "3"]

      assert_received {:page, %{"limit" => "25"} = first}
      refute Map.has_key?(first, "after_token")
      assert_received {:page, %{"after_token" => "page-2"}}
    end

    test "filters by name and status", %{opts: opts} do
      assert {:ok, [%{id: "1"}]} = ExAtlas.list_compute(opts ++ [name: "web", status: :running])
    end

    test "filters by GPU family", %{opts: opts} do
      assert {:ok, [_, _, _]} = ExAtlas.list_compute(opts ++ [gpu: :rtx_4090])
      assert {:ok, []} = ExAtlas.list_compute(opts ++ [gpu: :h100])
    end
  end

  describe "list_compute/1 paging errors" do
    test "a token that does not advance fails the whole call", %{bypass: bypass, opts: opts} do
      Bypass.expect(bypass, "GET", "/api/v1/instances", fn conn ->
        json(conn, 200, %{"instances" => [instance()], "next_token" => "same"})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
               ExAtlas.list_compute(opts)

      assert message =~ "did not advance"
    end

    test "a failed second page fails the whole call", %{bypass: bypass, opts: opts} do
      Bypass.expect(bypass, "GET", "/api/v1/instances", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.query_params["after_token"],
          do: json(conn, 400, %{"success" => false, "error" => "invalid_args"}),
          else: json(conn, 200, %{"instances" => [instance()], "next_token" => "t2"})
      end)

      assert {:error, %ExAtlas.Error{status: 400}} = ExAtlas.list_compute(opts)
    end
  end

  describe "terminate/2" do
    test "sends DELETE /api/v0/instances/{id}/", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "DELETE", "/api/v0/instances/28411907", fn conn ->
        json(conn, 200, %{"success" => true})
      end)

      assert :ok = ExAtlas.terminate("28411907", opts)
    end

    test "a 404 is :not_found", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "DELETE", "/api/v0/instances/28411907", fn conn ->
        json(conn, 404, refused("not_found", "Instance not found"))
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.terminate("28411907", opts)
    end

    test "a 200 with success: false is an error", %{bypass: bypass, opts: opts} do
      Bypass.expect_once(bypass, "DELETE", "/api/v0/instances/28411907", fn conn ->
        json(conn, 200, refused("invalid_args", "invalid instance_id"))
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, raw: %{"error" => "invalid_args"}}} =
               ExAtlas.terminate("28411907", opts)
    end
  end

  describe "stop/2 and start/2" do
    test "are :unsupported, with no request", %{opts: opts} do
      assert {:error, %ExAtlas.Error{kind: :unsupported}} = ExAtlas.stop("1", opts)
      assert {:error, %ExAtlas.Error{kind: :unsupported}} = ExAtlas.start("1", opts)
    end
  end

  describe "list_gpu_types/1" do
    test "returns one GpuType per Vast name at its lowest on-demand price", %{
      bypass: bypass,
      opts: opts
    } do
      test_pid = self()

      Bypass.expect(bypass, "POST", "/api/v0/bundles", fn conn ->
        {query, conn} = read_json(conn)
        send(test_pid, {:query, query})

        offers =
          case query["gpu_name"]["in"] do
            ["RTX 4090"] ->
              [
                offer(%{"id" => 1, "dph_total" => 0.51}),
                offer(%{"id" => 2, "dph_total" => 0.39})
              ]

            ["H100 SXM" | _] ->
              [
                offer(%{
                  "id" => 3,
                  "gpu_name" => "H100 SXM",
                  "gpu_ram" => 81_920,
                  "dph_total" => 2.1
                }),
                offer(%{
                  "id" => 4,
                  "gpu_name" => "H100 NVL",
                  "gpu_ram" => 95_830,
                  "dph_total" => 2.4
                })
              ]

            ["A100 SXM4", "A100 PCIE"] ->
              ram = query["gpu_ram"]
              gb = if Map.has_key?(ram, "gte"), do: 81_920, else: 40_960

              [
                offer(%{
                  "id" => 5,
                  "gpu_name" => "A100 SXM4",
                  "gpu_ram" => gb,
                  "dph_total" => gb / 100_000
                })
              ]

            _ ->
              []
          end

        json(conn, 200, %{"offers" => offers})
      end)

      assert {:ok, types} = ExAtlas.list_gpu_types(opts)

      assert [a100_40, a100_80, h100_nvl, h100_sxm, rtx_4090] = types
      assert %Spec.GpuType{id: "RTX 4090", canonical: :rtx_4090, provider: :vast} = rtx_4090
      assert rtx_4090.lowest_price_per_hour == 0.39
      assert rtx_4090.memory_gb == 24
      assert %{id: "H100 SXM", canonical: :h100, memory_gb: 80} = h100_sxm
      assert %{id: "H100 NVL", canonical: :h100, lowest_price_per_hour: 2.4} = h100_nvl
      assert %{id: "A100 SXM4", canonical: :a100_40g, memory_gb: 40} = a100_40
      assert %{id: "A100 SXM4", canonical: :a100_80g, memory_gb: 80} = a100_80

      # One on-demand search per catalog GPU.
      queries =
        for _ <- Spec.GpuCatalog.supported_gpus(:vast) do
          assert_received {:query, query}
          query
        end

      assert Enum.all?(queries, &(&1["type"] == "ondemand"))
    end

    test "a failed search fails the call", %{bypass: bypass, opts: opts} do
      Bypass.expect(bypass, "POST", "/api/v0/bundles", fn conn ->
        json(conn, 401, %{
          "success" => false,
          "error" => "auth_error",
          "msg" => "Invalid user key"
        })
      end)

      assert {:error, %ExAtlas.Error{kind: :unauthorized}} = ExAtlas.list_gpu_types(opts)
    end
  end

  describe "the client" do
    test "every request emits [:ex_atlas, :vast, :request] without the key", %{
      bypass: bypass,
      opts: opts
    } do
      test_pid = self()
      handler = "vast-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:ex_atlas, :vast, :request],
        fn event, measurements, meta, _ -> send(test_pid, {event, measurements, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Bypass.expect_once(bypass, "GET", "/api/v0/instances/28411907", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer vast-test-key"]
        json(conn, 200, %{"instances" => instance()})
      end)

      assert {:ok, _} = ExAtlas.get_compute("28411907", opts)

      assert_received {[:ex_atlas, :vast, :request], %{status: 200}, meta}
      assert meta.url =~ "/api/v0/instances/28411907"
      refute inspect(meta) =~ "vast-test-key"
    end

    test "with no API key, a call is :unauthorized naming VAST_API_KEY, and no request", %{
      opts: opts
    } do
      opts = Keyword.delete(opts, :api_key)
      previous = System.get_env("VAST_API_KEY")
      System.delete_env("VAST_API_KEY")
      on_exit(fn -> if previous, do: System.put_env("VAST_API_KEY", previous) end)

      error =
        try do
          ExAtlas.get_compute("1", opts)
        rescue
          e in ExAtlas.Error -> {:raised, e}
        end

      assert {_, %ExAtlas.Error{kind: :unauthorized, message: message}} = error
      assert message =~ "VAST_API_KEY"
    end
  end
end
