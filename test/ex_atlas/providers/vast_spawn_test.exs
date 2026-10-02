defmodule ExAtlas.Providers.VastSpawnTest do
  # Bypass stands in for Vast's API. A refusal test registers no route for
  # PUT /api/v0/asks/:id, so a rent fails the test.
  use ExUnit.Case, async: false

  import ExAtlas.Test.FakeVast

  alias ExAtlas.Test.CurlShim

  @bundles "/api/v0/bundles"

  # Distinctive, so a `refute =~` cannot pass on a common substring.
  @hf_token "hf-probe-7c1d9e"
  @container_key "vast-instance-key-4b8e2a"

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

  describe "spawn_compute/1 command:" do
    setup do
      previous = Application.get_env(:ex_atlas, :callback)

      Application.put_env(:ex_atlas, :callback,
        secret: ExAtlas.Test.Orchestrator.callback_secret()
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ex_atlas, :callback, previous),
          else: Application.delete_env(:ex_atlas, :callback)
      end)

      {:ok, prepared} = ExAtlas.Callback.prepare(callback: "https://app.example.com/atlas/cb")
      {:ok, callback: prepared[:callback]}
    end

    # Rents with `extra` and returns the rent body Vast received.
    defp rent_body(bypass, opts, extra) do
      expect_search(bypass, [offer()])
      expect_rents(bypass, fn _ -> rented(28_411_907) end)

      assert {:ok, _} = rent_spawn(opts, extra)
      assert_received {:rent, _, body}
      body
    end

    # What Vast injects into every container (docs.vast.ai, "Docker
    # Execution Environment").
    defp vast_env, do: [{"CONTAINER_ID", "28411907"}, {"CONTAINER_API_KEY", @container_key}]

    # The callback variables the rent put in the env object, as Vast passes them.
    defp callback_env(body) do
      [
        {"ATLAS_CALLBACK_URL", body["env"]["ATLAS_CALLBACK_URL"]},
        {"ATLAS_CALLBACK_TOKEN", body["env"]["ATLAS_CALLBACK_TOKEN"]}
        | vast_env()
      ]
    end

    test "self_terminate: true sends args that run the command under sh -c", %{
      bypass: bypass,
      opts: opts
    } do
      body = rent_body(bypass, opts, command: ["python", "train.py"])

      assert body["runtype"] == "args"
      assert ["sh", "-c", script] = body["args"]
      assert script =~ "trap atlas_self_terminate EXIT INT TERM; 'python' 'train.py'"
      refute Map.has_key?(body, "onstart")
    end

    @tag :tmp_dir
    test "the wrapper deletes the instance by its CONTAINER_ID on exit 0", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp
    } do
      body = rent_body(bypass, opts, command: ["sh", "-c", "echo ran > #{tmp}/ran"])

      assert {0, log, config} = CurlShim.run(body["args"], tmp, vast_env())

      assert File.read!(Path.join(tmp, "ran")) == "ran\n"
      assert log =~ "-X DELETE"
      assert log =~ "https://console.vast.ai/api/v0/instances/28411907/"
      # A hung DELETE must not hold the instance, and its bill, open for ever.
      assert log =~ "-m 30"
      assert config == ~s(header = "Authorization: Bearer #{@container_key}"\n)
    end

    @tag :tmp_dir
    test "the wrapper deletes the instance when the command exits 1", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp
    } do
      body = rent_body(bypass, opts, command: ["sh", "-c", "exit 1"])

      assert {1, log, _config} = CurlShim.run(body["args"], tmp, vast_env())
      assert log =~ "-X DELETE https://console.vast.ai/api/v0/instances/28411907/"
    end

    # The shell outlives a command a signal killed, so its EXIT trap runs. A
    # TERM sent to the shell alone (`docker stop`) waits for the command.
    @tag :tmp_dir
    test "the wrapper deletes the instance when SIGTERM kills the command", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp
    } do
      body = rent_body(bypass, opts, command: ["sh", "-c", "kill -TERM $$; sleep 5"])

      assert {143, log, _config} = CurlShim.run(body["args"], tmp, vast_env())
      assert log =~ "-X DELETE https://console.vast.ai/api/v0/instances/28411907/"
    end

    @tag :tmp_dir
    test "no argv carries the instance key or the callback token", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp,
      callback: callback
    } do
      body = rent_body(bypass, opts, command: ["true"], callback: callback)
      token = body["env"]["ATLAS_CALLBACK_TOKEN"]
      env = vast_env() ++ [{"ATLAS_CALLBACK_URL", "https://app.example.com/atlas/cb"}]

      assert {0, log, config} =
               CurlShim.run(body["args"], tmp, [{"ATLAS_CALLBACK_TOKEN", token} | env])

      # Control: both credentials reached curl, on stdin.
      assert config =~ "Bearer #{@container_key}"
      assert config =~ "Bearer #{token}"
      refute log =~ @container_key
      refute log =~ token
      refute Enum.join(body["args"]) =~ token
    end

    @tag :tmp_dir
    test "with a callback the finish report goes first, then the delete", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp,
      callback: callback
    } do
      body = rent_body(bypass, opts, command: ["sh", "-c", "exit 3"], callback: callback)
      env = callback_env(body)

      assert {3, log, _config} = CurlShim.run(body["args"], tmp, env)

      assert [finish, delete] = String.split(log, "\n", trim: true)
      assert finish =~ ~s({"exit_code":3})
      assert finish =~ "https://app.example.com/atlas/cb/finish"
      assert delete =~ "-X DELETE"
    end

    @tag :tmp_dir
    test "a callback host that is down cannot stop the delete", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp,
      callback: callback
    } do
      body = rent_body(bypass, opts, command: ["true"], callback: callback)
      CurlShim.install(tmp, 7)
      env = callback_env(body)

      assert {0, log, _config} = CurlShim.run(body["args"], tmp, env)
      assert log =~ "/finish"
      assert log =~ "-X DELETE"
    end

    test "self_terminate: false sends the command as args, unwrapped", %{
      bypass: bypass,
      opts: opts
    } do
      body =
        rent_body(bypass, opts, command: ["python", "train.py", "it's"], self_terminate: false)

      assert body["args"] == ["python", "train.py", "it's"]
    end

    @tag :tmp_dir
    test "self_terminate: false with a callback reports and does not delete", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp,
      callback: callback
    } do
      body =
        rent_body(bypass, opts, command: ["true"], self_terminate: false, callback: callback)

      env = callback_env(body)

      assert {0, log, _config} = CurlShim.run(body["args"], tmp, env)
      assert log =~ ~s({"exit_code":0})
      refute log =~ "-X DELETE"
    end

    test "an empty command sends no args, so the image's own command runs", %{
      bypass: bypass,
      opts: opts
    } do
      body = rent_body(bypass, opts, command: [])
      refute Map.has_key?(body, "args")
    end

    @tag :tmp_dir
    test "command arguments survive the wrapper intact", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp
    } do
      arg = "it's a $PATH; rm -rf / `id`"

      body =
        rent_body(bypass, opts,
          command: ["sh", "-c", "printf '%s' \"$1\" > #{tmp}/arg", "sh", arg]
        )

      assert {0, _log, _config} = CurlShim.run(body["args"], tmp, vast_env())
      assert File.read!(Path.join(tmp, "arg")) == arg
    end

    # Review of PR 108: a newline in a key ends curl's config line, and the
    # rest of the value is read as curl options (`url =`, `variable =`).
    @tag :tmp_dir
    test "a key or id that is not a plain token sends no request", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp
    } do
      body = rent_body(bypass, opts, command: ["true"])

      for {id, key} <- [
            {"28411907", "abc\nurl = \"http://127.0.0.1:9/stolen\""},
            {"28411907", ""},
            {"../../999", @container_key},
            {"", @container_key}
          ] do
        File.rm_rf!(Path.join(tmp, "curl.log"))
        env = [{"CONTAINER_ID", id}, {"CONTAINER_API_KEY", key}]

        assert {0, "", ""} = CurlShim.run(body["args"], tmp, env),
               "sent a request with id #{inspect(id)} and key #{inspect(key)}"
      end

      # Control: a plain id and key still delete.
      assert {0, log, _} = CurlShim.run(body["args"], tmp, vast_env())
      assert log =~ "-X DELETE"
    end

    @tag :tmp_dir
    test "a callback token that is not a plain token posts no report", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: tmp,
      callback: callback
    } do
      body = rent_body(bypass, opts, command: ["true"], callback: callback)
      url = {"ATLAS_CALLBACK_URL", "https://app.example.com/atlas/cb"}
      bad = {"ATLAS_CALLBACK_TOKEN", "t\nurl = \"http://127.0.0.1:9/x\""}

      assert {0, log, _} = CurlShim.run(body["args"], tmp, [url, bad | vast_env()])
      refute log =~ "/finish"
      # The delete does not depend on the report.
      assert log =~ "-X DELETE"

      File.rm_rf!(Path.join(tmp, "curl.log"))
      good = {"ATLAS_CALLBACK_TOKEN", body["env"]["ATLAS_CALLBACK_TOKEN"]}
      assert {0, log, _} = CurlShim.run(body["args"], tmp, [url, good | vast_env()])
      assert log =~ "/finish"
    end

    test "Vast lists :self_terminate among its capabilities" do
      assert :self_terminate in ExAtlas.Providers.Vast.capabilities()
    end
  end

  describe "spawn_compute/1 spot: true" do
    # A bid search lists `dph_total` as the bid plus the disk's storage cost
    # (read from Vast's free search, 2026-10-02: `dph_base` = `min_bid`).
    defp bid_offer(id, min_bid, attrs \\ %{}) do
      total = if is_number(min_bid), do: Float.round(min_bid + 0.01, 4), else: 0.9
      offer(Map.merge(%{"id" => id, "min_bid" => min_bid, "dph_total" => total}, attrs))
    end

    test "searches type bid and rents at the offer's min_bid", %{bypass: bypass, opts: opts} do
      expect_search(bypass, [bid_offer(7, 0.18)])
      expect_rents(bypass, fn _ -> rented(28_411_907) end)

      assert {:ok, compute} = rent_spawn(opts, spot: true)

      assert_received {:search, query}
      assert query["type"] == "bid"
      assert_received {:rent, "7", body}
      assert body["price"] == 0.18
      # What the bid bills: the bid plus the disk's storage.
      assert compute.cost_per_hour == 0.19
    end

    test "control: an on-demand spawn searches ondemand and sends no price", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [bid_offer(7, 0.18)])
      expect_rents(bypass, fn _ -> rented(1) end)

      assert {:ok, compute} = rent_spawn(opts)

      assert_received {:search, %{"type" => "ondemand"}}
      assert_received {:rent, "7", body}
      refute Map.has_key?(body, "price")
      assert compute.cost_per_hour == 0.19
    end

    # Offer 1 has the lowest bid and the dearest disk: it bills the most.
    test "tries offers by what the bid bills", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [
        bid_offer(1, 0.10, %{"dph_total" => 0.30}),
        bid_offer(2, 0.15, %{"dph_total" => 0.16}),
        bid_offer(3, 0.20, %{"dph_total" => 0.21})
      ])

      expect_rents(bypass, fn _ -> {400, refused("bid_too_low", "no")} end)

      assert {:error, %ExAtlas.Error{kind: :provider}} = rent_spawn(opts, spot: true)
      assert rent_ids() == ["2", "3", "1"]
    end

    test "skips an offer with no usable min_bid, and never rents it at dph_total", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [
        bid_offer(1, nil, %{"dph_total" => 0.05}),
        bid_offer(2, "0.10", %{"dph_total" => 0.06}),
        bid_offer(3, 0, %{"dph_total" => 0.07}),
        bid_offer(4, 0.25)
      ])

      expect_rents(bypass, fn _ -> rented(5) end)

      assert {:ok, %{cost_per_hour: 0.26}} = rent_spawn(opts, spot: true)
      assert rent_ids() == ["4"]
    end

    test "an offer without dph_total still sets cost_per_hour from its min_bid", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [Map.delete(bid_offer(7, 0.18), "dph_total")])
      expect_rents(bypass, fn _ -> rented(1) end)

      assert {:ok, %{cost_per_hour: 0.18}} = rent_spawn(opts, spot: true)
    end

    test "provider_opts.offer_id: nil with spot: true searches, as on-demand does", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [bid_offer(7, 0.18)])
      expect_rents(bypass, fn _ -> rented(1) end)

      assert {:ok, %{cost_per_hour: 0.19}} =
               rent_spawn(opts, spot: true, provider_opts: %{offer_id: nil})
    end

    test "no offer with a min_bid is a :provider error, and no rent", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [bid_offer(1, nil)])

      assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
               rent_spawn(opts, spot: true)

      assert message =~ "interruptible"
    end

    test "a refused bid tries the next offer at that offer's own min_bid", %{
      bypass: bypass,
      opts: opts
    } do
      expect_search(bypass, [bid_offer(1, 0.10), bid_offer(2, 0.15)])

      expect_rents(bypass, fn
        "1" -> {400, refused("bid_too_low", "no")}
        "2" -> rented(9)
      end)

      assert {:ok, %{id: "9", cost_per_hour: 0.16}} = rent_spawn(opts, spot: true)
      assert_received {:rent, "1", %{"price" => 0.10}}
      assert_received {:rent, "2", %{"price" => 0.15}}
    end

    test "provider_opts.offer_id with spot: true is :validation, and no request", %{opts: opts} do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               rent_spawn(opts,
                 spot: true,
                 provider_opts: %{offer_id: 7},
                 env: %{"T" => @hf_token}
               )

      assert message =~ "offer_id"
      refute message =~ @hf_token
    end

    test "a refused bid withholds Vast's msg, as an on-demand refusal does", %{
      bypass: bypass,
      opts: opts
    } do
      expect_rents(bypass, fn _ -> {400, refused("invalid_args", "bad env #{@hf_token}")} end)

      for extra <- [[spot: true], []] do
        expect_search(bypass, [bid_offer(1, 0.10)])

        assert {:error, %ExAtlas.Error{} = error} =
                 rent_spawn(opts, [env: %{"HF_TOKEN" => @hf_token}] ++ extra)

        assert error.message =~ "invalid_args"
        refute inspect(error) =~ @hf_token
      end
    end

    test "Vast lists :spot among its capabilities" do
      assert :spot in ExAtlas.Providers.Vast.capabilities()
    end
  end

  describe "spawn_compute/1 refusals before any request" do
    test "template_id and network_volume_id are :unsupported", %{
      opts: opts
    } do
      for extra <- [
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

    # `inspect/1` escapes a NUL byte and prints bad UTF-8 as a binary, so the
    # refutes read the message itself, where the bytes would appear as given.
    test "a value with a NUL byte or not UTF-8 is :validation naming the variable", %{
      opts: opts
    } do
      for value <- ["#{@hf_token}\0x", @hf_token <> <<0xFF, 0xFE>>] do
        assert {:error, %ExAtlas.Error{kind: :validation} = error} =
                 rent_spawn(opts, env: %{"DB_PASS" => value})

        assert error.message =~ "DB_PASS"
        refute error.message =~ @hf_token
        refute Exception.message(error) =~ @hf_token
      end
    end

    # The trap reads these from the environment Vast injects; an `env:` entry
    # of the same name could point the delete elsewhere.
    test "CONTAINER_ID and CONTAINER_API_KEY in env are :validation", %{opts: opts} do
      for name <- ["CONTAINER_ID", "CONTAINER_API_KEY"] do
        assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
                 rent_spawn(opts, env: %{name => "1"})

        assert message =~ name
      end
    end

    test "a command argument with a NUL byte or not UTF-8 is :validation naming its index", %{
      opts: opts
    } do
      for bad <- ["#{@hf_token}\0x", @hf_token <> <<0xFF>>] do
        assert {:error, %ExAtlas.Error{kind: :validation} = error} =
                 rent_spawn(opts, command: ["python", bad])

        assert error.message =~ "argument 1"
        refute error.message =~ @hf_token
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

  # A command can hold a value its caller wants kept, as an env value can.
  # Each rent failure below echoes the whole request back; none may reach the
  # error. The env tests above cover the same paths for `env`.
  describe "spawn_compute/1 rent failures with a command" do
    @command_marker "cmd-probe-91f3aa"

    setup %{bypass: bypass} do
      expect_search(bypass, [offer(%{"id" => 1})])
      {:ok, command: ["python", "train.py", "--token", @command_marker]}
    end

    # Answers the rent with `respond`, after sending the args it got to the test.
    defp echo_rent(bypass, respond) do
      test_pid = self()

      Bypass.expect_once(bypass, "PUT", "/api/v0/asks/1", fn conn ->
        {body, conn} = read_json(conn)
        send(test_pid, {:args, body["args"]})
        respond.(conn, Jason.encode!(body))
      end)
    end

    defp assert_withheld(error) do
      # Control: the marker went to Vast, so each refute below can fail.
      assert_received {:args, ["sh", "-c", script]}
      assert script =~ @command_marker

      refute inspect(error) =~ @command_marker
      refute inspect(error, structs: false) =~ @command_marker
      refute Exception.message(error) =~ @command_marker
    end

    test "a refusal whose msg echoes the request", %{bypass: bypass, opts: opts, command: cmd} do
      echo_rent(bypass, fn conn, echo -> json(conn, 400, refused("invalid_args", echo)) end)

      assert {:error, %ExAtlas.Error{status: 400} = error} = rent_spawn(opts, command: cmd)
      assert_withheld(error)
    end

    test "a 500 whose error field is the request", %{bypass: bypass, opts: opts, command: cmd} do
      echo_rent(bypass, fn conn, echo -> json(conn, 500, refused(echo, "x")) end)

      assert {:error, %ExAtlas.Error{status: 500} = error} = rent_spawn(opts, command: cmd)
      assert_withheld(error)
    end

    test "a 200 with no new_contract that echoes the request", %{
      bypass: bypass,
      opts: opts,
      command: cmd
    } do
      echo_rent(bypass, fn conn, echo -> json(conn, 200, %{"success" => false, "msg" => echo}) end)

      assert {:error, %ExAtlas.Error{} = error} = rent_spawn(opts, command: cmd)
      assert_withheld(error)
    end

    test "a body that is not JSON", %{bypass: bypass, opts: opts, command: cmd} do
      echo_rent(bypass, fn conn, echo ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(400, ~s({"msg":) <> echo)
      end)

      assert {:error, %ExAtlas.Error{} = error} = rent_spawn(opts, command: cmd)
      assert_withheld(error)
    end

    test "a redirect is not followed: the command goes to no other host", %{
      bypass: bypass,
      opts: opts,
      command: cmd
    } do
      elsewhere = Bypass.open()
      Bypass.down(elsewhere)

      echo_rent(bypass, fn conn, _echo ->
        conn
        |> Plug.Conn.put_resp_header("location", "http://localhost:#{elsewhere.port}/steal")
        |> Plug.Conn.resp(307, "")
      end)

      assert {:error, %ExAtlas.Error{status: 307} = error} = rent_spawn(opts, command: cmd)
      assert_withheld(error)
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
