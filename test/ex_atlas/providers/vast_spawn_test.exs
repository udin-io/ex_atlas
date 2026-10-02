defmodule ExAtlas.Providers.VastSpawnTest do
  # Bypass stands in for Vast's API. A refusal test registers no route for
  # PUT /api/v0/asks/:id, so a rent fails the test.
  use ExUnit.Case, async: false

  import ExAtlas.Test.FakeVast

  @bundles "/api/v0/bundles"

  # Distinctive, so a `refute =~` cannot pass on a common substring.
  @hf_token "hf-probe-7c1d9e"

  setup do
    bypass = Bypass.open()

    opts = [
      provider: :vast,
      api_key: "vast-test-key",
      base_url: "http://localhost:#{bypass.port}",
      gpu: :rtx_4090,
      image: "vllm/vllm-openai:latest"
    ]

    {:ok, bypass: bypass, opts: opts}
  end

  # Answers the offer search with `offers` and sends its body to the test.
  defp expect_search(bypass, offers) do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", @bundles, fn conn ->
      {query, conn} = read_json(conn)
      send(test_pid, {:search, query})
      json(conn, 200, %{"offers" => offers})
    end)
  end

  # Answers each rent with `answer.(offer_id)` and sends the body to the test.
  defp expect_rents(bypass, answer) do
    test_pid = self()

    Bypass.expect(bypass, "PUT", "/api/v0/asks/:id", fn conn ->
      {body, conn} = read_json(conn)
      id = List.last(conn.path_info)
      send(test_pid, {:rent, id, body})
      {status, reply} = answer.(id)
      json(conn, status, reply)
    end)
  end

  defp rent_spawn(opts, extra \\ []), do: ExAtlas.spawn_compute(Keyword.merge(opts, extra))

  defp rented(contract), do: {200, %{"success" => true, "new_contract" => contract}}

  defp rent_ids(acc \\ []) do
    receive do
      {:rent, id, _body} -> rent_ids([id | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "spawn_compute/1 offer search" do
    test "searches Vast's spaced names, count, disk and ports, on-demand, cheapest first", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [offer()])
      expect_rents(bypass, fn _ -> rented(28_411_907) end)

      assert {:ok, _} =
               rent_spawn(
                 opts,
                 gpu: :h100,
                 gpu_count: 2,
                 ports: [{8000, :http}, {22, :tcp}]
               )

      assert_received {:search, query}

      assert query["gpu_name"] == %{"in" => ["H100 SXM", "H100 PCIE", "H100 NVL"]}
      assert query["num_gpus"] == %{"eq" => 2}
      assert query["type"] == "ondemand"
      assert query["order"] == [["dph_total", "asc"]]
      assert query["verified"] == %{"eq" => true}
      assert query["rentable"] == %{"eq" => true}
      assert query["rented"] == %{"eq" => false}
      assert query["disk_space"] == %{"gte" => 20}
      assert query["allocated_storage"] == 20
      assert query["direct_port_count"] == %{"gte" => 2}
      refute Map.has_key?(query, "datacenter")
    end

    test "cloud_type: :secure asks for datacenter hosts; :community does not", %{
      bypass: bypass,
      opts: opts
    } do
      for {cloud, datacenter} <- [secure: %{"eq" => true}, community: nil] do
        expect_search(bypass, [offer()])
        expect_rents(bypass, fn _ -> rented(1) end)

        assert {:ok, _} = rent_spawn(opts, cloud_type: cloud)
        assert_received {:search, query}
        assert query["datacenter"] == datacenter
      end
    end

    test "the A100 80 GB and 40 GB share names and split on gpu_ram", %{
      bypass: bypass,
      opts: opts
    } do
      for {gpu, ram} <- [a100_80g: %{"gte" => 70_000}, a100_40g: %{"lt" => 70_000}] do
        expect_search(bypass, [offer()])
        expect_rents(bypass, fn _ -> rented(1) end)

        assert {:ok, _} = rent_spawn(opts, gpu: gpu)
        assert_received {:search, query}
        assert query["gpu_name"] == %{"in" => ["A100 SXM4", "A100 PCIE"]}
        assert query["gpu_ram"] == ram
      end
    end

    test "container_disk_gb sets the disk searched for and rented", %{bypass: bypass, opts: opts} do
      expect_search(bypass, [offer()])
      expect_rents(bypass, fn _ -> rented(1) end)

      assert {:ok, _} = rent_spawn(opts, container_disk_gb: 80)

      assert_received {:search, %{"disk_space" => %{"gte" => 80}, "allocated_storage" => 80}}
      assert_received {:rent, _, %{"disk" => 80}}
    end

    test "no matching offer is a :provider error, and no rent", %{bypass: bypass, opts: opts} do
      expect_search(bypass, [])

      assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
               rent_spawn(opts)

      assert message =~ "no on-demand offer"
    end

    test "a GPU the catalog has no Vast name for is :validation, and no request", %{opts: opts} do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               rent_spawn(opts, gpu: :mi300x)

      assert message =~ ":mi300x"
    end
  end

  describe "spawn_compute/1 picks the offer" do
    test "rents the cheapest offer in the first hinted country that has one", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [
        offer(%{"id" => 1, "dph_total" => 0.30, "geolocation" => "Hungary, HU"}),
        offer(%{"id" => 2, "dph_total" => 0.55, "geolocation" => "Texas, US"}),
        offer(%{"id" => 3, "dph_total" => 0.41, "geolocation" => "Quebec, CA"}),
        offer(%{"id" => 4, "dph_total" => 0.45, "geolocation" => "California, US"})
      ])

      expect_rents(bypass, fn _ -> rented(28_411_907) end)

      assert {:ok, compute} = rent_spawn(opts, region_hints: ["GB", "us", "CA"])

      assert rent_ids() == ["4"]
      assert compute.region == "California, US"
      assert compute.cost_per_hour == 0.45
    end

    test "with no hinted country offered, rents the cheapest anywhere", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [
        offer(%{"id" => 2, "dph_total" => 0.55, "geolocation" => "Texas, US"}),
        offer(%{"id" => 1, "dph_total" => 0.30, "geolocation" => "Hungary, HU"})
      ])

      expect_rents(bypass, fn _ -> rented(28_411_907) end)

      assert {:ok, _} = rent_spawn(opts, region_hints: ["JP"])
      assert rent_ids() == ["1"]
    end

    test "returns a provisioning Compute from the offer, with no read after the rent", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [offer()])
      expect_rents(bypass, fn _ -> rented(28_411_907) end)

      assert {:ok, compute} =
               rent_spawn(opts, name: "atlas-x", ports: [{8000, :http}])

      assert compute.id == "28411907"
      assert compute.provider == :vast
      assert compute.status == :provisioning
      assert compute.gpu_type == "RTX 4090"
      assert compute.cost_per_hour == 0.42
      assert compute.region == "Texas, US"
      assert compute.name == "atlas-x"
      assert compute.image == "vllm/vllm-openai:latest"
      assert compute.ports == [%{internal: 8000, external: nil, protocol: :http, url: nil}]
    end
  end

  describe "spawn_compute/1 rent body" do
    test "carries image, label, disk, runtype args, cancel_unavail and the env object", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [offer()])
      expect_rents(bypass, fn _ -> rented(28_411_907) end)

      s3 = [
        endpoint: "https://s3.example.com",
        access_key_id: "AKIAEXAMPLE",
        secret_access_key: "s3-secret-probe",
        dataset_uri: "s3://atlas-data/datasets/v1/"
      ]

      assert {:ok, compute} =
               rent_spawn(
                 opts,
                 name: "atlas-x",
                 env: %{"HF_TOKEN" => @hf_token},
                 ports: [{8000, :http}, {22, :tcp}],
                 auth: :bearer,
                 s3: s3
               )

      assert_received {:rent, "50751794", body}

      assert body["image"] == "vllm/vllm-openai:latest"
      assert body["label"] == "atlas-x"
      assert body["disk"] == 20
      assert body["runtype"] == "args"
      assert body["cancel_unavail"] == true
      refute Map.has_key?(body, "args")
      refute Map.has_key?(body, "onstart")

      env = body["env"]
      assert is_map(env)
      assert env["HF_TOKEN"] == @hf_token
      assert env["-p 8000:8000"] == "1"
      assert env["-p 22:22"] == "1"
      assert env["ATLAS_PORTS"] == "8000/http,22/tcp"
      assert env["AWS_SECRET_ACCESS_KEY"] == "s3-secret-probe"
      assert env["ATLAS_DATASET_URI"] == "s3://atlas-data/datasets/v1/"
      assert env["ATLAS_PRESHARED_KEY"] == compute.auth.token
    end

    test "an unnamed spawn sends no label and no ports flags", %{bypass: bypass, opts: opts} do
      expect_search(bypass, [offer()])
      expect_rents(bypass, fn _ -> rented(1) end)

      assert {:ok, _} = rent_spawn(opts)
      assert_received {:rent, _, body}
      refute Map.has_key?(body, "label")
      assert body["env"] == %{}
      assert_received {:search, query}
      refute Map.has_key?(query, "direct_port_count")
    end
  end

  describe "spawn_compute/1 refusals before any request" do
    test "command:, spot: true, template_id and network_volume_id are :unsupported", %{
      opts: opts
    } do
      for extra <- [
            [command: ["python", "train.py"]],
            [spot: true],
            [template_id: "tpl_1"],
            [network_volume_id: "vol_1"]
          ] do
        assert {:error, %ExAtlas.Error{kind: :unsupported, provider: :vast}} =
                 rent_spawn(opts, extra),
               "expected #{inspect(Keyword.keys(extra))} to be unsupported"
      end
    end

    test "no image is :validation", %{opts: opts} do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               rent_spawn(Keyword.delete(opts, :image))

      assert message =~ ":image"
    end

    # A name that starts with `-` is a Docker flag in Vast's env object:
    # `-v /:/host` would mount the host's root.
    test "an env name that is not an identifier is :validation naming it, not its value", %{
      opts: opts
    } do
      for name <- ["-v /:/host", "-p 1:1", "MY VAR", "1ABC", ""] do
        assert {:error, %ExAtlas.Error{kind: :validation} = error} =
                 rent_spawn(opts, env: %{name => @hf_token})

        assert error.message =~ inspect(name)
        refute inspect(error) =~ @hf_token
      end
    end

    test "control: an identifier env name passes the check", %{bypass: bypass, opts: opts} do
      expect_search(bypass, [offer()])
      expect_rents(bypass, fn _ -> rented(1) end)

      assert {:ok, _} = rent_spawn(opts, env: %{"_My_Var2" => "x"})
    end

    test "a value with a NUL byte or not UTF-8 is :validation naming the variable", %{
      opts: opts
    } do
      for value <- ["a\0b", <<0xFF, 0xFE>>] do
        assert {:error, %ExAtlas.Error{kind: :validation} = error} =
                 rent_spawn(opts, env: %{"DB_PASS" => value})

        assert error.message =~ "DB_PASS"
        refute inspect(error) =~ value
      end
    end

    test "ATLAS_PORTS in env is :validation", %{opts: opts} do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               rent_spawn(opts, env: %{"ATLAS_PORTS" => "1/tcp"})

      assert message =~ "ATLAS_PORTS"
    end

    test "a port that is not {1..65535, :http | :tcp} is :validation", %{opts: opts} do
      for port <- [{0, :http}, {65_536, :tcp}, {80, :udp}, 80] do
        assert {:error, %ExAtlas.Error{kind: :validation}} =
                 rent_spawn(opts, ports: [port])
      end
    end

    test "an offer_id that is not a positive integer is :validation", %{opts: opts} do
      for id <- ["12", -1, 1.5] do
        assert {:error, %ExAtlas.Error{kind: :validation}} =
                 rent_spawn(opts, provider_opts: %{offer_id: id})
      end
    end
  end

  describe "spawn_compute/1 provider_opts.offer_id" do
    test "rents that offer with no search", %{bypass: bypass, opts: opts} do
      expect_rents(bypass, fn _ -> rented(28_411_907) end)

      assert {:ok, compute} = rent_spawn(opts, provider_opts: %{offer_id: 777})

      assert rent_ids() == ["777"]
      assert compute.id == "28411907"
      assert compute.cost_per_hour == nil
    end

    test "a refused rent returns its error and tries nothing else", %{bypass: bypass, opts: opts} do
      expect_rents(bypass, fn _ -> {404, refused("no_such_ask", "gone")} end)

      assert {:error, %ExAtlas.Error{kind: :provider, status: 404}} =
               rent_spawn(opts, provider_opts: %{offer_id: 777})

      assert rent_ids() == ["777"]
    end
  end

  describe "spawn_compute/1 rent failures" do
    setup %{bypass: bypass} do
      expect_search(bypass, [
        offer(%{"id" => 1, "dph_total" => 0.30}),
        offer(%{"id" => 2, "dph_total" => 0.31}),
        offer(%{"id" => 3, "dph_total" => 0.32}),
        offer(%{"id" => 4, "dph_total" => 0.33})
      ])

      :ok
    end

    test "a refused rent tries the next offer", %{bypass: bypass, opts: opts} do
      expect_rents(bypass, fn
        "1" -> {410, refused("no_such_ask", "Instance type 1 is no longer available.")}
        _ -> rented(28_411_907)
      end)

      assert {:ok, %{id: "28411907", cost_per_hour: 0.31}} = rent_spawn(opts)
      assert rent_ids() == ["1", "2"]
    end

    test "a third refusal returns the error with Vast's code and no msg; no fourth rent", %{
      bypass: bypass,
      opts: opts
    } do
      expect_rents(bypass, fn id ->
        {400, refused("invalid_args", "error 400/3467: offer #{id} bad: HF_TOKEN=#{@hf_token}")}
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, status: 400} = error} =
               rent_spawn(opts, env: %{"HF_TOKEN" => @hf_token})

      assert rent_ids() == ["1", "2", "3"]
      assert error.message =~ "invalid_args"
      assert error.raw == %{"error" => "invalid_args"}
      refute inspect(error) =~ @hf_token
      refute Exception.message(error) =~ "3467"
    end

    test "a 500 is sent once and returns :provider", %{bypass: bypass, opts: opts} do
      expect_rents(bypass, fn _ -> {500, refused("server_error", "echo #{@hf_token}")} end)

      assert {:error, %ExAtlas.Error{kind: :provider, status: 500} = error} =
               rent_spawn(opts, env: %{"HF_TOKEN" => @hf_token})

      assert rent_ids() == ["1"]
      refute inspect(error) =~ @hf_token
    end

    test "control: a 429 then 200 rents once and returns the instance", %{
      bypass: bypass,
      opts: opts
    } do
      calls = :counters.new(1, [])

      Bypass.expect(bypass, "PUT", "/api/v0/asks/:id", fn conn ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> json(429, %{"detail" => "API requests too frequent endpoint threshold=4.5"})
        else
          json(conn, 200, %{"success" => true, "new_contract" => 28_411_907})
        end
      end)

      assert {:ok, %{id: "28411907", cost_per_hour: 0.30}} = rent_spawn(opts)
      assert :counters.get(calls, 1) == 2
    end

    test "a 401 stops at the first offer and reads :unauthorized", %{bypass: bypass, opts: opts} do
      expect_rents(bypass, fn _ -> {401, refused("auth_error", "Invalid user key")} end)

      assert {:error, %ExAtlas.Error{kind: :unauthorized}} = rent_spawn(opts)
      assert rent_ids() == ["1"]
    end

    test "a 200 with no new_contract is an error, and no other rent", %{
      bypass: bypass,
      opts: opts
    } do
      expect_rents(bypass, fn _ ->
        {200, %{"success" => false, "error" => "odd", "msg" => @hf_token}}
      end)

      assert {:error, %ExAtlas.Error{kind: :provider} = error} = rent_spawn(opts)
      assert rent_ids() == ["1"]
      refute inspect(error) =~ @hf_token
    end
  end

  describe "spawn_compute/1 rent answers that hide what happened" do
    setup %{bypass: bypass} do
      expect_search(bypass, [offer(%{"id" => 1}), offer(%{"id" => 2})])
      :ok
    end

    # Req cannot decode the body, and its error keeps the body it read.
    test "a body that is not JSON prints no echoed value, and tries no other offer", %{
      bypass: bypass,
      opts: opts
    } do
      for status <- [200, 400, 500] do
        Bypass.expect_once(bypass, "PUT", "/api/v0/asks/1", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("content-type", "application/json")
          |> Plug.Conn.resp(status, ~s({"error":"invalid_args","msg":"bad HF_TOKEN=#{@hf_token}"))
        end)

        assert {:error, %ExAtlas.Error{} = error} =
                 rent_spawn(opts, env: %{"HF_TOKEN" => @hf_token})

        refute inspect(error) =~ @hf_token, "a #{status} body leaked"
        refute inspect(error, structs: false) =~ @hf_token
        refute Exception.message(error) =~ @hf_token

        if status == 500 do
          :ok
        else
          expect_search(bypass, [offer(%{"id" => 1}), offer(%{"id" => 2})])
        end
      end
    end

    # The `error` field is documented as a code (`invalid_args`), but Vast
    # writes it; free text there is withheld like `msg`.
    test "an error field that is not a code is withheld", %{bypass: bypass, opts: opts} do
      expect_rents(bypass, fn _ -> {500, refused("bad env HF_TOKEN=#{@hf_token}", "x")} end)

      assert {:error, %ExAtlas.Error{} = error} =
               rent_spawn(opts, env: %{"HF_TOKEN" => @hf_token})

      assert error.message =~ "no error code"
      refute inspect(error) =~ @hf_token
      refute Exception.message(error) =~ @hf_token
    end

    # A 307 or 308 re-sends the body, env values included, to its Location.
    test "a redirect is not followed: the env goes to no other host", %{
      bypass: bypass,
      opts: opts
    } do
      elsewhere = Bypass.open()
      Bypass.down(elsewhere)

      Bypass.expect_once(bypass, "PUT", "/api/v0/asks/1", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://localhost:#{elsewhere.port}/steal")
        |> Plug.Conn.resp(307, "")
      end)

      assert {:error, %ExAtlas.Error{status: 307}} =
               rent_spawn(opts, env: %{"HF_TOKEN" => @hf_token})
    end

    # A proxy in front of Vast can answer 408 after Vast took the rent.
    test "a 408 stops at the first offer", %{bypass: bypass, opts: opts} do
      expect_rents(bypass, fn _ -> {408, refused("timeout", "slow")} end)

      assert {:error, %ExAtlas.Error{status: 408}} = rent_spawn(opts)
      assert rent_ids() == ["1"]
    end
  end

  describe "spawn_compute/1 rent timeout" do
    # Req's plug stands in for the network here: Bypass reports a handler the
    # client hung up on as a test failure.
    test "a timeout is sent once and tries no other offer", %{opts: opts} do
      test_pid = self()

      plug = fn conn ->
        case conn.method do
          "POST" ->
            json(conn, 200, %{"offers" => [offer(%{"id" => 1}), offer(%{"id" => 2})]})

          "PUT" ->
            send(test_pid, {:rent, List.last(conn.path_info), nil})
            Req.Test.transport_error(conn, :timeout)
        end
      end

      assert {:error, %ExAtlas.Error{kind: :transport}} =
               rent_spawn(opts, req_options: [plug: plug])

      assert rent_ids() == ["1"]
    end
  end

  describe "spawn_compute/1 secrets" do
    test "the returned Compute prints no auth token and no env value", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [offer()])
      expect_rents(bypass, fn _ -> rented(1) end)

      assert {:ok, compute} =
               rent_spawn(opts, env: %{"HF_TOKEN" => @hf_token}, auth: :bearer)

      # Control: the token exists, so the refute below is not vacuous.
      assert is_binary(compute.auth.token)
      refute inspect(compute) =~ compute.auth.token
      refute inspect(compute, structs: false) =~ @hf_token
    end
  end
end
