defmodule ExAtlas.Providers.RunPodTest do
  use ExUnit.Case, async: false

  alias ExAtlas.Orchestrator.UpstreamStatus
  alias ExAtlas.Providers.RunPod.Client

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
      caps = ExAtlas.capabilities(:runpod)
      assert :serverless in caps
      assert :http_proxy in caps
      refute :spot in caps
      assert :self_terminate in caps
    end
  end

  describe "spawn_compute/1" do
    test "POSTs /pods and returns a normalized Compute", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["gpu"] == %{"id" => "NVIDIA H100 80GB HBM3", "count" => 1}

        response = %{
          "id" => "pod_abc123",
          "status" => "RUNNING",
          "ports" => ["8000/http"],
          "gpu" => %{"id" => "NVIDIA H100 80GB HBM3", "count" => 1},
          "image" => body["image"]
        }

        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(201, Jason.encode!(response))
      end)

      {:ok, compute} =
        ExAtlas.spawn_compute(
          [gpu: :h100, image: "pytorch:latest", ports: [{8000, :http}], auth: :bearer] ++ opts
        )

      assert compute.provider == :runpod
      assert compute.id == "pod_abc123"
      assert compute.status == :running
      [%{url: url}] = compute.ports
      assert url == "https://pod_abc123-8000.proxy.runpod.net"
      assert compute.auth.scheme == :bearer
    end

    test "template_id with no ports and no disk POSTs neither key", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["templateId"] == "9x4m2p7v"
        refute Map.has_key?(body, "ports")
        refute Map.has_key?(body, "disk")
        json(conn, 201, pod("p1", "RUNNING", "t"))
      end)

      assert {:ok, %{id: "p1"}} =
               ExAtlas.spawn_compute([gpu: :h100, template_id: "9x4m2p7v"] ++ opts)
    end

    test "template_id with ports and container_disk_gb still POSTs both", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"ports" => ["8000/http"], "disk" => 20} = Jason.decode!(raw)
        json(conn, 201, pod("p1", "RUNNING", "t"))
      end)

      assert {:ok, _} =
               ExAtlas.spawn_compute(
                 [gpu: :h100, template_id: "t", ports: [{8000, :http}], container_disk_gb: 20] ++
                   opts
               )
    end

    test "without template_id the body still carries disk 50", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"disk" => 50, "ports" => []} = Jason.decode!(raw)
        json(conn, 201, pod("p1", "RUNNING", "t"))
      end)

      assert {:ok, _} = ExAtlas.spawn_compute([gpu: :h100, image: "x"] ++ opts)
    end

    test "s3: puts the seven staging variables into the POST body env", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:env, Jason.decode!(raw)["env"]})
        json(conn, 201, pod("p1", "RUNNING", "t"))
      end)

      assert {:ok, %{id: "p1"}} =
               ExAtlas.spawn_compute(
                 [
                   gpu: :h100,
                   image: "x",
                   s3: %{
                     endpoint: "https://t3.storage.dev",
                     region: "auto",
                     access_key_id: "tid-test-4b1e",
                     secret_access_key: "tsec-test-9f2c",
                     dataset_uri: "s3://bucket/datasets/abc/",
                     artifact_uri: "s3://bucket/artifacts/run-123/"
                   }
                 ] ++ opts
               )

      assert_receive {:env, env}

      assert env == %{
               "AWS_ENDPOINT_URL_S3" => "https://t3.storage.dev",
               "AWS_REGION" => "auto",
               "AWS_DEFAULT_REGION" => "auto",
               "AWS_ACCESS_KEY_ID" => "tid-test-4b1e",
               "AWS_SECRET_ACCESS_KEY" => "tsec-test-9f2c",
               "ATLAS_DATASET_URI" => "s3://bucket/datasets/abc/",
               "ATLAS_ARTIFACT_URI" => "s3://bucket/artifacts/run-123/"
             }
    end

    test "an invalid s3: raises before any request reaches RunPod", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      test_pid = self()

      Bypass.stub(bypass, "POST", "/pods", fn conn ->
        send(test_pid, :posted)
        json(conn, 201, pod("p1", "RUNNING", "t"))
      end)

      error =
        assert_raise NimbleOptions.ValidationError, fn ->
          ExAtlas.spawn_compute(
            [
              gpu: :h100,
              image: "x",
              s3: %{access_key_id: "tid-test-4b1e", dataset_uri: "s3://bucket/d/"}
            ] ++ opts
          )
        end

      assert error.key == :s3
      refute inspect(error) =~ "tid-test-4b1e"
      # The valid-s3: test above is the control: the same stub path does POST.
      refute_received :posted
    end

    test "a string-keyed s3 option raises without printing it", %{ctx_opts: opts} do
      error =
        assert_raise ArgumentError, fn ->
          ExAtlas.spawn_compute(
            [gpu: :h100, image: "x"] ++ opts ++ [{"s3", %{secret_access_key: "tsec-test-9f2c"}}]
          )
        end

      refute Exception.message(error) =~ "tsec-test-9f2c"
    end

    test "inspect of the compute omits the env RunPod echoes back", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test_pid, {:echoed_env, body["env"]})
        json(conn, 201, Map.put(pod("p1", "RUNNING", "t"), "env", body["env"]))
      end)

      {:ok, compute} =
        ExAtlas.spawn_compute(
          [gpu: :h100, image: "x", env: %{"AWS_SECRET_ACCESS_KEY" => "tsec-test-9f2c"}] ++ opts
        )

      # Control: the response did echo the secret (the stub sends it back).
      assert_received {:echoed_env, %{"AWS_SECRET_ACCESS_KEY" => "tsec-test-9f2c"}}
      refute Map.has_key?(compute.raw, "env")
      assert inspect(compute) =~ ~s(id: "p1")
      refute inspect(compute) =~ "tsec-test-9f2c"
      refute inspect(compute, structs: false, limit: :infinity) =~ "tsec-test-9f2c"
    end

    test "a spawn answered 200 instead of 201 errors without the pod's env", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        json(conn, 200, Map.put(pod("p1", "RUNNING", "t"), "env", body["env"]))
      end)

      assert {:error, %ExAtlas.Error{status: 200} = error} =
               ExAtlas.spawn_compute(
                 [gpu: :h100, image: "x", env: %{"HF_TOKEN" => "hf-secret-5d1"}] ++ opts
               )

      refute inspect(error, structs: false, limit: :infinity) =~ "hf-secret-5d1"
    end

    test "inspect of the compute omits presigned URLs RunPod echoes back", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        send(test_pid, {:echoed_env, body["env"]})
        json(conn, 201, Map.put(pod("p1", "RUNNING", "t"), "env", body["env"]))
      end)

      put_url = "https://bucket.s3.amazonaws.com/a.tar.gz?X-Amz-Signature=putsig-a7e3b2"

      {:ok, compute} =
        ExAtlas.spawn_compute([gpu: :h100, image: "x", s3: %{artifact_url: put_url}] ++ opts)

      # Control: the response did echo the URL (the stub sends it back).
      assert_received {:echoed_env, %{"ATLAS_ARTIFACT_URL" => ^put_url}}
      refute Map.has_key?(compute.raw, "env")
      text = inspect(compute, structs: false, limit: :infinity, printable_limit: :infinity)
      assert text =~ ~s(id: "p1")
      refute text =~ "putsig-a7e3b2"
    end
  end

  describe "get_compute/2" do
    test "GETs /pods/:id and normalizes", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "GET", "/pods/pod_abc", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"id" => "pod_abc", "status" => "RUNNING"})
        )
      end)

      assert {:ok, compute} = ExAtlas.get_compute("pod_abc", opts)
      assert compute.id == "pod_abc"
      assert compute.status == :running
    end

    test "keeps the env RunPod echoes back out of raw", %{bypass: bypass, ctx_opts: opts} do
      echoed = Map.put(pod("pod_abc", "RUNNING", "t"), "env", %{"HF_TOKEN" => "hf-secret-5d1"})
      Bypass.expect_once(bypass, "GET", "/pods/pod_abc", fn conn -> json(conn, 200, echoed) end)

      assert {:ok, compute} = ExAtlas.get_compute("pod_abc", opts)
      assert compute.raw["dataCenterId"] == "US-KS-2"
      refute Map.has_key?(compute.raw, "env")
      refute inspect(compute, structs: false, limit: :infinity) =~ "hf-secret-5d1"
    end

    test "a 200 body that is a list of pods errors without their env", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      echoed = Map.put(pod("pod_abc", "RUNNING", "t"), "env", %{"HF_TOKEN" => "hf-secret-5d1"})
      Bypass.expect_once(bypass, "GET", "/pods/pod_abc", fn conn -> json(conn, 200, [echoed]) end)

      assert {:error, %ExAtlas.Error{kind: :provider} = error} =
               ExAtlas.get_compute("pod_abc", opts)

      assert error.message =~ "unexpected body"
      refute inspect(error, structs: false, limit: :infinity) =~ "hf-secret-5d1"
    end

    test "the status poll's compute holds no echoed env", %{bypass: bypass, ctx_opts: opts} do
      echoed = Map.put(pod("pod_abc", "RUNNING", "t"), "env", %{"HF_TOKEN" => "hf-secret-5d1"})
      Bypass.expect_once(bypass, "GET", "/pods/pod_abc", fn conn -> json(conn, 200, echoed) end)

      assert {:alive, compute} = UpstreamStatus.observe("pod_abc", opts)
      assert compute.raw["dataCenterId"] == "US-KS-2"
      refute inspect(compute, structs: false, limit: :infinity) =~ "hf-secret-5d1"
    end

    test "carries an age the Reaper's grace window can use", %{bypass: bypass, ctx_opts: opts} do
      # `:reap_grace_ms` spares resources younger than the window, and can only
      # do that for a resource whose `:created_at` survives the round trip.
      Bypass.expect_once(bypass, "GET", "/pods/pod_abc", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "pod_abc",
            "status" => "RUNNING",
            "startedAt" => "2024-07-12T19:14:40.144Z"
          })
        )
      end)

      assert {:ok, compute} = ExAtlas.get_compute("pod_abc", opts)
      assert compute.created_at == ~U[2024-07-12 19:14:40.144Z]
    end

    test "a 200 whose body is not a pod object is a :provider error, not a crash", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/pods/pod_abc", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, "null")
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, provider: :runpod}} =
               ExAtlas.get_compute("pod_abc", opts)
    end
  end

  describe "terminate/2" do
    test "DELETEs /pods/:id", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "DELETE", "/pods/pod_abc", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = ExAtlas.terminate("pod_abc", opts)
    end
  end

  describe "spawn_compute/1 failures" do
    test "a 503 on create is returned, never retried into a second pod", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      # expect_once fails the test if a retry reaches the server.
      Bypass.expect_once(bypass, "POST", "/pods", fn conn ->
        json(conn, 503, %{"title" => "Service Unavailable", "status" => 503, "detail" => "busy"})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, status: 503}} =
               ExAtlas.spawn_compute([gpu: :h100, image: "x"] ++ opts)
    end

    # A 429 means RunPod made nothing, so a retry cannot rent a second pod.
    test "a 429 on create is retried, and the second answer makes one pod", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      calls = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/pods", fn conn ->
        :counters.add(calls, 1, 1)

        case :counters.get(calls, 1) do
          1 ->
            conn
            |> Plug.Conn.put_resp_header("retry-after", "0")
            |> json(429, %{"title" => "Too Many Requests", "status" => 429})

          _ ->
            json(conn, 201, %{"id" => "pod_after_429", "status" => "RUNNING"})
        end
      end)

      assert {:ok, %ExAtlas.Spec.Compute{id: "pod_after_429"}} =
               ExAtlas.spawn_compute([gpu: :h100, image: "x"] ++ opts)

      assert :counters.get(calls, 1) == 2
    end
  end

  # Telemetry calls a remote capture faster than an anonymous function.
  def forward_url(_event, _measurements, meta, test_pid), do: send(test_pid, {:url, meta.url})

  describe "telemetry" do
    test "the catalog request event hides the query and the key", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      handler = "runpod-telemetry-#{System.unique_integer()}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ex_atlas, :runpod, :request],
        &__MODULE__.forward_url/4,
        test_pid
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      Bypass.expect(bypass, "GET", "/catalog/gpus", fn conn ->
        json(conn, 200, %{"gpus" => []})
      end)

      {:ok, []} = ExAtlas.list_gpu_types(opts)

      assert_receive {:url, url}
      assert url =~ "/catalog/gpus"
      refute url =~ "?"
      refute url =~ "test-key"
    end
  end

  describe "spot" do
    test "spot: true returns :unsupported and sends no request", %{bypass: bypass, ctx_opts: opts} do
      # Runpod no longer sells spot pods and v2 has no field for them. Any
      # request reaching the server fails this test.
      Bypass.down(bypass)

      assert {:error, %ExAtlas.Error{kind: :unsupported, provider: :runpod}} =
               ExAtlas.spawn_compute([gpu: :h100, image: "x", spot: true] ++ opts)
    end
  end

  describe "REST v2" do
    test "the management API is REST v2" do
      assert Client.management_url() == "https://api.runpod.io/v2"
    end

    for action <- [:stop, :start] do
      test "#{action}/2 POSTs the #{action} action", %{bypass: bypass, ctx_opts: opts} do
        action = unquote(to_string(action))

        Bypass.expect_once(bypass, "POST", "/pods/pod_abc/action", fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(raw) == %{"action" => action}
          json(conn, 200, %{"id" => "pod_abc", "status" => "EXITED"})
        end)

        assert :ok = apply(ExAtlas, unquote(action), ["pod_abc", opts])
      end
    end

    test "a 404 problem body becomes :not_found with its detail", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/pods/gone", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/problem+json")
        |> Plug.Conn.resp(
          404,
          Jason.encode!(%{"title" => "Not Found", "status" => 404, "detail" => "pod not found"})
        )
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found, message: "pod not found"}} =
               ExAtlas.get_compute("gone", opts)
    end

    test "an ERROR pod is observed dead and :failed", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "GET", "/pods/pod_abc", fn conn ->
        json(conn, 200, %{"id" => "pod_abc", "status" => "ERROR"})
      end)

      assert {:dead, :failed, %{id: "pod_abc"}} =
               UpstreamStatus.observe("pod_abc", opts)
    end
  end

  describe "list_compute/1" do
    setup %{bypass: bypass} do
      pods = [
        pod("p1", "RUNNING", "atlas-a"),
        pod("p2", "STARTING", "atlas-b"),
        pod("p3", "ERROR", "atlas-c"),
        pod("p4", "EXITED", "other")
      ]

      # Two pages: the first names a cursor, the second ends the walk.
      Bypass.expect(bypass, "GET", "/pods", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["limit"] == "1000"

        case conn.query_params["cursor"] do
          nil ->
            json(conn, 200, %{
              "pods" => Enum.take(pods, 2),
              "pagination" => %{"nextCursor" => "c2", "hasNextPage" => true}
            })

          "c2" ->
            json(conn, 200, %{
              "pods" => Enum.drop(pods, 2),
              "pagination" => %{"nextCursor" => nil, "hasNextPage" => false}
            })
        end
      end)

      :ok
    end

    test "returns the pods of every page", %{ctx_opts: opts} do
      assert {:ok, computes} = ExAtlas.list_compute(opts)
      assert Enum.map(computes, & &1.id) == ~w(p1 p2 p3 p4)
    end

    test "status: :failed returns the ERROR pod (issue 37)", %{ctx_opts: opts} do
      assert {:ok, [%{id: "p3", status: :failed}]} =
               ExAtlas.list_compute([status: :failed] ++ opts)
    end

    test "status: :running excludes a STARTING pod", %{ctx_opts: opts} do
      assert {:ok, [%{id: "p1"}]} = ExAtlas.list_compute([status: :running] ++ opts)
    end

    test "name: filters by exact name", %{ctx_opts: opts} do
      assert {:ok, [%{id: "p4"}]} = ExAtlas.list_compute([name: "other"] ++ opts)
    end

    test "gpu: and region: filter too", %{ctx_opts: opts} do
      assert {:ok, [_, _, _, _]} = ExAtlas.list_compute([gpu: :rtx_4090] ++ opts)
      assert {:ok, []} = ExAtlas.list_compute([gpu: :h100] ++ opts)
      assert {:ok, []} = ExAtlas.list_compute([region: "EU-RO-1"] ++ opts)
    end
  end

  describe "list_compute/1 env echo" do
    test "keeps the env RunPod echoes back out of every raw", %{bypass: bypass, ctx_opts: opts} do
      echoed = Map.put(pod("p1", "RUNNING", "atlas-a"), "env", %{"HF_TOKEN" => "hf-secret-5d1"})

      Bypass.expect_once(bypass, "GET", "/pods", fn conn ->
        json(conn, 200, %{"pods" => [echoed], "pagination" => %{"hasNextPage" => false}})
      end)

      assert {:ok, [compute]} = ExAtlas.list_compute(opts)
      assert compute.raw["dataCenterId"] == "US-KS-2"
      refute Map.has_key?(compute.raw, "env")
      refute inspect(compute, structs: false, limit: :infinity) =~ "hf-secret-5d1"
    end
  end

  describe "list_compute/1 failures" do
    test "a failed second page fails the call instead of returning half a list", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      Bypass.expect(bypass, "GET", "/pods", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["cursor"] do
          nil ->
            json(conn, 200, %{
              "pods" => [pod("p1", "RUNNING", "atlas-a")],
              "pagination" => %{"nextCursor" => "c2", "hasNextPage" => true}
            })

          "c2" ->
            json(conn, 404, %{"title" => "Not Found", "status" => 404, "detail" => "bad cursor"})
        end
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.list_compute(opts)
    end

    for {label, cursor} <- [{"repeats", "same"}, {"is null", nil}] do
      test "a next page whose cursor #{label} is a :provider error", %{
        bypass: bypass,
        ctx_opts: opts
      } do
        Bypass.expect(bypass, "GET", "/pods", fn conn ->
          json(conn, 200, %{
            "pods" => [pod("p1", "RUNNING", "atlas-a")],
            "pagination" => %{"nextCursor" => unquote(cursor), "hasNextPage" => true}
          })
        end)

        assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
                 ExAtlas.list_compute(opts)

        assert message =~ "did not advance"
      end
    end

    test "a cursor that never ends stops after 100 pages", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect(bypass, "GET", "/pods", fn conn ->
        json(conn, 200, %{
          "pods" => [],
          "pagination" => %{
            "nextCursor" => Integer.to_string(System.unique_integer([:positive])),
            "hasNextPage" => true
          }
        })
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
               ExAtlas.list_compute(opts)

      assert message =~ "100 pages"
    end

    test "a page holding a non-object entry is a :provider error", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/pods", fn conn ->
        json(conn, 200, %{
          "pods" => [pod("p1", "RUNNING", "atlas-a"), nil],
          "pagination" => %{"nextCursor" => nil, "hasNextPage" => false}
        })
      end)

      assert {:error, %ExAtlas.Error{kind: :provider}} = ExAtlas.list_compute(opts)
    end

    test "a body that is not a pod list is a :provider error", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "GET", "/pods", fn conn -> json(conn, 200, [%{"id" => "p1"}]) end)

      assert {:error, %ExAtlas.Error{kind: :provider}} = ExAtlas.list_compute(opts)
    end
  end

  defp pod(id, status, name) do
    %{
      "id" => id,
      "name" => name,
      "status" => status,
      "gpu" => %{"id" => "NVIDIA GeForce RTX 4090", "count" => 1},
      "dataCenterId" => "US-KS-2",
      "ports" => [],
      "runtime" => nil,
      "createdAt" => "2026-06-01T12:00:00Z",
      "startedAt" => nil
    }
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  describe "error handling" do
    test "401 becomes :unauthorized", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "DELETE", "/pods/x", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error" => "bad key"}))
      end)

      assert {:error, %ExAtlas.Error{kind: :unauthorized, provider: :runpod, status: 401}} =
               ExAtlas.terminate("x", opts)
    end
  end

  describe "list_gpu_types/1" do
    defp fixture_body(cloud),
      do: File.read!("test/fixtures/runpod/v2/catalog_gpus_#{cloud}.json")

    defp expect_catalog(bypass, fun) do
      Bypass.expect(bypass, "GET", "/catalog/gpus", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")
        fun.(conn, conn.query_params)
      end)
    end

    defp raw_json(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(status, body)
    end

    test "reads SECURE then COMMUNITY from the v2 catalog and merges them", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      test_pid = self()

      expect_catalog(bypass, fn conn, params ->
        send(test_pid, {:params, params})
        raw_json(conn, 200, fixture_body(String.downcase(params["cloud"])))
      end)

      assert {:ok, gpus} = ExAtlas.list_gpu_types(opts)

      assert_received {:params, secure}
      assert_received {:params, community}

      assert secure == %{"include" => "AVAILABILITY", "product" => "POD", "cloud" => "SECURE"}
      assert community == %{secure | "cloud" => "COMMUNITY"}

      assert %{stock: :low, lowest_price_per_hour: 0.34, spot_price_per_hour: nil} =
               Enum.find(gpus, &(&1.id == "NVIDIA GeForce RTX 4090"))
    end

    test "a 401 is unauthorized, and the same context lists on a 200", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/catalog/gpus", &json(&1, 401, %{"title" => "no"}))

      assert {:error, %ExAtlas.Error{kind: :unauthorized, status: 401}} =
               ExAtlas.list_gpu_types(opts ++ [req_options: [retry: false]])

      expect_catalog(bypass, fn conn, params ->
        raw_json(conn, 200, fixture_body(String.downcase(params["cloud"])))
      end)

      assert {:ok, [_ | _]} = ExAtlas.list_gpu_types(opts)
    end

    test "a 403 is an error with its status", %{bypass: bypass, ctx_opts: opts} do
      Bypass.expect_once(bypass, "GET", "/catalog/gpus", &json(&1, 403, %{"title" => "no"}))

      assert {:error, %ExAtlas.Error{status: 403}} = ExAtlas.list_gpu_types(opts)
    end

    test "a failed COMMUNITY read returns an error, never a partial list", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      expect_catalog(bypass, fn conn, params ->
        case params["cloud"] do
          "SECURE" -> raw_json(conn, 200, fixture_body("secure"))
          "COMMUNITY" -> json(conn, 400, %{"title" => "bad"})
        end
      end)

      assert {:error, %ExAtlas.Error{status: 400}} = ExAtlas.list_gpu_types(opts)
    end

    test "a 200 with no gpus list is a provider error", %{bypass: bypass, ctx_opts: opts} do
      expect_catalog(bypass, fn conn, _ -> json(conn, 200, %{"nope" => []}) end)

      assert {:error, %ExAtlas.Error{kind: :provider}} = ExAtlas.list_gpu_types(opts)
    end

    test "a gpus list holding a non-object entry is a provider error", %{
      bypass: bypass,
      ctx_opts: opts
    } do
      expect_catalog(bypass, fn conn, _ -> json(conn, 200, %{"gpus" => [42]}) end)

      assert {:error, %ExAtlas.Error{kind: :provider}} = ExAtlas.list_gpu_types(opts)
    end
  end

  describe "serverless jobs through the top-level API" do
    setup %{bypass: bypass, ctx_opts: opts} do
      # `Client.runtime/2` always targets api.runpod.ai; route it at Bypass with
      # `req_options`.
      job_opts =
        Keyword.merge(opts,
          endpoint: "abc123",
          req_options: [base_url: "http://localhost:#{bypass.port}"]
        )

      {:ok, job_opts: job_opts}
    end

    test "get_job/2 carries :endpoint through to the runtime API", %{
      bypass: bypass,
      job_opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/status/job_1", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"id" => "job_1", "status" => "COMPLETED", "output" => %{"ok" => true}})
        )
      end)

      assert {:ok, job} = ExAtlas.get_job("job_1", opts)
      assert job.id == "job_1"
      assert job.status == :completed
      assert job.endpoint == "abc123"
    end

    test "cancel_job/2 carries :endpoint through to the runtime API", %{
      bypass: bypass,
      job_opts: opts
    } do
      Bypass.expect_once(bypass, "POST", "/cancel/job_1", fn conn ->
        Plug.Conn.resp(conn, 200, "{}")
      end)

      assert :ok = ExAtlas.cancel_job("job_1", opts)
    end

    test "cancel_job/2 without :endpoint returns a validation error", %{ctx_opts: opts} do
      assert {:error, %ExAtlas.Error{kind: :validation, provider: :runpod}} =
               ExAtlas.cancel_job("job_1", opts)
    end

    test "stream_job/2 carries :endpoint through to the runtime API", %{
      bypass: bypass,
      job_opts: opts
    } do
      Bypass.expect_once(bypass, "GET", "/stream/job_1", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"status" => "COMPLETED", "stream" => [%{"output" => "chunk-1"}]})
        )
      end)

      chunks = "job_1" |> ExAtlas.stream_job(opts) |> Enum.take(1)

      assert chunks == [%{"output" => "chunk-1"}]
    end

    test "get_job/2 still reports a validation error when no endpoint is given", %{
      job_opts: opts
    } do
      assert {:error, %ExAtlas.Error{kind: :validation}} =
               ExAtlas.get_job("job_1", Keyword.delete(opts, :endpoint))
    end
  end

  describe "network volumes" do
    alias ExAtlas.Providers.RunPod
    alias ExAtlas.Spec.NetworkVolume

    @volume %{
      "id" => "2q9m7x4c",
      "name" => "datasets",
      "size" => 200,
      "dataCenter" => "EU-RO-1",
      "type" => "HIGH_PERFORMANCE"
    }

    setup %{ctx_opts: opts}, do: {:ok, ctx: ExAtlas.Config.build_ctx(:runpod, opts)}

    defp volume_request(opts \\ []) do
      ExAtlas.Spec.NetworkVolumeRequest.new!(
        Keyword.merge([name: "datasets", size_gb: 200, region: "EU-RO-1"], opts)
      )
    end

    test "capabilities include :manage_network_volumes" do
      assert :manage_network_volumes in RunPod.capabilities()
    end

    test "create POSTs name, size and dataCenter and returns a NetworkVolume", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "POST", "/network-volumes", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "name" => "datasets",
                 "size" => 200,
                 "dataCenter" => "EU-RO-1"
               }

        json(conn, 201, @volume)
      end)

      assert {:ok,
              %NetworkVolume{
                id: "2q9m7x4c",
                provider: :runpod,
                size_gb: 200,
                region: "EU-RO-1",
                tier: :high_performance
              }} = RunPod.create_network_volume(volume_request(), ctx)
    end

    test "create with tier: :standard sends type STANDARD", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/network-volumes", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"type" => "STANDARD"} = Jason.decode!(raw)
        json(conn, 201, %{@volume | "type" => "STANDARD"})
      end)

      assert {:ok, %NetworkVolume{tier: :standard}} =
               RunPod.create_network_volume(volume_request(tier: :standard), ctx)
    end

    test "create with no region is a :validation error and sends no request", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.down(bypass)

      assert {:error, %ExAtlas.Error{kind: :validation, provider: :runpod, message: message}} =
               RunPod.create_network_volume(volume_request(region: nil), ctx)

      assert message =~ "region"
    end

    test "create surfaces a provider refusal", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/network-volumes", fn conn ->
        json(conn, 400, %{"error" => "size out of range"})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider}} =
               RunPod.create_network_volume(volume_request(), ctx)
    end

    test "list returns one NetworkVolume per entry of networkVolumes", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "GET", "/network-volumes", fn conn ->
        json(conn, 200, %{"networkVolumes" => [@volume, %{@volume | "id" => "b"}]})
      end)

      assert {:ok, [%NetworkVolume{id: "2q9m7x4c"}, %NetworkVolume{id: "b"}]} =
               RunPod.list_network_volumes(ctx)
    end

    test "list with no volumes returns an empty list", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/network-volumes", fn conn ->
        json(conn, 200, %{"networkVolumes" => []})
      end)

      assert {:ok, []} = RunPod.list_network_volumes(ctx)
    end

    test "a 200 list body with no networkVolumes list is a :provider error", %{
      bypass: bypass,
      ctx: ctx
    } do
      for body <- [%{"other" => 1}, [@volume], %{"networkVolumes" => "x"}] do
        Bypass.expect_once(bypass, "GET", "/network-volumes", fn conn -> json(conn, 200, body) end)

        assert {:error, %ExAtlas.Error{kind: :provider, provider: :runpod}} =
                 RunPod.list_network_volumes(ctx)
      end
    end

    test "a list entry that is not an object is a :provider error", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/network-volumes", fn conn ->
        json(conn, 200, %{"networkVolumes" => [@volume, "oops"]})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider}} = RunPod.list_network_volumes(ctx)
    end

    test "get returns the volume", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/network-volumes/2q9m7x4c", fn conn ->
        json(conn, 200, @volume)
      end)

      assert {:ok, %NetworkVolume{id: "2q9m7x4c", name: "datasets"}} =
               RunPod.get_network_volume("2q9m7x4c", ctx)
    end

    test "get of a missing volume is :not_found", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/network-volumes/gone", fn conn ->
        json(conn, 404, %{"error" => "not found"})
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = RunPod.get_network_volume("gone", ctx)
    end

    test "get with a 200 body that is not an object is a :provider error", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "GET", "/network-volumes/x", fn conn ->
        Plug.Conn.resp(conn, 200, "null")
      end)

      assert {:error, %ExAtlas.Error{kind: :provider}} = RunPod.get_network_volume("x", ctx)
    end

    test "delete returns :ok on 204", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "DELETE", "/network-volumes/2q9m7x4c", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = RunPod.delete_network_volume("2q9m7x4c", ctx)
    end

    test "delete of a missing volume is :not_found", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "DELETE", "/network-volumes/gone", fn conn ->
        json(conn, 404, %{"error" => "not found"})
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} =
               RunPod.delete_network_volume("gone", ctx)
    end
  end

  describe "templates" do
    alias ExAtlas.Providers.RunPod
    alias ExAtlas.Spec.Template

    @template %{
      "id" => "9x4m2p7v",
      "name" => "trainer-v7",
      "image" => "ghcr.io/acme/trainer:7",
      "args" => "",
      "disk" => 80,
      "mounts" => %{"persistent" => %{"size" => 100, "path" => "/workspace"}},
      "ports" => ["8000/http"],
      "env" => %{"WANDB_PROJECT" => "atlas", "WANDB_API_KEY" => "s3cr3t-value"},
      "serverless" => false,
      "startSsh" => true,
      "startJupyter" => true
    }

    setup %{ctx_opts: opts}, do: {:ok, ctx: ExAtlas.Config.build_ctx(:runpod, opts)}

    defp template_request(opts \\ []) do
      ExAtlas.Spec.TemplateRequest.new!(
        Keyword.merge(
          [
            name: "trainer-v7",
            image: "ghcr.io/acme/trainer:7",
            ports: [{8000, :http}],
            env: %{"WANDB_PROJECT" => "atlas"},
            container_disk_gb: 80,
            volume_gb: 100
          ],
          opts
        )
      )
    end

    test "capabilities include :manage_templates" do
      assert :manage_templates in RunPod.capabilities()
    end

    test "create POSTs the template body and returns a Template", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/templates", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "name" => "trainer-v7",
                 "image" => "ghcr.io/acme/trainer:7",
                 "ports" => ["8000/http"],
                 "env" => %{"WANDB_PROJECT" => "atlas"},
                 "disk" => 80,
                 "mounts" => %{"persistent" => %{"size" => 100, "path" => "/workspace"}}
               }

        json(conn, 201, @template)
      end)

      assert {:ok,
              %Template{
                id: "9x4m2p7v",
                provider: :runpod,
                image: "ghcr.io/acme/trainer:7",
                ports: [{8000, :http}],
                container_disk_gb: 80,
                volume_gb: 100
              }} = RunPod.create_template(template_request(), ctx)
    end

    test "create with ssh: false and jupyter: false sends both as false", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "POST", "/templates", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert %{"startSsh" => false, "startJupyter" => false} = Jason.decode!(raw)
        json(conn, 201, %{@template | "startSsh" => false, "startJupyter" => false})
      end)

      assert {:ok, %Template{ssh: false, jupyter: false}} =
               RunPod.create_template(template_request(ssh: false, jupyter: false), ctx)
    end

    test "create without ssh and jupyter sends neither key", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/templates", fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        refute Map.has_key?(body, "startSsh")
        refute Map.has_key?(body, "startJupyter")
        json(conn, 201, @template)
      end)

      assert {:ok, %Template{}} = RunPod.create_template(template_request(), ctx)
    end

    test "create surfaces a provider refusal", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "POST", "/templates", fn conn ->
        json(conn, 400, %{"error" => "bad image"})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider}} =
               RunPod.create_template(template_request(), ctx)
    end

    test "list returns the templates of every page", %{bypass: bypass, ctx: ctx} do
      Bypass.expect(bypass, "GET", "/templates", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["cursor"] do
          nil ->
            json(conn, 200, %{
              "templates" => [@template],
              "pagination" => %{"nextCursor" => "c2", "hasNextPage" => true}
            })

          "c2" ->
            json(conn, 200, %{
              "templates" => [%{@template | "id" => "b"}],
              "pagination" => %{"nextCursor" => nil, "hasNextPage" => false}
            })
        end
      end)

      assert {:ok, [%Template{id: "9x4m2p7v"}, %Template{id: "b"}]} =
               RunPod.list_templates(ctx)
    end

    test "list fails whole when the second page fails", %{bypass: bypass, ctx: ctx} do
      Bypass.expect(bypass, "GET", "/templates", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["cursor"] do
          nil ->
            json(conn, 200, %{
              "templates" => [@template],
              "pagination" => %{"nextCursor" => "c2", "hasNextPage" => true}
            })

          "c2" ->
            json(conn, 404, %{"error" => "bad cursor"})
        end
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = RunPod.list_templates(ctx)
    end

    test "get returns the template", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/templates/9x4m2p7v", fn conn ->
        json(conn, 200, @template)
      end)

      assert {:ok, %Template{id: "9x4m2p7v", name: "trainer-v7"}} =
               RunPod.get_template("9x4m2p7v", ctx)
    end

    test "get of a missing template is :not_found", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/templates/gone", fn conn ->
        json(conn, 404, %{"error" => "not found"})
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = RunPod.get_template("gone", ctx)
    end

    test "get with a 200 body that is not an object is a :provider error without the body", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "GET", "/templates/x", fn conn ->
        json(conn, 200, [@template])
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, raw: nil} = error} =
               RunPod.get_template("x", ctx)

      refute inspect(error) =~ "s3cr3t-value"
    end

    test "inspect of a returned template does not show an env value", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/templates/9x4m2p7v", fn conn ->
        json(conn, 200, @template)
      end)

      {:ok, template} = RunPod.get_template("9x4m2p7v", ctx)
      assert template.env["WANDB_API_KEY"] == "s3cr3t-value"
      refute inspect(template) =~ "s3cr3t-value"
    end

    test "delete returns :ok on 204", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "DELETE", "/templates/9x4m2p7v", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = RunPod.delete_template("9x4m2p7v", ctx)
    end

    test "delete of a template in use is a refusal, not :ok", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "DELETE", "/templates/busy", fn conn ->
        json(conn, 400, %{"error" => "template is in use"})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider}} = RunPod.delete_template("busy", ctx)
    end

    test "delete of a missing template is :not_found", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "DELETE", "/templates/gone", fn conn ->
        json(conn, 404, %{"error" => "not found"})
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = RunPod.delete_template("gone", ctx)
    end
  end

  describe "serverless endpoints" do
    alias ExAtlas.Providers.RunPod
    alias ExAtlas.Spec.Endpoint

    @endpoint %{
      "id" => "4m7x2k9q",
      "name" => "image-generator",
      "type" => "QUEUE",
      "env" => %{"HF_TOKEN" => "s3cr3t-value"},
      "gpu" => %{"pools" => ["ADA_24"], "count" => 1},
      "workers" => %{"min" => 0, "max" => 3},
      "dataCenterIds" => ["US-TX-3"],
      "networkVolumes" => []
    }

    setup %{ctx_opts: opts}, do: {:ok, ctx: ExAtlas.Config.build_ctx(:runpod, opts)}

    test "capabilities include :manage_endpoints" do
      assert :manage_endpoints in RunPod.capabilities()
    end

    test "list returns the endpoints of every page", %{bypass: bypass, ctx: ctx} do
      Bypass.expect(bypass, "GET", "/serverless", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["cursor"] do
          nil ->
            json(conn, 200, %{
              "endpoints" => [@endpoint],
              "pagination" => %{"nextCursor" => "c2", "hasNextPage" => true}
            })

          "c2" ->
            json(conn, 200, %{
              "endpoints" => [%{@endpoint | "id" => "b", "type" => "LOAD_BALANCER"}],
              "pagination" => %{"nextCursor" => nil, "hasNextPage" => false}
            })
        end
      end)

      assert {:ok,
              [
                %Endpoint{id: "4m7x2k9q", type: :queue, workers_max: 3},
                %Endpoint{id: "b", type: :load_balancer}
              ]} = RunPod.list_endpoints(ctx)
    end

    test "list fails whole when the second page fails", %{bypass: bypass, ctx: ctx} do
      Bypass.expect(bypass, "GET", "/serverless", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["cursor"] do
          nil ->
            json(conn, 200, %{
              "endpoints" => [@endpoint],
              "pagination" => %{"nextCursor" => "c2", "hasNextPage" => true}
            })

          "c2" ->
            json(conn, 404, %{"error" => "bad cursor"})
        end
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = RunPod.list_endpoints(ctx)
    end

    test "get returns the endpoint", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/serverless/4m7x2k9q", fn conn ->
        json(conn, 200, @endpoint)
      end)

      assert {:ok,
              %Endpoint{
                id: "4m7x2k9q",
                provider: :runpod,
                name: "image-generator",
                gpu_pools: ["ADA_24"],
                region_hints: ["US-TX-3"]
              }} = RunPod.get_endpoint("4m7x2k9q", ctx)
    end

    test "get of a missing endpoint is :not_found", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/serverless/gone", fn conn ->
        json(conn, 404, %{"error" => "not found"})
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = RunPod.get_endpoint("gone", ctx)
    end

    test "get with a 200 body that is not an object is a :provider error without the body", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "GET", "/serverless/x", fn conn ->
        json(conn, 200, [@endpoint])
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, raw: nil} = error} =
               RunPod.get_endpoint("x", ctx)

      refute inspect(error) =~ "s3cr3t-value"
    end

    test "inspect of a returned endpoint does not show an env value", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "GET", "/serverless/4m7x2k9q", fn conn ->
        json(conn, 200, @endpoint)
      end)

      {:ok, endpoint} = RunPod.get_endpoint("4m7x2k9q", ctx)
      refute Map.has_key?(endpoint.raw, "env")
      refute inspect(endpoint) =~ "s3cr3t-value"
    end

    test "delete returns :ok on 204", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "DELETE", "/serverless/4m7x2k9q", fn conn ->
        Plug.Conn.resp(conn, 204, "")
      end)

      assert :ok = RunPod.delete_endpoint("4m7x2k9q", ctx)
    end

    test "delete of an endpoint RunPod refuses is an error, not :ok", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "DELETE", "/serverless/busy", fn conn ->
        json(conn, 400, %{"error" => "endpoint has active workers"})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider}} = RunPod.delete_endpoint("busy", ctx)
    end

    test "delete of a missing endpoint is :not_found", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "DELETE", "/serverless/gone", fn conn ->
        json(conn, 404, %{"error" => "not found"})
      end)

      assert {:error, %ExAtlas.Error{kind: :not_found}} = RunPod.delete_endpoint("gone", ctx)
    end
  end

  describe "endpoint and template env stays out of raw" do
    alias ExAtlas.Providers.RunPod

    @env_secret "tsec-env-4e7a"
    @env_leaf %{"HF_TOKEN" => @env_secret, "MODEL" => "llama"}
    @env_endpoint %{
      "id" => "ep1",
      "name" => "gen",
      "type" => "QUEUE",
      "env" => @env_leaf,
      "template" => %{"id" => "t1", "image" => "img", "env" => @env_leaf},
      "workers" => %{"min" => 0, "max" => 3}
    }
    @env_template %{
      "id" => "t1",
      "name" => "trainer",
      "image" => "img",
      "env" => @env_leaf,
      "disk" => 80
    }

    setup %{ctx_opts: opts}, do: {:ok, ctx: ExAtlas.Config.build_ctx(:runpod, opts)}

    # Every print path a crash report or a log line can take.
    defp prints(term),
      do: inspect(term, structs: false, limit: :infinity, printable_limit: :infinity)

    defp page(key, entries, next),
      do: %{key => entries, "pagination" => %{"nextCursor" => next, "hasNextPage" => next != nil}}

    defp serve_pages(bypass, path, key, entry) do
      test_pid = self()

      Bypass.expect(bypass, "GET", path, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:served, Jason.encode!(entry)})

        case conn.query_params["cursor"] do
          nil -> json(conn, 200, page(key, [entry], "c2"))
          "c2" -> json(conn, 200, page(key, [%{entry | "id" => "b"}], nil))
        end
      end)
    end

    test "get_endpoint drops env and template env from raw", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/serverless/ep1", fn conn ->
        json(conn, 200, @env_endpoint)
      end)

      assert {:ok, endpoint} = RunPod.get_endpoint("ep1", ctx)
      refute Map.has_key?(endpoint.raw, "env")
      refute Map.has_key?(endpoint.raw["template"], "env")
      refute prints(endpoint) =~ @env_secret
      refute prints(endpoint) =~ "HF_TOKEN"
    end

    test "get_endpoint keeps every other key of raw", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/serverless/ep1", fn conn ->
        json(conn, 200, @env_endpoint)
      end)

      assert {:ok, endpoint} = RunPod.get_endpoint("ep1", ctx)

      assert endpoint.raw == %{
               "id" => "ep1",
               "name" => "gen",
               "type" => "QUEUE",
               "template" => %{"id" => "t1", "image" => "img"},
               "workers" => %{"min" => 0, "max" => 3}
             }
    end

    test "list_endpoints drops env from every page", %{bypass: bypass, ctx: ctx} do
      serve_pages(bypass, "/serverless", "endpoints", @env_endpoint)

      assert {:ok, [%{id: "ep1"} = first, %{id: "b"} = second]} = RunPod.list_endpoints(ctx)
      assert_received {:served, served}
      assert served =~ @env_secret

      for endpoint <- [first, second] do
        refute prints(endpoint) =~ @env_secret
        refute Map.has_key?(endpoint.raw, "env")
      end
    end

    test "a template, listed, fetched or created, keeps env out of raw", %{
      bypass: bypass,
      ctx: ctx
    } do
      Bypass.expect_once(bypass, "GET", "/templates/t1", fn conn ->
        json(conn, 200, @env_template)
      end)

      Bypass.expect_once(bypass, "POST", "/templates", fn conn ->
        json(conn, 201, @env_template)
      end)

      request =
        ExAtlas.Spec.TemplateRequest.new!(name: "trainer", image: "img", env: @env_leaf)

      assert {:ok, fetched} = RunPod.get_template("t1", ctx)
      assert {:ok, created} = RunPod.create_template(request, ctx)

      serve_pages(bypass, "/templates", "templates", @env_template)
      assert {:ok, [listed, _]} = RunPod.list_templates(ctx)

      for template <- [fetched, created, listed] do
        refute Map.has_key?(template.raw, "env")
        refute prints(template.raw) =~ @env_secret
        # Control: the normalized field still carries the configured env.
        assert template.env == @env_leaf
      end
    end

    test "a response with no env keeps its whole raw", %{bypass: bypass, ctx: ctx} do
      endpoint = Map.drop(@env_endpoint, ["env"]) |> Map.put("template", %{"id" => "t1"})
      template = Map.delete(@env_template, "env")

      Bypass.expect_once(bypass, "GET", "/serverless/ep1", fn conn ->
        json(conn, 200, endpoint)
      end)

      Bypass.expect_once(bypass, "GET", "/templates/t1", fn conn -> json(conn, 200, template) end)

      assert {:ok, %{raw: ^endpoint}} = RunPod.get_endpoint("ep1", ctx)
      assert {:ok, %{raw: ^template}} = RunPod.get_template("t1", ctx)
    end
  end

  describe "compute_spend/3" do
    alias ExAtlas.Providers.RunPod
    alias ExAtlas.Spec.Spend

    setup %{ctx_opts: opts}, do: {:ok, ctx: ExAtlas.Config.build_ctx(:runpod, opts)}

    @spend_body %{
      "records" => [
        %{
          "startTime" => "2026-09-01T00:00:00Z",
          "endTime" => "2026-09-02T00:00:00Z",
          "podId" => "pod_9",
          "totalAmount" => 12.34,
          "gpuAmount" => 11.1,
          "cpuAmount" => 0,
          "diskAmount" => 1.24
        }
      ],
      "metadata" => %{
        "query" => %{
          "startTime" => "2026-09-01T00:00:00Z",
          "endTime" => "2026-10-02T00:00:00Z",
          "bucketSize" => "day",
          "podId" => "pod_9"
        },
        "recordCount" => 1,
        "uniquePodCount" => 1,
        "totals" => %{
          "totalAmount" => 12.34,
          "gpuAmount" => 11.1,
          "cpuAmount" => 0,
          "diskAmount" => 1.24
        }
      }
    }

    defp expect_spend(bypass, body \\ @spend_body) do
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/billing/pods", fn conn ->
        send(test_pid, {:query, URI.decode_query(conn.query_string)})
        json(conn, 200, body)
      end)
    end

    test "capabilities include :billing" do
      assert :billing in RunPod.capabilities()
    end

    test "asks for the pod and returns its totals as dollars", %{bypass: bypass, ctx: ctx} do
      expect_spend(bypass)

      assert {:ok,
              %Spend{
                compute_id: "pod_9",
                provider: :runpod,
                total_usd: 12.34,
                gpu_usd: 11.1,
                cpu_usd: +0.0,
                disk_usd: 1.24
              }} = RunPod.compute_spend("pod_9", [], ctx)

      assert_received {:query, %{"podId" => "pod_9"}}
    end

    test "with no window it sends neither startTime nor endTime", %{bypass: bypass, ctx: ctx} do
      expect_spend(bypass)

      assert {:ok, %Spend{}} = RunPod.compute_spend("pod_9", [], ctx)
      assert_received {:query, query}
      assert query == %{"podId" => "pod_9"}
    end

    test "from and to become RFC 3339 startTime and endTime", %{bypass: bypass, ctx: ctx} do
      expect_spend(bypass)

      assert {:ok, %Spend{}} =
               RunPod.compute_spend(
                 "pod_9",
                 [from: ~U[2026-09-30 00:00:00Z], to: ~U[2026-10-01 12:30:00Z]],
                 ctx
               )

      assert_received {:query,
                       %{
                         "podId" => "pod_9",
                         "startTime" => "2026-09-30T00:00:00Z",
                         "endTime" => "2026-10-01T12:30:00Z"
                       }}
    end

    test "from alone sends startTime and no endTime", %{bypass: bypass, ctx: ctx} do
      expect_spend(bypass)

      assert {:ok, %Spend{}} =
               RunPod.compute_spend("pod_9", [from: ~U[2026-09-30 00:00:00Z]], ctx)

      assert_received {:query, query}
      assert query == %{"podId" => "pod_9", "startTime" => "2026-09-30T00:00:00Z"}
    end

    test "from and to are the window RunPod resolved", %{bypass: bypass, ctx: ctx} do
      expect_spend(bypass)

      assert {:ok, %Spend{from: ~U[2026-09-01 00:00:00Z], to: ~U[2026-10-02 00:00:00Z]}} =
               RunPod.compute_spend("pod_9", [], ctx)
    end

    test "a pod with no records is 0.0 dollars", %{bypass: bypass, ctx: ctx} do
      zero = %{"totalAmount" => 0, "gpuAmount" => 0, "cpuAmount" => 0, "diskAmount" => 0}
      body = %{"records" => [], "metadata" => %{"totals" => zero, "recordCount" => 0}}
      expect_spend(bypass, body)

      assert {:ok, %Spend{total_usd: +0.0, gpu_usd: +0.0, cpu_usd: +0.0, disk_usd: +0.0}} =
               RunPod.compute_spend("pod_9", [], ctx)
    end

    test "a body with no metadata.totals is a :provider error", %{bypass: bypass, ctx: ctx} do
      expect_spend(bypass, %{"records" => []})

      assert {:error, %ExAtlas.Error{kind: :provider, provider: :runpod, message: message}} =
               RunPod.compute_spend("pod_9", [], ctx)

      assert message =~ "/billing/pods"
    end

    test "surfaces a provider refusal", %{bypass: bypass, ctx: ctx} do
      Bypass.expect_once(bypass, "GET", "/billing/pods", fn conn ->
        json(conn, 401, %{"error" => "bad key"})
      end)

      assert {:error, %ExAtlas.Error{kind: :unauthorized}} =
               RunPod.compute_spend("pod_9", [], ctx)
    end
  end
end
