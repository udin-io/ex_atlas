defmodule ExAtlas.Providers.RunPod.TranslateTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Callback
  alias ExAtlas.Providers.RunPod.Translate
  alias ExAtlas.Spec

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
      assert log =~ "Authorization: Bearer pod-scoped-key"
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

    # Run a generated `dockerStartCmd` for real, with a `curl` shim ahead of
    # everything else on PATH so the self-termination request is recorded
    # rather than sent. Returns `{exit_status, curl_log}`.
    defp run_start_cmd(cmd, tmp, extra_env \\ [])

    defp run_start_cmd(["sh", "-c", script], tmp, extra_env) do
      shim = Path.join(tmp, "curl")
      log = Path.join(tmp, "curl.log")
      File.write!(shim, "#!/bin/sh\necho \"$@\" >> #{log}\n")
      File.chmod!(shim, 0o755)

      {_out, status} =
        System.cmd("sh", ["-c", script],
          stderr_to_stdout: true,
          env:
            [
              {"PATH", tmp <> ":" <> System.get_env("PATH", "/usr/bin:/bin")},
              {"RUNPOD_POD_ID", "pod_abc"},
              {"RUNPOD_API_KEY", "pod-scoped-key"}
            ] ++ extra_env
        )

      {status, File.read!(log)}
    end

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

    defp callback_env(tmp) do
      [
        {"ATLAS_CALLBACK_URL", "https://app.example.com/atlas/cb"},
        {"ATLAS_CALLBACK_TOKEN", "a-token"},
        {"ATLAS_TASK_ID", "a-task"},
        {"CURL_LOG", Path.join(tmp, "curl.log")}
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

      assert {0, log} = run_start_cmd(body["cmd"], tmp, callback_env(tmp))

      assert log =~ ~s({"exit_code":0})
      assert log =~ "https://app.example.com/atlas/cb/finish"
      assert log =~ "-X DELETE"

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

      assert {3, log} = run_start_cmd(body["cmd"], tmp, callback_env(tmp))
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

      assert {0, log} = run_start_cmd(body["cmd"], tmp, callback_env(tmp))
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

      assert {0, log} = run_start_cmd(body["cmd"], tmp, callback_env(tmp))
      assert log =~ "-X DELETE"
    end

    # A curl shim that logs and then fails, the way an unreachable host looks.
    defp failing_curl(tmp) do
      shim = Path.join(tmp, "curl")
      log = Path.join(tmp, "curl.log")
      File.write!(shim, "#!/bin/sh\necho \"$@\" >> #{log}\nexit 7\n")
      File.chmod!(shim, 0o755)
    end
  end

  describe "network_volume_request_to_body/1" do
    test "sends name, size and dataCenter, and no type when tier is unset" do
      req =
        Spec.NetworkVolumeRequest.new!(name: "datasets", size_gb: 200, region: "EU-RO-1")

      assert Translate.network_volume_request_to_body(req) ==
               %{"name" => "datasets", "size" => 200, "dataCenter" => "EU-RO-1"}
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
end
