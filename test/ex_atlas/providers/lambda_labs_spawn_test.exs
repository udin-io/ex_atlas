defmodule ExAtlas.Providers.LambdaLabsSpawnTest do
  # Bypass stands in for Lambda's Cloud API v1. A refusal test registers no
  # route for POST /instance-operations/launch, so a launch fails the test.
  use ExUnit.Case, async: false

  import ExAtlas.Test.FakeLambda

  alias ExAtlas.Spec

  @launch "/instance-operations/launch"
  @launched_id "0920582c7ff041399e34823a0be62549"

  # Distinctive, so a `refute =~` cannot pass on a common substring.
  @hf_token "hf-probe-7c1d9e"

  setup do
    bypass = Bypass.open()

    opts = [
      provider: :lambda_labs,
      api_key: "lambda-test-key",
      base_url: "http://localhost:#{bypass.port}",
      gpu: :h100,
      image: "vllm/vllm-openai:latest",
      provider_opts: %{ssh_key_name: "deploy"}
    ]

    {:ok, bypass: bypass, opts: opts}
  end

  defp expect_types(bypass, types \\ instance_types()) do
    Bypass.expect_once(bypass, "GET", "/instance-types", fn conn ->
      json(conn, 200, %{"data" => types})
    end)
  end

  # Sends the decoded launch body to the test and answers with one id.
  defp expect_launch(bypass) do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", @launch, fn conn ->
      {body, conn} = read_json(conn)
      send(test_pid, {:launch, body})
      json(conn, 200, %{"data" => %{"instance_ids" => [@launched_id]}})
    end)
  end

  defp launched_body do
    assert_received {:launch, body}
    body
  end

  # Routes for the firewall calls a spawn with `ports:` makes. A test that
  # asserts on them registers its own expects instead.
  defp stub_firewall(bypass) do
    Bypass.stub(bypass, "POST", "/firewall-rulesets", fn conn ->
      json(conn, 200, %{"data" => ruleset(%{"id" => "rs-stub"})})
    end)

    Bypass.stub(bypass, "DELETE", "/firewall-rulesets/:id", fn conn ->
      json(conn, 200, %{"data" => %{}})
    end)
  end

  defp tags(body), do: Map.new(body["tags"], &{&1["key"], &1["value"]})

  describe "spawn_compute/1 picks the type and region" do
    test "launches the catalog's type in the first hinted region with capacity", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      expect_launch(bypass)
      stub_firewall(bypass)
      before = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, compute} =
               ExAtlas.spawn_compute(
                 opts ++
                   [
                     name: "atlas-vllm",
                     ports: [{8000, :http}, {22, :tcp}],
                     region_hints: ["eu-central-1", "us-east-1"]
                   ]
               )

      body = launched_body()
      assert body["instance_type_name"] == "gpu_1x_h100_pcie"
      assert body["region_name"] == "us-east-1"
      assert body["ssh_key_names"] == ["deploy"]
      assert body["name"] == "atlas-vllm"

      tags = tags(body)
      assert tags["atlas-ports"] == "8000/http,22/tcp"
      assert tags["atlas-image"] == "vllm/vllm-openai:latest"
      assert {:ok, created_at, 0} = DateTime.from_iso8601(tags["atlas-created-at"])
      assert DateTime.compare(created_at, before) in [:gt, :eq]

      assert %Spec.Compute{
               id: @launched_id,
               provider: :lambda_labs,
               status: :provisioning,
               cost_per_hour: 2.49,
               region: "us-east-1",
               gpu_type: "gpu_1x_h100_pcie",
               gpu_count: 1,
               image: "vllm/vllm-openai:latest",
               name: "atlas-vllm",
               created_at: ^created_at
             } = compute

      assert [%{internal: 8000, protocol: :http, url: nil}, %{internal: 22, protocol: :tcp}] =
               compute.ports
    end

    test "with no hint, launches in Lambda's first region with capacity", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, %{region: "us-west-1"}} = ExAtlas.spawn_compute(opts)
      assert launched_body()["region_name"] == "us-west-1"
    end

    test "a type with no capacity anywhere is a :provider error naming it, and no launch", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)

      assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
               ExAtlas.spawn_compute(Keyword.put(opts, :gpu, :h100_sxm))

      assert message =~ "gpu_1x_h100_sxm5"
    end

    test "gpu_count: 8 launches the 8x type", %{bypass: bypass, opts: opts} do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, %{gpu_type: "gpu_8x_h100_sxm5", gpu_count: 8, cost_per_hour: 23.92}} =
               ExAtlas.spawn_compute(Keyword.merge(opts, gpu: :h100_sxm, gpu_count: 8))

      assert launched_body()["instance_type_name"] == "gpu_8x_h100_sxm5"
    end

    test "a count Lambda does not list is :validation naming the listed counts, and no launch",
         %{bypass: bypass, opts: opts} do
      expect_types(bypass)

      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(Keyword.merge(opts, gpu: :h100_sxm, gpu_count: 4))

      assert message =~ "gpu_4x_h100_sxm5"
      assert message =~ "1, 8"
    end

    test "provider_opts.instance_type wins over the catalog", %{bypass: bypass, opts: opts} do
      expect_types(bypass)
      expect_launch(bypass)

      opts =
        Keyword.put(opts, :provider_opts, %{ssh_key_name: "deploy", instance_type: "gpu_1x_a10"})

      assert {:ok, %{gpu_type: "gpu_1x_a10", region: "us-west-1"}} = ExAtlas.spawn_compute(opts)
      assert launched_body()["instance_type_name"] == "gpu_1x_a10"
    end
  end

  describe "spawn_compute/1 launch body" do
    # From `InstanceLaunchRequest` and `RequestedTagEntry` in Lambda's OpenAPI
    # spec 1.10.0, https://cloud.lambda.ai/api/v1/openapi.json.
    @launch_properties ~w(region_name instance_type_name ssh_key_names file_system_names
                          file_system_mounts hostname name image user_data tags firewall_rulesets)
    @launch_required ~w(region_name instance_type_name ssh_key_names)
    @tag_key ~r/^[a-z][a-z0-9-:]+$/

    test "holds only fields Lambda's spec defines, with valid tags", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      expect_launch(bypass)
      stub_firewall(bypass)

      long_image = "registry.example.com/" <> String.duplicate("a", 200) <> ":latest"

      assert {:ok, _} =
               ExAtlas.spawn_compute(
                 Keyword.merge(opts,
                   name: "atlas-x",
                   image: long_image,
                   ports: [{8000, :http}],
                   env: %{"A" => "1"}
                 )
               )

      body = launched_body()
      assert Map.keys(body) -- @launch_properties == []
      assert @launch_required -- Map.keys(body) == []

      for %{"key" => key, "value" => value} <- body["tags"] do
        assert key =~ @tag_key
        assert String.length(value) <= 128
      end

      # An image longer than a tag value holds gets no atlas-image tag.
      refute Map.has_key?(tags(body), "atlas-image")
    end
  end

  describe "spawn_compute/1 SSH key" do
    test "with none in provider_opts or app config, is :validation before any request", %{
      opts: opts
    } do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(Keyword.put(opts, :provider_opts, %{}))

      assert message =~ "ssh_key_name"
    end

    test "app config alone works", %{bypass: bypass, opts: opts} do
      previous = Application.get_env(:ex_atlas, :lambda_labs)
      Application.put_env(:ex_atlas, :lambda_labs, ssh_key_name: "from-config")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ex_atlas, :lambda_labs, previous),
          else: Application.delete_env(:ex_atlas, :lambda_labs)
      end)

      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, _} = ExAtlas.spawn_compute(Keyword.put(opts, :provider_opts, %{}))
      assert launched_body()["ssh_key_names"] == ["from-config"]
    end
  end

  describe "spawn_compute/1 user_data script" do
    @tag :tmp_dir
    test "runs the image with every port and variable; values reach docker byte for byte, never on argv",
         %{bypass: bypass, opts: opts, tmp_dir: dir} do
      expect_types(bypass)
      expect_launch(bypass)
      stub_firewall(bypass)
      tricky = "it's $(id) `whoami` \"q\"\nline two\\"

      assert {:ok, compute} =
               ExAtlas.spawn_compute(
                 opts ++
                   [
                     ports: [{8000, :http}, {9000, :tcp}],
                     # A container PATH must not hide the host's docker.
                     env: %{
                       "HF_TOKEN" => @hf_token,
                       "TRICKY" => tricky,
                       "PATH" => "/opt/conda/bin"
                     },
                     auth: :bearer
                   ]
               )

      script = launched_body()["user_data"]
      assert String.starts_with?(script, "#!/bin/bash\n")

      run = run_with_stub_docker(script, dir)

      assert run.argv ==
               ~w(run --detach --name atlas --gpus all --restart no -p 8000:8000 -p 9000:9000) ++
                 ~w(-e ATLAS_PRESHARED_KEY -e HF_TOKEN -e PATH -e TRICKY vllm/vllm-openai:latest)

      assert run.env == %{
               "ATLAS_PRESHARED_KEY" => compute.auth.token,
               "HF_TOKEN" => @hf_token,
               "PATH" => "/opt/conda/bin",
               "TRICKY" => tricky
             }

      # The stub daemon answered `docker info` on the second try; the script
      # waited for it before `docker run`.
      assert run.info_calls == 2

      for value <- [@hf_token, tricky, compute.auth.token] do
        refute Enum.any?(run.argv, &String.contains?(&1, value))
      end

      # `$(id)` stayed text: the shell never ran it.
      refute File.exists?(Path.join(dir, "ran-id"))
    end

    # The values are exported for `docker run` itself, so these would steer
    # the host's docker client or its loader, not only the container.
    test "an env name docker or the loader reads on the host is :validation, and no launch", %{
      opts: opts
    } do
      for name <- ["DOCKER_HOST", "DOCKER_CONFIG", "LD_PRELOAD", "LD_LIBRARY_PATH"] do
        assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
                 ExAtlas.spawn_compute(opts ++ [env: %{name => "tcp://evil:2375"}])

        assert message =~ inspect(name)
      end
    end

    test "an env name that is not a shell identifier is :validation naming it, and no launch", %{
      opts: opts
    } do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message} = error} =
               ExAtlas.spawn_compute(opts ++ [env: %{"A-B" => @hf_token}])

      assert message =~ ~s("A-B")
      refute inspect(error) =~ @hf_token
    end

    test "a value with a NUL byte is :validation naming the variable, and no launch", %{
      opts: opts
    } do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(opts ++ [env: %{"NULLY" => "a" <> <<0>> <> "b"}])

      assert message =~ "NULLY"
    end

    # Lambda's body is JSON, which holds UTF-8 only; Jason raised with the
    # script's first bytes in its message.
    test "a value or image that is not UTF-8 is :validation naming it, before any request", %{
      opts: opts
    } do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message} = error} =
               ExAtlas.spawn_compute(opts ++ [env: %{"BIN" => "sk-" <> <<0xFF, 1>>}])

      assert message =~ ~s("BIN")
      refute inspect(error) =~ "sk-"

      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(Keyword.put(opts, :image, "img" <> <<0xFF>>))

      assert message =~ ":image"
    end

    # Quoting keeps it out of the shell, but docker still reads it as a flag.
    test "an image that starts with - is :validation, and no launch", %{opts: opts} do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(Keyword.put(opts, :image, "--privileged"))

      assert message =~ ":image"
    end

    test "env:, s3:, ports: or auth: without image: is :validation, and no launch", %{opts: opts} do
      opts = Keyword.delete(opts, :image)

      for extra <- [
            [env: %{"A" => "1"}],
            [ports: [{8000, :http}]],
            [auth: :bearer],
            [s3: %{access_key_id: "k", secret_access_key: "s", dataset_uri: "s3://b/d/"}]
          ] do
        assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
                 ExAtlas.spawn_compute(opts ++ extra),
               "expected #{inspect(Keyword.keys(extra))} without image: to be refused"

        assert message =~ ":image"
      end
    end

    test "no image and none of them launches a plain VM with no user_data", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, %{image: nil, ports: []}} = ExAtlas.spawn_compute(Keyword.delete(opts, :image))

      body = launched_body()
      refute Map.has_key?(body, "user_data")
      assert Map.keys(tags(body)) == ["atlas-created-at"]
    end

    test "a script of 1,000,000 bytes launches; one byte more is :validation", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      expect_launch(bypass)

      # Measure the script around an empty value, then pad the value to fit.
      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [env: %{"PAD" => ""}])
      base = byte_size(launched_body()["user_data"])
      pad = String.duplicate("x", 1_000_000 - base)

      expect_types(bypass)
      expect_launch(bypass)
      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [env: %{"PAD" => pad}])
      assert byte_size(launched_body()["user_data"]) == 1_000_000

      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(opts ++ [env: %{"PAD" => pad <> "x"}])

      assert message =~ "1000001 bytes"
    end
  end

  describe "spawn_compute/1 ports and launch answer" do
    test "a port that is not {1..65535, :http | :tcp} is :validation, and no launch", %{
      opts: opts
    } do
      for port <- [{0, :http}, {65_536, :tcp}, {8000, :udp}, 8000] do
        assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
                 ExAtlas.spawn_compute(opts ++ [ports: [port]]),
               "expected #{inspect(port)} to be refused"

        assert message =~ "port"
      end
    end

    test "ports too many for one 128-character tag are :validation, and no launch", %{
      opts: opts
    } do
      ports = for port <- 10_000..10_013, do: {port, :http}

      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(opts ++ [ports: ports])

      assert message =~ "128"
    end

    test "a launch answered 200 with no instance id is a :provider error", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)

      Bypass.expect_once(bypass, "POST", @launch, fn conn ->
        json(conn, 200, %{"data" => %{"instance_ids" => []}})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
               ExAtlas.spawn_compute(opts)

      assert message =~ "/instance-operations/launch"
    end
  end

  describe "spawn_compute/1 firewall ruleset" do
    # The ruleset opens `ports:` at Lambda's firewall. `FirewallRule` and the
    # create request are in Lambda's OpenAPI spec 1.10.0: a rule needs
    # `protocol`, `source_network` and `description`; the name holds at most 64
    # characters.
    @ruleset_rule_keys ~w(protocol port_range source_network description)

    # Logs the order of the three calls a spawn makes.
    defp expect_ruleset_flow(bypass, log, launch_status \\ 200) do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/firewall-rulesets", fn conn ->
        {body, conn} = read_json(conn)
        send(test_pid, {:ruleset, body})
        Agent.update(log, &[:create | &1])
        json(conn, 200, %{"data" => ruleset(%{"id" => "rs-1", "name" => body["name"]})})
      end)

      Bypass.expect_once(bypass, "POST", @launch, fn conn ->
        {body, conn} = read_json(conn)
        send(test_pid, {:launch, body})
        Agent.update(log, &[:launch | &1])

        if launch_status == 200 do
          json(conn, 200, %{"data" => %{"instance_ids" => [@launched_id]}})
        else
          json(conn, launch_status, %{"error" => %{"code" => "global/invalid-parameters"}})
        end
      end)
    end

    defp ruleset_body do
      assert_received {:ruleset, body}
      body
    end

    setup do
      {:ok, log: start_supervised!({Agent, fn -> [] end})}
    end

    test "creates one ruleset with a tcp rule per port, then launches with its id", %{
      bypass: bypass,
      opts: opts,
      log: log
    } do
      expect_types(bypass)
      expect_ruleset_flow(bypass, log)

      assert {:ok, %{id: @launched_id}} =
               ExAtlas.spawn_compute(
                 opts ++
                   [
                     name: "vllm-a",
                     ports: [{8000, :http}, {9000, :tcp}],
                     region_hints: ["us-east-1"]
                   ]
               )

      body = ruleset_body()
      assert body["region"] == "us-east-1"
      assert body["name"] =~ ~r/\Aatlas-vllm-a-[0-9a-f]{8}\z/

      assert [
               %{"protocol" => "tcp", "port_range" => [8000, 8000]} = http,
               %{"protocol" => "tcp", "port_range" => [9000, 9000]}
             ] = body["rules"]

      assert http["source_network"] == "0.0.0.0/0"
      assert Enum.all?(body["rules"], &(Map.keys(&1) -- @ruleset_rule_keys == []))
      assert Enum.all?(body["rules"], &(&1["description"] != ""))

      assert launched_body()["firewall_rulesets"] == [%{"id" => "rs-1"}]
      assert Agent.get(log, &Enum.reverse/1) == [:create, :launch]
    end

    test "provider_opts.source_network limits the rules", %{
      bypass: bypass,
      opts: opts,
      log: log
    } do
      expect_types(bypass)
      expect_ruleset_flow(bypass, log)

      opts =
        Keyword.put(opts, :provider_opts, %{
          source_network: "203.0.113.0/24",
          ssh_key_name: "deploy"
        })

      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])
      assert [%{"source_network" => "203.0.113.0/24"}] = ruleset_body()["rules"]
    end

    test "a port listed twice opens one rule", %{bypass: bypass, opts: opts, log: log} do
      expect_types(bypass)
      expect_ruleset_flow(bypass, log)

      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [ports: [{22, :tcp}, {22, :http}]])
      assert [%{"port_range" => [22, 22]}] = ruleset_body()["rules"]
    end

    test "the ruleset name holds at most 64 characters, and differs for two spawns of one name",
         %{bypass: bypass, opts: opts} do
      expect_types(bypass)
      test_pid = self()

      Bypass.stub(bypass, "POST", "/firewall-rulesets", fn conn ->
        {body, conn} = read_json(conn)
        send(test_pid, {:ruleset, body})
        json(conn, 200, %{"data" => ruleset()})
      end)

      Bypass.stub(bypass, "POST", @launch, fn conn ->
        json(conn, 200, %{"data" => %{"instance_ids" => [@launched_id]}})
      end)

      Bypass.stub(bypass, "GET", "/instance-types", fn conn ->
        json(conn, 200, %{"data" => instance_types()})
      end)

      long = String.duplicate("é", 100)

      for name <- [long, long] do
        assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [name: name, ports: [{80, :http}]])
      end

      assert [%{"name" => first}, %{"name" => second}] = [ruleset_body(), ruleset_body()]
      assert String.length(first) == 64
      assert first != second
    end

    test "an unnamed spawn gets a generated ruleset name", %{bypass: bypass, opts: opts, log: log} do
      expect_types(bypass)
      expect_ruleset_flow(bypass, log)

      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])
      assert ruleset_body()["name"] =~ ~r/\Aatlas-[0-9a-f]{8}\z/
    end

    test "ports: [] creates no ruleset and sends no firewall_rulesets", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [ports: []])
      refute Map.has_key?(launched_body(), "firewall_rulesets")
    end

    test "a refused ruleset create returns its error and launches nothing", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)

      Bypass.expect_once(bypass, "POST", "/firewall-rulesets", fn conn ->
        json(conn, 400, %{
          "error" => %{"code" => "global/quota-exceeded", "message" => "Too many rulesets."}
        })
      end)

      assert {:error,
              %ExAtlas.Error{
                kind: :provider,
                status: 400,
                provider: :lambda_labs,
                message: "Too many rulesets."
              }} = ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])
    end

    test "a ruleset create answered 429 then 200 creates one ruleset", %{
      bypass: bypass,
      opts: opts,
      log: log
    } do
      expect_types(bypass)
      calls = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/firewall-rulesets", fn conn ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> json(429, %{"error" => %{"code" => "global/rate-limited", "message" => "slow"}})
        else
          json(conn, 200, %{"data" => ruleset(%{"id" => "rs-1"})})
        end
      end)

      Bypass.expect_once(bypass, "POST", @launch, fn conn ->
        Agent.update(log, &[:launch | &1])
        json(conn, 200, %{"data" => %{"instance_ids" => [@launched_id]}})
      end)

      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])
      assert :counters.get(calls, 1) == 2
    end

    test "a refused launch deletes the ruleset it created and returns the launch error", %{
      bypass: bypass,
      opts: opts,
      log: log
    } do
      expect_types(bypass)
      expect_ruleset_flow(bypass, log, 400)

      Bypass.expect_once(bypass, "DELETE", "/firewall-rulesets/rs-1", fn conn ->
        Agent.update(log, &[:delete | &1])
        json(conn, 200, %{"data" => %{}})
      end)

      assert {:error, %ExAtlas.Error{status: 400, provider: :lambda_labs}} =
               ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])

      assert Agent.get(log, &Enum.reverse/1) == [:create, :launch, :delete]
    end

    test "a refused launch whose ruleset delete also fails still returns the launch error", %{
      bypass: bypass,
      opts: opts,
      log: log
    } do
      expect_types(bypass)
      expect_ruleset_flow(bypass, log, 400)

      Bypass.expect_once(bypass, "DELETE", "/firewall-rulesets/rs-1", fn conn ->
        json(conn, 500, %{"error" => %{"code" => "global/internal-error"}})
      end)

      assert {:error, %ExAtlas.Error{status: 400, message: message}} =
               ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])

      assert message =~ "refused the launch"
    end

    test "a launch answered 200 with no instance id deletes the ruleset it created", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/firewall-rulesets", fn conn ->
        json(conn, 200, %{"data" => ruleset(%{"id" => "rs-1"})})
      end)

      Bypass.expect_once(bypass, "POST", @launch, fn conn ->
        json(conn, 200, %{"data" => %{"instance_ids" => []}})
      end)

      Bypass.expect_once(bypass, "DELETE", "/firewall-rulesets/rs-1", fn conn ->
        send(test_pid, :ruleset_deleted)
        json(conn, 200, %{"data" => %{}})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider}} =
               ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])

      assert_received :ruleset_deleted
    end

    test "a ruleset create answered 200 with no id is a :provider error and launches nothing", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)

      Bypass.expect_once(bypass, "POST", "/firewall-rulesets", fn conn ->
        json(conn, 200, %{"data" => %{"name" => "atlas-x"}})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, message: message}} =
               ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])

      assert message =~ "/firewall-rulesets"
    end

    test "us-south-1 launches with no ruleset, since Lambda applies no firewall rules there", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass, %{
        "gpu_1x_h100_pcie" => type_entry("gpu_1x_h100_pcie", 249, 1, "H100", ["us-south-1"])
      })

      expect_launch(bypass)

      assert {:ok, %{region: "us-south-1"}} =
               ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])

      body = launched_body()
      assert body["region_name"] == "us-south-1"
      refute Map.has_key?(body, "firewall_rulesets")
    end

    test "a source_network that is not a string is :validation before any request", %{opts: opts} do
      opts = Keyword.put(opts, :provider_opts, %{source_network: 5, ssh_key_name: "deploy"})

      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(opts ++ [ports: [{80, :http}]])

      assert message =~ "source_network"
    end
  end

  describe "spawn_compute/1 unsupported fields" do
    test "spot, template_id, network_volume_id and command are :unsupported, and no request", %{
      opts: opts
    } do
      for extra <- [
            [spot: true],
            [template_id: "tpl_1"],
            [network_volume_id: "vol_1"],
            [command: ["python", "train.py"]]
          ] do
        assert {:error, %ExAtlas.Error{kind: :unsupported, provider: :lambda_labs}} =
                 ExAtlas.spawn_compute(opts ++ extra),
               "expected #{inspect(Keyword.keys(extra))} to be unsupported"
      end
    end
  end

  describe "spawn_compute/1 launch retries" do
    test "a launch answered 503 is sent once and returns :provider", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)

      # expect_once fails the test if a retry reaches the server.
      Bypass.expect_once(bypass, "POST", @launch, fn conn ->
        json(conn, 503, %{"error" => %{"code" => "global/internal-error", "message" => "busy"}})
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, status: 503}} = ExAtlas.spawn_compute(opts)
    end

    test "a launch answered 429 then 200 launches once and returns the instance", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      calls = :counters.new(1, [])

      Bypass.expect(bypass, "POST", @launch, fn conn ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> json(429, %{"error" => %{"code" => "global/rate-limited", "message" => "slow"}})
        else
          json(conn, 200, %{"data" => %{"instance_ids" => [@launched_id]}})
        end
      end)

      assert {:ok, %{id: @launched_id}} = ExAtlas.spawn_compute(opts)
      assert :counters.get(calls, 1) == 2
    end
  end

  describe "spawn_compute/1 secrets" do
    test "a launch error that echoes an env value withholds the message and the body", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)

      Bypass.expect_once(bypass, "POST", @launch, fn conn ->
        json(conn, 400, %{
          "error" => %{
            "code" => "global/invalid-parameters",
            "message" => "bad user_data: export HF_TOKEN='#{@hf_token}'",
            "suggestion" => "check #{@hf_token}"
          }
        })
      end)

      assert {:error, %ExAtlas.Error{kind: :provider, status: 400} = error} =
               ExAtlas.spawn_compute(opts ++ [env: %{"HF_TOKEN" => @hf_token}])

      assert error.message =~ "global/invalid-parameters"
      assert error.raw == %{"error" => %{"code" => "global/invalid-parameters"}}
      refute inspect(error) =~ @hf_token
      refute Exception.message(error) =~ @hf_token
    end

    # An echo need not hold the value as given: the script holds it shell-quoted,
    # JSON escapes it, and Lambda may cut it short.
    test "a launch error that echoes a quoted, escaped or cut value withholds it too", %{
      bypass: bypass,
      opts: opts
    } do
      value = "p'ss\nw0rd-#{@hf_token}"

      for echo <- [
            "export DB_PASS='p'\\''ss",
            Jason.encode!(value),
            "value starting #{String.slice(value, 0, 6)} is invalid"
          ] do
        expect_types(bypass)

        Bypass.expect_once(bypass, "POST", @launch, fn conn ->
          json(conn, 400, %{
            "error" => %{"code" => "global/invalid-parameters", "message" => echo}
          })
        end)

        assert {:error, %ExAtlas.Error{kind: :provider, status: 400} = error} =
                 ExAtlas.spawn_compute(opts ++ [env: %{"DB_PASS" => value}])

        assert error.message =~ "global/invalid-parameters"
        refute inspect(error) =~ echo
      end
    end

    test "the returned Compute prints no auth token and no env value", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, compute} =
               ExAtlas.spawn_compute(opts ++ [env: %{"HF_TOKEN" => @hf_token}, auth: :bearer])

      # Control: the token exists, so the refute below is not vacuous.
      assert is_binary(compute.auth.token)
      refute inspect(compute) =~ compute.auth.token
      refute inspect(compute, structs: false) =~ @hf_token
    end
  end

  # Runs `script` under bash with a `docker` stub first on PATH. The stub
  # records its argv and, for each `-e NAME`, the value it read from its own
  # environment.
  defp run_with_stub_docker(script, dir) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    # `id` would write a marker if the shell ever ran `$(id)`.
    stub_id = Path.join(bin, "id")
    File.write!(stub_id, "#!/bin/bash\ntouch \"$OUT/ran-id\"\n")

    stub = Path.join(bin, "docker")

    File.write!(stub, ~S"""
    #!/bin/bash
    # The daemon answers `docker info` from the second call on.
    if [ "$1" = info ]; then
      n=$(cat "$OUT/info_calls" 2>/dev/null || echo 0)
      echo $((n + 1)) > "$OUT/info_calls"
      [ "$n" -ge 1 ]
      exit $?
    fi
    printf '%s\0' "$@" > "$OUT/argv"
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-e" ]; then printf '%s' "${!arg}" > "$OUT/env.$arg"; fi
      prev="$arg"
    done
    """)

    File.chmod!(stub, 0o755)
    File.chmod!(stub_id, 0o755)
    path = Path.join(dir, "user_data.sh")
    File.write!(path, script)

    {output, status} =
      System.cmd("bash", [path],
        env: [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"OUT", dir}],
        stderr_to_stdout: true
      )

    assert status == 0, output

    argv = dir |> Path.join("argv") |> File.read!() |> String.split(<<0>>, trim: true)

    env =
      for file <- File.ls!(dir), String.starts_with?(file, "env."), into: %{} do
        {String.replace_prefix(file, "env.", ""), File.read!(Path.join(dir, file))}
      end

    info_calls = dir |> Path.join("info_calls") |> File.read!() |> String.trim()

    %{argv: argv, env: env, info_calls: String.to_integer(info_calls)}
  end
end
