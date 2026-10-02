defmodule ExAtlas.Providers.RunPod.TranslateTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Callback
  alias ExAtlas.Providers.RunPod.Translate
  alias ExAtlas.Spec
  alias ExAtlas.Test.CurlShim

  describe "compute_request_to_pod_create/1" do
    test "maps canonical GPU to RunPod id" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _auth} = Translate.compute_request_to_pod_create(req)
      assert body["gpu"] == %{"id" => "NVIDIA H100 80GB HBM3", "count" => 1}
    end

    test "renders ports into '<port>/<proto>' strings" do
      req =
        Spec.ComputeRequest.new!(
          gpu: :a100_80g,
          image: "x",
          ports: [{8000, :http}, {22, :tcp}]
        )

      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["ports"] == ["8000/http", "22/tcp"]
    end

    test "maps cloud_type atoms" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", cloud_type: :secure)
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["cloud"] == "SECURE"
    end

    test "no :command leaves cmd unset so the image's own CMD runs" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _} = Translate.compute_request_to_pod_create(req)
      refute Map.has_key?(body, "cmd")
    end

    test "self_terminate: false sends the command through verbatim" do
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          command: ["/app/train.sh", "--epochs", "3"],
          self_terminate: false
        )

      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["cmd"] == ["/app/train.sh", "--epochs", "3"]
    end

    @tag :tmp_dir
    test "the self-terminating wrapper runs the command, then DELETEs the pod", %{tmp_dir: tmp} do
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          command: ["sh", "-c", "echo ran > #{tmp}/ran"]
        )

      {body, _} = Translate.compute_request_to_pod_create(req)

      assert {0, log} = run_start_cmd(body["cmd"], tmp)

      assert File.read!(Path.join(tmp, "ran")) == "ran\n"
      assert log =~ "-X DELETE"
      assert log =~ "https://api.runpod.io/v2/pods/pod_abc"
      # The key reaches curl on stdin: argv shows in `ps` to every process
      # in the container.
      refute log =~ "pod-scoped-key"
      assert curl_config(tmp) =~ ~s(header = "Authorization: Bearer pod-scoped-key")
      # A hung DELETE must not hold the pod, and its bill, open for ever.
      assert log =~ "-m 30"
    end

    @tag :tmp_dir
    test "the pod is deleted even when the command exits non-zero", %{tmp_dir: tmp} do
      # A crashed trainer that left the pod up would bill until the
      # `:max_runtime_ms` backstop fired, which is the trap this exists to
      # close. `trap ... EXIT` fires on any shell exit, not just a clean one.
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", command: ["sh", "-c", "exit 3"])
      {body, _} = Translate.compute_request_to_pod_create(req)

      assert {3, log} = run_start_cmd(body["cmd"], tmp)
      assert log =~ "https://api.runpod.io/v2/pods/pod_abc"
    end

    @tag :tmp_dir
    test "command arguments survive the shell wrapper intact", %{tmp_dir: tmp} do
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          command: ["sh", "-c", "printf '%s' \"$1\" > #{tmp}/arg", "sh", "it's a $PATH; rm -rf /"]
        )

      {body, _} = Translate.compute_request_to_pod_create(req)

      assert {0, _log} = run_start_cmd(body["cmd"], tmp)
      assert File.read!(Path.join(tmp, "arg")) == "it's a $PATH; rm -rf /"
    end

    # Run a generated `dockerStartCmd` for real (see `CurlShim`). Returns
    # `{exit_status, curl_argv_log}`; `curl_config/1` reads what curl took on
    # stdin.
    defp run_start_cmd(cmd, tmp, extra_env \\ []) do
      env = [{"RUNPOD_POD_ID", "pod_abc"}, {"RUNPOD_API_KEY", "pod-scoped-key"}] ++ extra_env
      {status, log, _config} = CurlShim.run(cmd, tmp, env)
      {status, log}
    end

    defp curl_config(tmp), do: File.read!(Path.join(tmp, "curl.config"))

    test "mints a bearer token when auth: :bearer" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", auth: :bearer)
      {body, auth} = Translate.compute_request_to_pod_create(req)
      assert %{scheme: :bearer, token: _, hash: _, header: _} = auth

      assert body["env"]["ATLAS_PRESHARED_KEY"] == auth.token
    end

    test "drops nil fields so RunPod doesn't complain" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _} = Translate.compute_request_to_pod_create(req)
      refute Map.has_key?(body, "mounts")
      refute Map.has_key?(body, "templateId")
      refute Map.has_key?(body, "cloud")
    end

    # Runpod v2 refused every body sent without `disk` in the 2026-09-30 probe
    # (issue 34), so a spawn with no size asks for v1's default, 50 GB.
    test "no container_disk_gb sends disk: 50, v1's default" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["disk"] == 50
    end

    # REST v2 applies body fields over the template's own, so an empty `ports`
    # list or a default `disk` would replace the template's.
    test "template_id with no ports and no container_disk_gb sends neither ports nor disk" do
      req = Spec.ComputeRequest.new!(gpu: :h100, template_id: "9x4m2p7v")
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["templateId"] == "9x4m2p7v"
      refute Map.has_key?(body, "ports")
      refute Map.has_key?(body, "disk")
    end

    test "template_id with ports and container_disk_gb still sends both" do
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          template_id: "9x4m2p7v",
          ports: [{8000, :http}],
          container_disk_gb: 20
        )

      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["ports"] == ["8000/http"]
      assert body["disk"] == 20
    end

    test "template_id with only container_disk_gb sends the disk and no ports" do
      req = Spec.ComputeRequest.new!(gpu: :h100, template_id: "t", container_disk_gb: 20)
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["disk"] == 20
      refute Map.has_key?(body, "ports")
    end

    test "without template_id an empty ports list is still sent" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["ports"] == []
    end

    test "no volume_gb and no network_volume_id sends no mounts, so no /workspace volume" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _} = Translate.compute_request_to_pod_create(req)
      refute Map.has_key?(body, "mounts")
    end

    test "the body carries no v1 keys, which v2 rejects" do
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          command: ["/app/train.sh"],
          volume_gb: 20,
          container_disk_gb: 30
        )

      {body, _} = Translate.compute_request_to_pod_create(req)

      for key <-
            ~w(interruptible gpuTypeIds gpuCount imageName computeType cloudType dockerStartCmd containerDiskInGb volumeInGb networkVolumeId) do
        refute Map.has_key?(body, key), "v1 key #{key} is still sent"
      end

      assert body["image"] == "x"
      assert ["sh", "-c", _] = body["cmd"]
    end

    test "gpu_count lands in gpu.count" do
      req = Spec.ComputeRequest.new!(gpu: :h100, gpu_count: 4, image: "x")
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["gpu"] == %{"id" => "NVIDIA H100 80GB HBM3", "count" => 4}
    end

    test "env goes out as a map of strings" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", env: %{"MODEL" => "llama"})
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["env"] == %{"MODEL" => "llama"}
    end

    test "volume_gb becomes a persistent mount at /workspace" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", volume_gb: 20)
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["mounts"] == %{"persistent" => %{"size" => 20, "path" => "/workspace"}}
    end

    test "network_volume_id becomes a network mount at /workspace" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", network_volume_id: "vol_1")
      {body, _} = Translate.compute_request_to_pod_create(req)

      assert body["mounts"] == %{
               "network" => [%{"volumeId" => "vol_1", "path" => "/workspace"}]
             }
    end

    test "container_disk_gb becomes disk" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", container_disk_gb: 30)
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["disk"] == 30
    end

    test "cloud_type :community maps to COMMUNITY" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", cloud_type: :community)
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["cloud"] == "COMMUNITY"
    end

    test "cloud_type :any sends no cloud key, so Runpod picks its default, SECURE" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", cloud_type: :any)
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body |> Map.keys() |> Enum.filter(&(&1 =~ ~r/cloud/i)) == []
    end

    test "an unnamed pod gets a name the Reaper's default prefix never matches" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _} = Translate.compute_request_to_pod_create(req)

      assert is_binary(body["name"]) and body["name"] != ""
      refute String.starts_with?(body["name"], "atlas-")
    end

    test "a given name is sent as is" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", name: "atlas-train-1")
      {body, _} = Translate.compute_request_to_pod_create(req)
      assert body["name"] == "atlas-train-1"
    end

    test "provider_opts merge into nested objects and keep gpu.id" do
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          provider_opts: %{gpu: %{minCudaVersion: "12.1"}, globalNetworking: true}
        )

      {body, _} = Translate.compute_request_to_pod_create(req)

      assert body["gpu"] == %{
               "id" => "NVIDIA H100 80GB HBM3",
               "count" => 1,
               "minCudaVersion" => "12.1"
             }

      assert body["globalNetworking"] == true
    end

    test "raises for GPU atom with no RunPod mapping" do
      req = Spec.ComputeRequest.new!(gpu: :nonexistent_gpu, image: "x")

      assert_raise ArgumentError, ~r/no mapping/, fn ->
        Translate.compute_request_to_pod_create(req)
      end
    end
  end

  describe "pod_to_compute/2" do
    test "keeps the pod env out of raw and every other raw key in it" do
      pod =
        Map.put(fixture("running"), "env", %{
          "HF_TOKEN" => "hf-secret-5d1",
          "ATLAS_CALLBACK_TOKEN" => "cb-secret-8e2"
        })

      compute = Translate.pod_to_compute(pod)

      refute Map.has_key?(compute.raw, "env")
      assert compute.raw == Map.delete(pod, "env")
      refute inspect(compute, structs: false, limit: :infinity) =~ "hf-secret-5d1"
      refute inspect(compute, structs: false, limit: :infinity) =~ "cb-secret-8e2"
    end

    test "a pod with no env keeps its raw as given" do
      pod = Map.delete(fixture("running"), "env")
      assert Translate.pod_to_compute(pod).raw == pod
    end

    test "threads auth through" do
      auth = %{scheme: :bearer, token: "t", hash: "h", header: "Authorization: Bearer t"}
      compute = Translate.pod_to_compute(fixture("running"), auth)
      assert compute.auth == auth
    end

    for {status, expected} <- [
          provisioning: :provisioning,
          starting: :provisioning,
          running: :running,
          exited: :stopped,
          error: :failed,
          terminated: :terminated
        ] do
      test "a #{status} pod reads as #{inspect(expected)}" do
        assert Translate.pod_to_compute(fixture(unquote(to_string(status)))).status ==
                 unquote(expected)
      end
    end

    test "a status outside the v2 enum reads as :provisioning, never as dead" do
      # An unclassifiable pod is not a dead one, and `UpstreamStatus` counts
      # :provisioning as alive: uncertainty never tears a resource down.
      assert Translate.pod_to_compute(%{"id" => "abc"}).status == :provisioning

      assert Translate.pod_to_compute(%{fixture("running") | "status" => "HIBERNATING"}).status ==
               :provisioning
    end

    test "carries id, name, image, gpu, cost and data center" do
      compute = Translate.pod_to_compute(fixture("running"))

      assert compute.id == "7h9k2m4n6p"
      assert compute.name == "pytorch-training"
      assert compute.image == "runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404"
      assert compute.gpu_type == "NVIDIA GeForce RTX 4090"
      assert compute.gpu_count == 1
      assert compute.cost_per_hour == 0.44
      assert compute.region == "US-KS-2"
    end

    test "created_at is startedAt, the last time the pod started" do
      assert Translate.pod_to_compute(fixture("running")).created_at == ~U[2026-06-01 12:02:00Z]
    end

    test "created_at falls back to createdAt before the pod has started" do
      assert Translate.pod_to_compute(fixture("provisioning")).created_at ==
               ~U[2026-06-01 12:00:00Z]
    end

    test "an unparseable timestamp is nil rather than a crash" do
      pod = %{"id" => "abc", "startedAt" => "not a date", "createdAt" => nil}
      assert Translate.pod_to_compute(pod).created_at == nil
    end

    test "a running pod's ports carry the proxy URL and the public TCP mapping" do
      compute = Translate.pod_to_compute(fixture("running"))

      assert compute.public_ip == "195.26.233.3"

      assert compute.ports == [
               %{
                 internal: 8888,
                 external: nil,
                 protocol: :http,
                 url: "https://7h9k2m4n6p-8888.proxy.runpod.net"
               },
               %{internal: 22, external: 34_446, protocol: :tcp, url: "tcp://195.26.233.3:34446"}
             ]
    end

    test "a pod that is not running still lists its configured ports" do
      compute = Translate.pod_to_compute(fixture("provisioning"))

      assert compute.public_ip == nil

      assert compute.ports == [
               %{
                 internal: 8888,
                 external: nil,
                 protocol: :http,
                 url: "https://7h9k2m4n6p-8888.proxy.runpod.net"
               },
               %{internal: 22, external: nil, protocol: :tcp, url: nil}
             ]
    end

    test "fields of the wrong type read as absent, not a crash" do
      pod = %{
        "id" => "abc",
        "status" => 5,
        "gpu" => "RTX 4090",
        "runtime" => "up",
        "ports" => "8000/http",
        "startedAt" => 7,
        "createdAt" => nil
      }

      compute = Translate.pod_to_compute(pod)

      assert compute.status == :provisioning
      assert compute.gpu_type == nil
      assert compute.gpu_count == 1
      assert compute.ports == []
      assert compute.public_ip == nil
      assert compute.created_at == nil
    end

    test "a malformed port entry is skipped, not a crash" do
      pod = %{fixture("provisioning") | "ports" => ["8000/http", "nonsense", 42, "x/tcp"]}
      assert [%{internal: 8000}] = Translate.pod_to_compute(pod).ports
    end
  end

  defp fixture(name) do
    "test/fixtures/runpod/v2/pod_#{name}.json" |> File.read!() |> Jason.decode!()
  end

  describe "gpu_types/2" do
    test "maps each recorded GPU from the two catalog reads" do
      gpus = Translate.gpu_types(recorded("secure"), recorded("community"))
      by_id = Map.new(gpus, &{&1.id, &1})

      assert %Spec.GpuType{
               provider: :runpod,
               display_name: "RTX 4090",
               memory_gb: 24,
               lowest_price_per_hour: 0.34,
               stock: :low,
               cloud_type: :any
             } = by_id["NVIDIA GeForce RTX 4090"]

      assert %{
               display_name: "H100 SXM",
               memory_gb: 80,
               lowest_price_per_hour: 2.69,
               stock: :medium
             } =
               by_id["NVIDIA H100 80GB HBM3"]

      assert Enum.all?(gpus, &(&1.spot_price_per_hour == nil))
    end

    test "a GPU on one cloud takes that cloud's price, never the zero on the other" do
      by_id =
        Map.new(Translate.gpu_types(recorded("secure"), recorded("community")), &{&1.id, &1})

      assert %{cloud_type: :community, lowest_price_per_hour: 1, stock: :unavailable} =
               by_id["NVIDIA A100-SXM4-40GB"]

      assert %{cloud_type: :secure, lowest_price_per_hour: 2.39} =
               by_id["AMD Instinct MI300X OAM"]
    end

    test "a GPU offered on neither cloud has no price and no stock" do
      assert %{cloud_type: :any, lowest_price_per_hour: nil, stock: :unavailable} =
               Translate.gpu_types(recorded("secure"), recorded("community"))
               |> Enum.find(&(&1.id == "unknown"))
    end

    test "stock is the best level of the clouds the GPU is offered on" do
      by_id = edge()

      assert %{stock: :high, lowest_price_per_hour: 0.3, cloud_type: :any} = by_id["GPU A"]
      # Control for the two below: A's secure LOW did not beat its community HIGH.
      assert %{stock: :high, cloud_type: :secure} = by_id["GPU B"]
      assert %{stock: :low, cloud_type: :community} = by_id["GPU C"]
      assert %{stock: :medium} = by_id["GPU D"]
      assert %{stock: :unavailable, lowest_price_per_hour: 1.1} = by_id["GPU E"]
      assert %{stock: :unknown} = by_id["GPU F"]
    end

    test "a GPU listed in one read only still appears" do
      assert %{stock: :medium, raw: %{"SECURE" => nil, "COMMUNITY" => %{"id" => "GPU G"}}} =
               edge()["GPU G"]
    end

    test "raw holds each cloud's entry, so data centers stay reachable" do
      %{raw: %{"SECURE" => secure, "COMMUNITY" => community}} = edge()["GPU A"]
      assert [%{"id" => "US-KS-2"}] = secure["dataCenters"]
      assert [%{"id" => "EU-RO-1"}] = community["dataCenters"]
    end

    test "entries with no cudaVersions, dataCenters, serverless price or pool map" do
      assert %{display_name: "B", memory_gb: 192} = edge()["GPU B"]
    end

    defp recorded(cloud) do
      "test/fixtures/runpod/v2/catalog_gpus_#{cloud}.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("gpus")
    end

    defp edge do
      %{"secure" => secure, "community" => community} =
        "test/fixtures/runpod/v2/catalog_gpus_edge.json" |> File.read!() |> Jason.decode!()

      Translate.gpu_types(secure, community) |> Map.new(&{&1.id, &1})
    end
  end

  describe "job_response_to_job/2" do
    test "maps RunPod statuses" do
      assert %{status: :completed} =
               Translate.job_response_to_job(%{"id" => "j", "status" => "COMPLETED"})

      assert %{status: :in_queue} =
               Translate.job_response_to_job(%{"id" => "j", "status" => "IN_QUEUE"})

      assert %{status: :failed} =
               Translate.job_response_to_job(%{"id" => "j", "status" => "FAILED"})
    end
  end

  describe "pod callbacks" do
    setup do
      secret = String.duplicate("translate-test-callback-secret", 2)
      Application.put_env(:ex_atlas, :callback, secret: secret)
      on_exit(fn -> Application.delete_env(:ex_atlas, :callback) end)

      {:ok, opts} = Callback.prepare(callback: "https://app.example.com/atlas/cb")
      %{callback: opts[:callback]}
    end

    defp env_value(body, key), do: body["env"][key]

    defp callback_env do
      [
        {"ATLAS_CALLBACK_URL", "https://app.example.com/atlas/cb"},
        {"ATLAS_CALLBACK_TOKEN", "a-token"},
        {"ATLAS_TASK_ID", "a-task"}
      ]
    end

    test "no callback injects nothing — the request is byte-identical to today" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", command: ["/app/train.sh"])
      {body, _} = Translate.compute_request_to_pod_create(req)

      assert env_value(body, "ATLAS_CALLBACK_URL") == nil
      assert env_value(body, "ATLAS_CALLBACK_TOKEN") == nil
      assert env_value(body, "ATLAS_TASK_ID") == nil
      refute body["cmd"] |> List.last() =~ "ATLAS_CALLBACK_URL"
    end

    test "without s3: the env is env: plus auth and callback, with their precedence unchanged",
         %{callback: callback} do
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          auth: :bearer,
          callback: callback,
          env: %{
            "MODEL" => "llama",
            "ATLAS_PRESHARED_KEY" => "from-env",
            "ATLAS_TASK_ID" => "from-env"
          }
        )

      {body, auth} = Translate.compute_request_to_pod_create(req)

      assert Map.keys(body["env"]) |> Enum.sort() ==
               ~w(ATLAS_CALLBACK_TOKEN ATLAS_CALLBACK_URL ATLAS_PRESHARED_KEY ATLAS_TASK_ID MODEL)

      assert body["env"]["MODEL"] == "llama"
      # Auth and callback variables replace an env: entry of the same name, as on main.
      assert body["env"]["ATLAS_PRESHARED_KEY"] == auth.token
      assert body["env"]["ATLAS_TASK_ID"] == callback.task_id
    end

    test "a callback injects the three documented variables", %{callback: callback} do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", callback: callback)
      {body, _} = Translate.compute_request_to_pod_create(req)

      assert env_value(body, "ATLAS_CALLBACK_URL") == "https://app.example.com/atlas/cb"
      assert env_value(body, "ATLAS_TASK_ID") == callback.task_id
    end

    test "the injected token verifies back to that task alone", %{callback: callback} do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", callback: callback)
      {body, _} = Translate.compute_request_to_pod_create(req)

      assert {:ok, claims} = Callback.verify(env_value(body, "ATLAS_CALLBACK_TOKEN"))
      assert claims.task_id == callback.task_id
    end

    test "the callback token is not the preshared key", %{callback: callback} do
      req =
        Spec.ComputeRequest.new!(gpu: :h100, image: "x", auth: :bearer, callback: callback)

      {body, auth} = Translate.compute_request_to_pod_create(req)

      # A browser-held secret must never also authorize writing into the
      # orchestrator, so the two credentials are separate.
      refute env_value(body, "ATLAS_CALLBACK_TOKEN") == auth.token
      assert env_value(body, "ATLAS_PRESHARED_KEY") == auth.token
    end

    test "env injection needs no command — an image's own CMD can report too",
         %{callback: callback} do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", callback: callback)
      {body, _} = Translate.compute_request_to_pod_create(req)

      refute Map.has_key?(body, "cmd")
      assert env_value(body, "ATLAS_TASK_ID") == callback.task_id
    end

    @tag :tmp_dir
    test "the trap posts a clean exit code, then deletes the pod",
         %{tmp_dir: tmp, callback: callback} do
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          command: ["sh", "-c", "echo ran"],
          callback: callback
        )

      {body, _} = Translate.compute_request_to_pod_create(req)

      assert {0, log} = run_start_cmd(body["cmd"], tmp, callback_env())

      assert log =~ ~s({"exit_code":0})
      assert log =~ "https://app.example.com/atlas/cb/finish"
      assert log =~ "-X DELETE"
      refute log =~ "a-token"
      assert curl_config(tmp) =~ ~s(header = "Authorization: Bearer a-token")

      # The marker is written before the pod goes, which is the whole point:
      # a later disappearance is no longer ambiguous.
      [finish, delete] = String.split(log, "\n", trim: true)
      assert finish =~ "/finish"
      assert delete =~ "-X DELETE"
    end

    @tag :tmp_dir
    test "the trap reports the real exit code of a failed command",
         %{tmp_dir: tmp, callback: callback} do
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          command: ["sh", "-c", "exit 3"],
          callback: callback
        )

      {body, _} = Translate.compute_request_to_pod_create(req)

      assert {3, log} = run_start_cmd(body["cmd"], tmp, callback_env())
      assert log =~ ~s({"exit_code":3})
    end

    @tag :tmp_dir
    test "self_terminate: false still reports, and still does not delete",
         %{tmp_dir: tmp, callback: callback} do
      # This is what makes the :finish_grace_ms window useful: without the
      # report, a `self_terminate: false` task can only ever end as :timed_out.
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          command: ["sh", "-c", "exit 0"],
          self_terminate: false,
          callback: callback
        )

      {body, _} = Translate.compute_request_to_pod_create(req)

      assert {0, log} = run_start_cmd(body["cmd"], tmp, callback_env())
      assert log =~ ~s({"exit_code":0})
      refute log =~ "-X DELETE"
    end

    @tag :tmp_dir
    test "a callback host that is down cannot stop the pod deleting itself",
         %{tmp_dir: tmp, callback: callback} do
      # The DELETE is the line that stops the meter. A failing POST in front of
      # it must never be able to skip it.
      req =
        Spec.ComputeRequest.new!(
          gpu: :h100,
          image: "x",
          command: ["sh", "-c", "echo ran"],
          callback: callback
        )

      {body, _} = Translate.compute_request_to_pod_create(req)
      failing_curl(tmp)

      assert {0, log} = run_start_cmd(body["cmd"], tmp, callback_env())
      assert log =~ "-X DELETE"
    end

    # A curl that fails, the way an unreachable host looks.
    defp failing_curl(tmp), do: CurlShim.install(tmp, 7)
  end

  describe "network_volume_request_to_body/1" do
    test "sends name, size and dataCenter, and no type when tier is unset" do
      req =
        Spec.NetworkVolumeRequest.new!(name: "datasets", size_gb: 200, region: "EU-RO-1")

      assert Translate.network_volume_request_to_body(req) ==
               %{"name" => "datasets", "size" => 200, "dataCenter" => "EU-RO-1"}
    end

    test "provider_opts merge over the body" do
      req =
        Spec.NetworkVolumeRequest.new!(
          name: "d",
          size_gb: 10,
          region: "r",
          provider_opts: %{type: "STANDARD"}
        )

      assert %{"type" => "STANDARD"} = Translate.network_volume_request_to_body(req)
    end

    test "maps each tier to RunPod's type" do
      for {tier, type} <- [standard: "STANDARD", high_performance: "HIGH_PERFORMANCE"] do
        req = Spec.NetworkVolumeRequest.new!(name: "d", size_gb: 10, region: "r", tier: tier)
        assert %{"type" => ^type} = Translate.network_volume_request_to_body(req)
      end
    end
  end

  describe "network_volume_to_spec/1" do
    test "normalizes a RunPod volume and keeps the body in raw" do
      raw = %{
        "id" => "2q9m7x4c",
        "name" => "datasets",
        "size" => 200,
        "dataCenter" => "EU-RO-1",
        "type" => "HIGH_PERFORMANCE"
      }

      assert %Spec.NetworkVolume{
               id: "2q9m7x4c",
               provider: :runpod,
               name: "datasets",
               size_gb: 200,
               region: "EU-RO-1",
               tier: :high_performance,
               raw: ^raw
             } = Translate.network_volume_to_spec(raw)
    end

    test "STANDARD maps to :standard and an unknown or missing type to nil" do
      assert %{tier: :standard} =
               Translate.network_volume_to_spec(%{"id" => "a", "type" => "STANDARD"})

      assert %{tier: nil} = Translate.network_volume_to_spec(%{"id" => "a", "type" => "NEW"})
      assert %{tier: nil} = Translate.network_volume_to_spec(%{"id" => "a"})
    end
  end

  describe "template_request_to_body/1" do
    test "maps name, image, ports, env, disk, mounts and cmd" do
      req =
        Spec.TemplateRequest.new!(
          name: "trainer-v7",
          image: "ghcr.io/acme/trainer:7",
          ports: [{8000, :http}, {22, :tcp}],
          env: %{"WANDB_PROJECT" => "atlas"},
          container_disk_gb: 80,
          volume_gb: 100,
          command: ["python", "train.py"]
        )

      assert Translate.template_request_to_body(req) == %{
               "name" => "trainer-v7",
               "image" => "ghcr.io/acme/trainer:7",
               "ports" => ["8000/http", "22/tcp"],
               "env" => %{"WANDB_PROJECT" => "atlas"},
               "disk" => 80,
               "mounts" => %{"persistent" => %{"size" => 100, "path" => "/workspace"}},
               "cmd" => ["python", "train.py"]
             }
    end

    test "a bare request sends only name and image" do
      req = Spec.TemplateRequest.new!(name: "n", image: "i")
      assert Translate.template_request_to_body(req) == %{"name" => "n", "image" => "i"}
    end

    test "ssh: false and jupyter: false send both keys as false" do
      req = Spec.TemplateRequest.new!(name: "n", image: "i", ssh: false, jupyter: false)

      assert %{"startSsh" => false, "startJupyter" => false} =
               Translate.template_request_to_body(req)
    end

    test "ssh: true and jupyter: true send both keys as true" do
      req = Spec.TemplateRequest.new!(name: "n", image: "i", ssh: true, jupyter: true)

      assert %{"startSsh" => true, "startJupyter" => true} =
               Translate.template_request_to_body(req)
    end

    test "omitting ssh and jupyter sends neither key, so RunPod's defaults hold" do
      body = Translate.template_request_to_body(Spec.TemplateRequest.new!(name: "n", image: "i"))
      refute Map.has_key?(body, "startSsh")
      refute Map.has_key?(body, "startJupyter")
    end

    test "serverless: true is sent and false is not" do
      on = Spec.TemplateRequest.new!(name: "n", image: "i", serverless: true)
      off = Spec.TemplateRequest.new!(name: "n", image: "i")
      assert %{"serverless" => true} = Translate.template_request_to_body(on)
      refute Map.has_key?(Translate.template_request_to_body(off), "serverless")
    end

    test "provider_opts merge over the body" do
      req = Spec.TemplateRequest.new!(name: "n", image: "i", provider_opts: %{category: "AMD"})
      assert %{"category" => "AMD"} = Translate.template_request_to_body(req)
    end
  end

  describe "template_to_spec/1" do
    @template %{
      "id" => "9x4m2p7v",
      "name" => "trainer-v7",
      "image" => "ghcr.io/acme/trainer:7",
      "args" => "",
      "cmd" => ["python", "train.py"],
      "disk" => 80,
      "mounts" => %{"persistent" => %{"size" => 100, "path" => "/workspace"}},
      "ports" => ["8000/http", "22/tcp"],
      "env" => %{"WANDB_PROJECT" => "atlas"},
      "serverless" => false,
      "startSsh" => true,
      "startJupyter" => false
    }

    test "normalizes a RunPod template and keeps its body, without env, in raw" do
      assert %Spec.Template{
               id: "9x4m2p7v",
               provider: :runpod,
               name: "trainer-v7",
               image: "ghcr.io/acme/trainer:7",
               ports: [{8000, :http}, {22, :tcp}],
               env: %{"WANDB_PROJECT" => "atlas"},
               container_disk_gb: 80,
               volume_gb: 100,
               command: ["python", "train.py"],
               serverless: false,
               ssh: true,
               jupyter: false,
               raw: raw
             } = Translate.template_to_spec(@template)

      assert raw == Map.delete(@template, "env")
    end

    test "raw keeps a template body that has no env whole" do
      body = Map.delete(@template, "env")
      assert %Spec.Template{raw: ^body, env: %{}} = Translate.template_to_spec(body)
    end

    test "a sparse body reads as absent fields" do
      assert %Spec.Template{
               id: "a",
               ports: [],
               env: %{},
               container_disk_gb: nil,
               volume_gb: nil,
               command: nil,
               serverless: false,
               ssh: nil,
               jupyter: nil
             } = Translate.template_to_spec(%{"id" => "a"})
    end

    test "fields of the wrong type read as absent and a bad port string is skipped" do
      raw = %{
        "id" => "a",
        "ports" => ["8000/http", "junk", 7],
        "env" => "x",
        "mounts" => [],
        "cmd" => "run",
        "disk" => "big"
      }

      assert %Spec.Template{
               ports: [{8000, :http}],
               env: %{},
               volume_gb: nil,
               command: nil,
               container_disk_gb: nil
             } = Translate.template_to_spec(raw)
    end
  end

  describe "endpoint_to_spec/1" do
    @endpoint %{
      "id" => "4m7x2k9q",
      "name" => "image-generator",
      "type" => "QUEUE",
      "image" => "ghcr.io/acme/gen:3",
      "env" => %{"HF_TOKEN" => "s3cr3t-value"},
      "gpu" => %{"pools" => ["ADA_24", "AMPERE_48"], "count" => 1},
      "workers" => %{"min" => 0, "max" => 3},
      "dataCenterIds" => ["US-TX-3"],
      "networkVolumes" => ["vol_abc"],
      "createdAt" => "2026-03-13T20:00:00Z"
    }

    test "normalizes a RunPod endpoint and keeps its body, without env, in raw" do
      assert %Spec.Endpoint{
               id: "4m7x2k9q",
               provider: :runpod,
               name: "image-generator",
               type: :queue,
               workers_min: 0,
               workers_max: 3,
               gpu_pools: ["ADA_24", "AMPERE_48"],
               region_hints: ["US-TX-3"],
               network_volume_ids: ["vol_abc"],
               created_at: ~U[2026-03-13 20:00:00Z],
               raw: raw
             } = Translate.endpoint_to_spec(@endpoint)

      assert raw == Map.delete(@endpoint, "env")
    end

    test "raw drops the env of the template nested in an endpoint, and keeps its other keys" do
      body =
        Map.put(@endpoint, "template", %{"id" => "t", "env" => %{"K" => "v"}, "image" => "i"})

      assert %Spec.Endpoint{raw: raw} = Translate.endpoint_to_spec(body)
      assert raw["template"] == %{"id" => "t", "image" => "i"}
      refute Map.has_key?(raw, "env")
    end

    test "raw keeps an endpoint body that has no env whole" do
      body = %{"id" => "a", "template" => %{"id" => "t"}, "workers" => %{"min" => 1}}
      assert %Spec.Endpoint{raw: ^body} = Translate.endpoint_to_spec(body)
    end

    test "a template that is not an object stays as RunPod sent it" do
      body = %{"id" => "a", "template" => "t1", "env" => %{"K" => "v"}}
      assert %Spec.Endpoint{raw: %{"template" => "t1"} = raw} = Translate.endpoint_to_spec(body)
      refute Map.has_key?(raw, "env")
    end

    test "LOAD_BALANCER maps to :load_balancer, an unknown type to :unknown, an absent one to nil" do
      assert %{type: :load_balancer} =
               Translate.endpoint_to_spec(%{"id" => "a", "type" => "LOAD_BALANCER"})

      assert %{type: :unknown} = Translate.endpoint_to_spec(%{"id" => "a", "type" => "STREAM"})
      assert %{type: nil} = Translate.endpoint_to_spec(%{"id" => "a"})
      assert %{type: nil} = Translate.endpoint_to_spec(%{"id" => "a", "type" => 7})
    end

    test "a sparse body reads as absent fields" do
      assert %Spec.Endpoint{
               id: "a",
               name: nil,
               workers_min: nil,
               workers_max: nil,
               gpu_pools: [],
               region_hints: [],
               network_volume_ids: [],
               created_at: nil
             } = Translate.endpoint_to_spec(%{"id" => "a"})
    end

    test "a CPU endpoint has no gpu and no pools" do
      raw = %{"id" => "a", "gpu" => nil, "cpu" => [%{"memory" => 16}]}
      assert %{gpu_pools: []} = Translate.endpoint_to_spec(raw)
    end

    test "fields of the wrong type read as absent" do
      raw = %{
        "id" => "a",
        "name" => 5,
        "workers" => %{"min" => -1, "max" => 2.5},
        "gpu" => %{"pools" => "ADA_24"},
        "dataCenterIds" => "US-TX-3",
        "networkVolumes" => [1, "vol_abc"],
        "createdAt" => "yesterday"
      }

      assert %Spec.Endpoint{
               name: nil,
               workers_min: nil,
               workers_max: nil,
               gpu_pools: [],
               region_hints: [],
               network_volume_ids: ["vol_abc"],
               created_at: nil
             } = Translate.endpoint_to_spec(raw)
    end
  end

  describe "pod_billing_to_spend/2" do
    defp billing_body(overrides \\ %{}) do
      Map.merge(
        %{
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
        },
        overrides
      )
    end

    test "reads metadata.totals as floats and metadata.query as the window" do
      assert {:ok,
              %Spec.Spend{
                compute_id: "pod_9",
                provider: :runpod,
                total_usd: 12.34,
                gpu_usd: 11.1,
                cpu_usd: +0.0,
                disk_usd: 1.24,
                from: ~U[2026-09-01 00:00:00Z],
                to: ~U[2026-10-02 00:00:00Z],
                raw: %{"records" => [_]}
              }} = Translate.pod_billing_to_spend(billing_body(), "pod_9")
    end

    test "totals come from metadata, not from a sum of the records" do
      body = put_in(billing_body(), ["metadata", "totals", "totalAmount"], 99.5)

      assert {:ok, %Spec.Spend{total_usd: 99.5}} = Translate.pod_billing_to_spend(body, "pod_9")
    end

    test "a pod with no records and zero totals is 0.0 dollars" do
      zero = %{"totalAmount" => 0, "gpuAmount" => 0, "cpuAmount" => 0, "diskAmount" => 0}

      body =
        billing_body(%{"records" => []})
        |> put_in(["metadata", "totals"], zero)

      assert {:ok, %Spec.Spend{total_usd: +0.0, gpu_usd: +0.0, cpu_usd: +0.0, disk_usd: +0.0}} =
               Translate.pod_billing_to_spend(body, "pod_9")
    end

    test "a body with no numeric metadata.totals is an error" do
      for body <- [
            %{},
            %{"records" => []},
            %{"metadata" => %{}},
            %{"metadata" => %{"totals" => %{}}},
            billing_body() |> put_in(["metadata", "totals", "totalAmount"], "12.34"),
            billing_body() |> put_in(["metadata", "totals", "diskAmount"], nil),
            nil,
            []
          ] do
        assert :error = Translate.pod_billing_to_spend(body, "pod_9")
      end
    end

    test "a missing or unparsable window reads as nil and keeps the totals" do
      for query <- [nil, "junk", [], %{}, %{"startTime" => "yesterday", "endTime" => 5}] do
        body = put_in(billing_body(), ["metadata", "query"], query)

        assert {:ok, %Spec.Spend{from: nil, to: nil, total_usd: 12.34}} =
                 Translate.pod_billing_to_spend(body, "pod_9")
      end
    end
  end

  describe "s3 staging" do
    @s3 %{
      endpoint: "https://t3.storage.dev",
      region: "auto",
      access_key_id: "tid-test-4b1e",
      secret_access_key: "tsec-test-9f2c",
      dataset_uri: "s3://bucket/datasets/abc/",
      artifact_uri: "s3://bucket/artifacts/run-123/"
    }

    defp pod_env(opts) do
      req = Spec.ComputeRequest.new!([gpu: :h100, image: "x"] ++ opts)
      {body, _auth} = Translate.compute_request_to_pod_create(req)
      body["env"]
    end

    test "a session token adds AWS_SESSION_TOKEN" do
      env = pod_env(s3: Map.put(@s3, :session_token, "tses-test-0d7a"))
      assert env["AWS_SESSION_TOKEN"] == "tses-test-0d7a"
      assert env["AWS_ACCESS_KEY_ID"] == "tid-test-4b1e"
    end

    test "only a dataset URI sets ATLAS_DATASET_URI and no AWS_* variable" do
      env = pod_env(s3: %{dataset_uri: "s3://bucket/d/"})

      assert env == %{"ATLAS_DATASET_URI" => "s3://bucket/d/"}
    end

    test "an unrelated env: variable stays beside the staging variables" do
      env = pod_env(env: %{"WANDB_PROJECT" => "x"}, s3: @s3)

      assert env["WANDB_PROJECT"] == "x"
      assert env["AWS_SECRET_ACCESS_KEY"] == "tsec-test-9f2c"
      assert env["ATLAS_ARTIFACT_URI"] == "s3://bucket/artifacts/run-123/"
    end

    test "two presigned URLs POST ATLAS_DATASET_URL and ATLAS_ARTIFACT_URL and no AWS_* key" do
      get_url = "https://bucket.s3.amazonaws.com/d.tar.gz?X-Amz-Signature=getsig-5d0c91"
      put_url = "https://bucket.s3.amazonaws.com/a.tar.gz?X-Amz-Signature=putsig-a7e3b2"

      env = pod_env(s3: %{dataset_url: get_url, artifact_url: put_url})

      assert env == %{"ATLAS_DATASET_URL" => get_url, "ATLAS_ARTIFACT_URL" => put_url}
    end
  end
end
