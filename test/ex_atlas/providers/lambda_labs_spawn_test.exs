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

  defp tags(body), do: Map.new(body["tags"], &{&1["key"], &1["value"]})

  describe "spawn_compute/1 picks the type and region" do
    test "launches the catalog's type in the first hinted region with capacity", %{
      bypass: bypass,
      opts: opts
    } do
      expect_types(bypass)
      expect_launch(bypass)
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

      run = run_with_stubs(script, dir)

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

    # bash refuses `export` for a readonly name, which stops the script before
    # `docker run`, and rewrites or drops a special one, so the container
    # would get another value.
    test "an env name bash keeps for itself is :validation naming it, and no launch", %{
      opts: opts
    } do
      for name <-
            ~w(UID EUID PPID SHELLOPTS BASHOPTS BASH_VERSINFO RANDOM SRANDOM SECONDS LINENO) ++
              ~w(GROUPS FUNCNAME HISTCMD OPTIND DIRSTACK PIPESTATUS BASHPID EPOCHSECONDS) ++
              ~w(EPOCHREALTIME BASH_ENV BASH_ARGV0 COMP_WORDS _) do
        assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
                 ExAtlas.spawn_compute(opts ++ [env: %{name => "1000"}]),
               "expected #{name} to be refused"

        assert message =~ inspect(name)
      end
    end

    @tag :tmp_dir
    test "control: a name that only contains one of bash's names launches and reaches docker",
         %{bypass: bypass, opts: opts, tmp_dir: dir} do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [env: %{"APP_UID" => "1000"}])

      assert run_with_stubs(launched_body()["user_data"], dir).env["APP_UID"] == "1000"
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

      # A shell argument cannot carry a NUL byte either.
      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(Keyword.put(opts, :image, "img" <> <<0>> <> "x"))

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

  describe "spawn_compute/1 command" do
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

    # Lambda gives an instance no key to delete itself, so the default would
    # leave a finished instance billing with nothing to end it.
    test "with self_terminate: true and no callback is :validation, and no request", %{
      opts: opts
    } do
      assert {:error, %ExAtlas.Error{kind: :validation, provider: :lambda_labs, message: message}} =
               ExAtlas.spawn_compute(opts ++ [command: ["python", "train.py"]])

      assert message =~ "self_terminate: false"
      assert message =~ "ExAtlas.Orchestrator.run_task/1"
    end

    @tag :tmp_dir
    test "with self_terminate: false runs the command after the image, each argument quoted", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: dir
    } do
      expect_types(bypass)
      expect_launch(bypass)

      command = ["python", "it's $(id) `whoami`", "--epochs=3"]

      assert {:ok, _} =
               ExAtlas.spawn_compute(opts ++ [command: command, self_terminate: false])

      run = run_with_stubs(launched_body()["user_data"], dir)

      assert run.argv ==
               ~w(run --detach --name atlas --gpus all --restart no vllm/vllm-openai:latest) ++
                 command

      # Nothing reports without a callback.
      assert run.systemd_run_argv == nil
      refute File.exists?(Path.join(dir, "ran-id"))
    end

    test "command: [] runs the image's own command and launches", %{bypass: bypass, opts: opts} do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [command: []])
    end

    @tag :tmp_dir
    test "with a callback, the host waits on the container and POSTs its exit code to /finish",
         %{bypass: bypass, opts: opts, tmp_dir: dir, callback: callback} do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, _} =
               ExAtlas.spawn_compute(
                 opts ++ [command: ["python", "train.py"], callback: callback]
               )

      run = run_with_stubs(launched_body()["user_data"], dir, wait_code: 3)

      assert Enum.take(run.argv, -3) == ["vllm/vllm-openai:latest", "python", "train.py"]
      token = run.env["ATLAS_CALLBACK_TOKEN"]
      assert is_binary(token) and token != ""

      assert ["--unit=atlas-finish", "--collect", "--quiet", "/bin/bash", unit_file, docker] =
               run.systemd_run_argv

      assert docker == Path.join([dir, "bin", "docker"])
      assert run.wait_argv == ["wait", "atlas"]
      assert run.unit_status == 0, run.unit_output

      # The token reaches curl on stdin, never on its argv.
      assert run.curl_stdin == "Authorization: Bearer #{token}\n"
      assert ["-H", "@-"] in Enum.chunk_every(run.curl_argv, 2, 1)
      assert ["-d", ~s({"exit_code":3})] in Enum.chunk_every(run.curl_argv, 2, 1)
      assert List.last(run.curl_argv) == "https://app.example.com/atlas/cb/finish"

      # The unit's script holds the token, readable by root alone.
      # The unit's script holds the token, readable by root alone, and
      # deletes itself once the unit reads it.
      assert run.unit_script =~ token
      assert run.unit_script_mode == "-rw-------"
      refute File.exists?(unit_file)
    end

    @tag :tmp_dir
    test "with a callback, no env value or token reaches an argv, a log or the unit's environment",
         %{bypass: bypass, opts: opts, tmp_dir: dir, callback: callback} do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, compute} =
               ExAtlas.spawn_compute(
                 opts ++
                   [
                     command: ["python", "train.py"],
                     callback: callback,
                     auth: :bearer,
                     env: %{
                       "HF_TOKEN" => @hf_token,
                       "DBUS_SYSTEM_BUS_ADDRESS" => "unix:path=/tmp/evil-bus"
                     }
                   ]
               )

      run = run_with_stubs(launched_body()["user_data"], dir, wait_code: 0)
      token = run.env["ATLAS_CALLBACK_TOKEN"]

      # Controls: each value reached the container, so each refute below can fail.
      assert run.env["HF_TOKEN"] == @hf_token
      assert run.env["ATLAS_PRESHARED_KEY"] == compute.auth.token
      assert run.env["DBUS_SYSTEM_BUS_ADDRESS"] == "unix:path=/tmp/evil-bus"

      for secret <- [token, @hf_token, compute.auth.token] do
        # cloud-init logs the script's output; journald logs the unit's.
        refute run.output =~ secret
        refute run.unit_output =~ secret
        refute Enum.any?(run.argv, &String.contains?(&1, secret))
        refute Enum.any?(run.systemd_run_argv, &String.contains?(&1, secret))
        refute Enum.any?(run.curl_argv, &String.contains?(&1, secret))
        refute run.curl_env =~ secret
        # The container's variables stay in the subshell that runs docker, so
        # none of them steers systemd-run or lands in the unit.
        refute run.systemd_run_env =~ secret
      end

      refute run.systemd_run_env =~ "evil-bus"
      refute run.unit_script =~ @hf_token
      refute run.unit_script =~ compute.auth.token
    end

    @tag :tmp_dir
    test "with a callback and no command, the host reports the image's own exit", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: dir,
      callback: callback
    } do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [callback: callback])

      run = run_with_stubs(launched_body()["user_data"], dir, wait_code: 0)

      assert List.last(run.argv) == "vllm/vllm-openai:latest"
      assert ["-d", ~s({"exit_code":0})] in Enum.chunk_every(run.curl_argv, 2, 1)
    end

    # `docker wait` prints an error, not a code, when the container is gone.
    @tag :tmp_dir
    test "with a callback, a docker wait that prints no exit code POSTs 125", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: dir,
      callback: callback
    } do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, _} = ExAtlas.spawn_compute(opts ++ [callback: callback])

      run = run_with_stubs(launched_body()["user_data"], dir, wait_code: "no-such-container")

      assert run.wait_argv == ["wait", "atlas"]
      assert ["-d", ~s({"exit_code":125})] in Enum.chunk_every(run.curl_argv, 2, 1)
    end

    # The container never started, so nothing would end the instance before
    # max_runtime_ms: the report ends the task at once instead.
    @tag :tmp_dir
    test "with a callback, a docker run that fails still POSTs 125", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: dir,
      callback: callback
    } do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, _} =
               ExAtlas.spawn_compute(opts ++ [command: ["true"], callback: callback])

      run =
        run_with_stubs(launched_body()["user_data"], dir, run_exit: 125, wait_code: :no_container)

      # Control: docker run was called and failed.
      assert hd(run.argv) == "run"
      assert run.wait_argv == ["wait", "atlas"]
      assert run.unit_status == 0, run.unit_output
      assert ["-d", ~s({"exit_code":125})] in Enum.chunk_every(run.curl_argv, 2, 1)
    end

    @tag :tmp_dir
    test "without a callback, a docker run that fails fails the script", %{
      bypass: bypass,
      opts: opts,
      tmp_dir: dir
    } do
      expect_types(bypass)
      expect_launch(bypass)

      assert {:ok, _} = ExAtlas.spawn_compute(opts)

      run = run_with_stubs(launched_body()["user_data"], dir, run_exit: 125, script_exit: 125)

      assert run.systemd_run_argv == nil
    end

    test "command: without image: is :validation, and no launch", %{opts: opts} do
      assert {:error, %ExAtlas.Error{kind: :validation, message: message}} =
               ExAtlas.spawn_compute(
                 Keyword.delete(opts, :image) ++ [command: ["true"], self_terminate: false]
               )

      assert message =~ ":command"
    end

    test "a command argument with a NUL byte or not UTF-8 is :validation, and no launch", %{
      opts: opts
    } do
      for arg <- ["a" <> <<0>> <> @hf_token, @hf_token <> <<0xFF>>] do
        assert {:error, %ExAtlas.Error{kind: :validation, message: message} = error} =
                 ExAtlas.spawn_compute(opts ++ [command: ["run", arg], self_terminate: false])

        assert message =~ ":command"
        refute inspect(error) =~ @hf_token
      end
    end
  end

  describe "spawn_compute/1 unsupported fields" do
    test "spot, template_id and network_volume_id are :unsupported, and no request", %{
      opts: opts
    } do
      for extra <- [
            [spot: true],
            [template_id: "tpl_1"],
            [network_volume_id: "vol_1"]
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

  # Runs `script` under bash with stubs first on PATH, the way cloud-init runs
  # it as root on the instance:
  #
  #   * `docker` records its `run` argv and, for each `-e NAME`, the value it
  #     read from its own environment; `docker wait` prints `:wait_code`;
  #   * `systemd-run` records its argv and environment, then runs its command
  #     the way systemd starts a unit: in a clean environment, after the
  #     script has returned;
  #   * `curl` records its argv, its stdin and its environment.
  #
  # Each stub writes under `dir`, which is baked into it: the unit's clean
  # environment carries no `OUT`.
  defp run_with_stubs(script, dir, opts \\ []) do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)

    wait_body =
      case Keyword.get(opts, :wait_code, 0) do
        :no_container -> "echo 'Error response from daemon: No such container: atlas' >&2; exit 1"
        code -> "echo #{code}; exit 0"
      end

    run_body =
      case Keyword.get(opts, :run_exit, 0) do
        0 -> "echo 4f1c0ffee"
        code -> "echo 'docker: Error response from daemon: pull access denied' >&2; exit #{code}"
      end

    # ExUnit's tmp_dir name holds the test name, `;` and `'` included.
    out = ExAtlas.Providers.Shell.quote_arg(dir)

    stub!(bin, "id", ~s(touch #{out}/ran-id\n))

    stub!(bin, "docker", """
    OUT=#{out}
    # The daemon answers `docker info` from the second call on.
    if [ "$1" = info ]; then
      n=$(cat "$OUT/info_calls" 2>/dev/null || echo 0)
      echo $((n + 1)) > "$OUT/info_calls"
      [ "$n" -ge 1 ]
      exit $?
    fi
    if [ "$1" = wait ]; then
      printf '%s\\0' "$@" > "$OUT/wait.argv"
      #{wait_body}
    fi
    printf '%s\\0' "$@" > "$OUT/argv"
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-e" ]; then printf '%s' "${!arg}" > "$OUT/env.$arg"; fi
      prev="$arg"
    done
    #{run_body}
    """)

    stub!(bin, "systemd-run", """
    OUT=#{out}
    printf '%s\\0' "$@" > "$OUT/systemd_run.argv"
    env > "$OUT/systemd_run.env"
    while [ "${1#--}" != "$1" ]; do shift; done
    printf '%s\\n' "$@" > "$OUT/unit.cmd"
    # The unit's script as systemd-run hands it over: its bytes and mode.
    cp "$2" "$OUT/unit_script"
    ls -ln "$2" | cut -c1-10 > "$OUT/unit_script.mode"
    """)

    stub!(bin, "curl", """
    OUT=#{out}
    printf '%s\\0' "$@" > "$OUT/curl.argv"
    cat > "$OUT/curl.stdin"
    env > "$OUT/curl.env"
    """)

    path = Path.join(dir, "user_data.sh")
    File.write!(path, script)
    tmp = Path.join(dir, "tmp")
    File.mkdir_p!(tmp)

    {output, status} =
      System.cmd("bash", [path],
        env: [{"PATH", bin <> ":" <> System.get_env("PATH")}, {"OUT", dir}, {"TMPDIR", tmp}],
        stderr_to_stdout: true
      )

    assert status == Keyword.get(opts, :script_exit, 0), output

    # systemd starts the unit after `systemd-run` returns, in an environment
    # holding only systemd's default PATH, with our stubs first.
    {unit_output, unit_status} = run_unit(dir, bin)

    env =
      for file <- File.ls!(dir), String.starts_with?(file, "env."), into: %{} do
        {String.replace_prefix(file, "env.", ""), File.read!(Path.join(dir, file))}
      end

    %{
      argv: read_argv(dir, "argv"),
      env: env,
      info_calls:
        dir |> Path.join("info_calls") |> File.read!() |> String.trim() |> String.to_integer(),
      output: output,
      unit_output: unit_output,
      unit_status: unit_status,
      systemd_run_argv: read_argv(dir, "systemd_run.argv"),
      systemd_run_env: read_file(dir, "systemd_run.env"),
      wait_argv: read_argv(dir, "wait.argv"),
      curl_argv: read_argv(dir, "curl.argv"),
      curl_stdin: read_file(dir, "curl.stdin"),
      curl_env: read_file(dir, "curl.env"),
      unit_script: read_file(dir, "unit_script"),
      unit_script_mode: dir |> read_file("unit_script.mode") |> then(&(&1 && String.trim(&1)))
    }
  end

  defp run_unit(dir, bin) do
    case File.read(Path.join(dir, "unit.cmd")) do
      {:ok, cmd} ->
        [exe | args] = String.split(cmd, "\n", trim: true)

        System.cmd("env", ["-i", "PATH=#{bin}:/usr/bin:/bin", exe | args], stderr_to_stdout: true)

      {:error, :enoent} ->
        {nil, nil}
    end
  end

  defp stub!(bin, name, body) do
    path = Path.join(bin, name)
    File.write!(path, "#!/bin/bash\n" <> body)
    File.chmod!(path, 0o755)
  end

  defp read_argv(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, raw} -> String.split(raw, <<0>>, trim: true)
      {:error, :enoent} -> nil
    end
  end

  defp read_file(dir, name) do
    case File.read(Path.join(dir, name)) do
      {:ok, raw} -> raw
      {:error, :enoent} -> nil
    end
  end
end
