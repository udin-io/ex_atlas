defmodule Atlas.Providers.RunPodTest do
  use ExUnit.Case, async: false

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    ctx_opts = [
      provider: :runpod,
      api_key: "test-key",
      base_url: base_url
    ]

    {:ok, bypass: bypass, ctx_opts: ctx_opts}
  end

  describe "capabilities/0" do
    test "reports the documented set" do
      caps = Atlas.capabilities(:runpod)
      assert :serverless in caps
      assert :http_proxy in caps
      assert :spot in caps
    end
  end

  describe "spawn_compute/1" do
    test "POSTs /pods and returns a normalized Compute", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["gpuTypeIds"] == ["NVIDIA H100 80GB HBM3"]

        response = %{
          "id" => "pod_abc123",
          "desiredStatus" => "RUNNING",
          "ports" => "8000/http",
          "gpuCount" => 1,
          "imageName" => body["imageName"]
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(201, Jason.encode!(response))
      end)

      {:ok, compute} =
        Atlas.spawn_compute(
          [gpu: :h100, image: "pytorch:latest", ports: [{8000, :http}], auth: :bearer] ++ opts
        )

      assert compute.provider == :runpod
      assert compute.id == "pod_abc123"
      assert compute.status == :running
      [%{url: url}] = compute.ports
      assert url == "https://pod_abc123-8000.proxy.runpod.net"
      assert compute.auth.scheme == :bearer
    end
  end

  describe "terminate/2" do
    test "DELETEs /pods/:id", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "DELETE", "/pods/pod_abc", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert :ok = Atlas.terminate("pod_abc", opts)
    end
  end

  describe "error handling" do
    test "401 becomes :unauthorized", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "DELETE", "/pods/x", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error" => "bad key"}))
      end)

      assert {:error, %Atlas.Error{kind: :unauthorized, provider: :runpod, status: 401}} =
               Atlas.terminate("x", opts)
    end
  end

  describe "list_gpu_types/1 (GraphQL)" do
    test "hits /graphql and normalizes", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "POST", "/", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(raw)
        assert payload["query"] =~ "gpuTypes"

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "data" => %{
              "gpuTypes" => [
                %{
                  "id" => "NVIDIA H100 80GB HBM3",
                  "displayName" => "H100 80GB",
                  "memoryInGb" => 80,
                  "secureCloud" => true,
                  "communityCloud" => false,
                  "lowestPrice" => %{
                    "minimumBidPrice" => 1.2,
                    "uninterruptablePrice" => 2.49
                  },
                  "stockStatus" => "High"
                }
              ]
            }
          })
        )
      end)

      # Point the GraphQL client at the Bypass server too — Client.graphql/1 uses @graphql_url
      # by default, but our test rig needs it routed to Bypass.
      opts_with_req =
        opts ++
          [
            req_options: [
              base_url: "http://localhost:#{bypass.port}/",
              params: [api_key: "test-key"]
            ]
          ]

      {:ok, [gpu]} = Atlas.list_gpu_types(opts_with_req)

      assert gpu.provider == :runpod
      assert gpu.display_name == "H100 80GB"
      assert gpu.memory_gb == 80
      assert gpu.lowest_price_per_hour == 2.49
      assert gpu.spot_price_per_hour == 1.2
      assert gpu.stock == :high
    end
  end
end
