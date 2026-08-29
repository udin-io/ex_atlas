defmodule ExAtlas.Providers.RunPod.TranslateTest do
  use ExUnit.Case, async: true

  alias ExAtlas.Providers.RunPod.Translate
  alias ExAtlas.Spec

  describe "compute_request_to_pod_create/1" do
    test "maps canonical GPU to RunPod id" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _auth} = Translate.compute_request_to_pod_create(req)
      assert body["gpuTypeIds"] == ["NVIDIA H100 80GB HBM3"]
      assert body["computeType"] == "GPU"
      assert body["cloudType"] == "ALL"
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
      assert body["cloudType"] == "SECURE"
    end

    test "no :command leaves dockerStartCmd unset so the image's own CMD runs" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _} = Translate.compute_request_to_pod_create(req)
      refute Map.has_key?(body, "dockerStartCmd")
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
      assert body["dockerStartCmd"] == ["/app/train.sh", "--epochs", "3"]
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

      assert {0, log} = run_start_cmd(body["dockerStartCmd"], tmp)

      assert File.read!(Path.join(tmp, "ran")) == "ran\n"
      assert log =~ "-X DELETE"
      assert log =~ "https://rest.runpod.io/v1/pods/pod_abc"
      assert log =~ "Authorization: Bearer pod-scoped-key"
    end

    @tag :tmp_dir
    test "the pod is deleted even when the command exits non-zero", %{tmp_dir: tmp} do
      # A crashed trainer that left the pod up would bill until the
      # `:max_runtime_ms` backstop fired, which is the trap this exists to
      # close. `trap ... EXIT` fires on any shell exit, not just a clean one.
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", command: ["sh", "-c", "exit 3"])
      {body, _} = Translate.compute_request_to_pod_create(req)

      assert {3, log} = run_start_cmd(body["dockerStartCmd"], tmp)
      assert log =~ "https://rest.runpod.io/v1/pods/pod_abc"
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

      assert {0, _log} = run_start_cmd(body["dockerStartCmd"], tmp)
      assert File.read!(Path.join(tmp, "arg")) == "it's a $PATH; rm -rf /"
    end

    # Run a generated `dockerStartCmd` for real, with a `curl` shim ahead of
    # everything else on PATH so the self-termination request is recorded
    # rather than sent. Returns `{exit_status, curl_log}`.
    defp run_start_cmd(["sh", "-c", script], tmp) do
      shim = Path.join(tmp, "curl")
      log = Path.join(tmp, "curl.log")
      File.write!(shim, "#!/bin/sh\necho \"$@\" >> #{log}\n")
      File.chmod!(shim, 0o755)

      {_out, status} =
        System.cmd("sh", ["-c", script],
          stderr_to_stdout: true,
          env: [
            {"PATH", tmp <> ":" <> System.get_env("PATH", "/usr/bin:/bin")},
            {"RUNPOD_POD_ID", "pod_abc"},
            {"RUNPOD_API_KEY", "pod-scoped-key"}
          ]
        )

      {status, File.read!(log)}
    end

    test "mints a bearer token when auth: :bearer" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x", auth: :bearer)
      {body, auth} = Translate.compute_request_to_pod_create(req)
      assert %{scheme: :bearer, token: _, hash: _, header: _} = auth

      key = Enum.find(body["env"], &(&1["key"] == "ATLAS_PRESHARED_KEY"))
      assert key["value"] == auth.token
    end

    test "drops nil fields so RunPod doesn't complain" do
      req = Spec.ComputeRequest.new!(gpu: :h100, image: "x")
      {body, _} = Translate.compute_request_to_pod_create(req)
      refute Map.has_key?(body, "volumeInGb")
      refute Map.has_key?(body, "networkVolumeId")
      refute Map.has_key?(body, "templateId")
    end

    test "raises for GPU atom with no RunPod mapping" do
      req = Spec.ComputeRequest.new!(gpu: :nonexistent_gpu, image: "x")

      assert_raise ArgumentError, ~r/no mapping/, fn ->
        Translate.compute_request_to_pod_create(req)
      end
    end
  end

  describe "pod_to_compute/2" do
    test "maps desiredStatus to normalized status" do
      pod = %{"id" => "abc", "desiredStatus" => "RUNNING", "gpuCount" => 2}
      compute = Translate.pod_to_compute(pod)
      assert compute.id == "abc"
      assert compute.status == :running
      assert compute.gpu_count == 2
    end

    test "threads auth through" do
      auth = %{scheme: :bearer, token: "t", hash: "h", header: "Authorization: Bearer t"}
      compute = Translate.pod_to_compute(%{"id" => "abc", "desiredStatus" => "RUNNING"}, auth)
      assert compute.auth == auth
    end

    test "builds proxy URL from pod id + port string" do
      pod = %{"id" => "pod_42", "desiredStatus" => "RUNNING", "ports" => "8000/http,22/tcp"}
      compute = Translate.pod_to_compute(pod)
      http_port = Enum.find(compute.ports, &(&1.protocol == :http))
      assert http_port.url == "https://pod_42-8000.proxy.runpod.net"
    end

    test "reads created_at from lastStartedAt, the only timestamp REST v1 carries" do
      pod = %{
        "id" => "abc",
        "desiredStatus" => "RUNNING",
        "lastStartedAt" => "2024-07-12T19:14:40.144Z"
      }

      compute = Translate.pod_to_compute(pod)

      assert compute.created_at == ~U[2024-07-12 19:14:40.144Z]
    end

    test "created_at is nil when the pod carries no usable timestamp" do
      # `lastStatusChange` is prose ("Rented by User: Fri Jul 12 2024 …"), not a
      # timestamp, so a pod that only has that one still has no age.
      pod = %{
        "id" => "abc",
        "desiredStatus" => "RUNNING",
        "lastStatusChange" => "Rented by User: Fri Jul 12 2024 15:14:40 GMT-0400"
      }

      assert Translate.pod_to_compute(pod).created_at == nil
      assert Translate.pod_to_compute(%{"id" => "abc"}).created_at == nil
    end

    test "an unparseable lastStartedAt is nil rather than a crash" do
      pod = %{"id" => "abc", "desiredStatus" => "RUNNING", "lastStartedAt" => "not a date"}

      assert Translate.pod_to_compute(pod).created_at == nil
    end

    test "a desiredStatus outside the enum reads as :provisioning, never as dead" do
      # The enum is RUNNING | EXITED | TERMINATED. Anything else is a pod we
      # cannot classify, and `UpstreamStatus` counts :provisioning as alive —
      # the same "uncertainty never tears a resource down" rule the poller runs
      # on.
      assert Translate.pod_to_compute(%{"id" => "abc"}).status == :provisioning

      assert Translate.pod_to_compute(%{"id" => "abc", "desiredStatus" => "FAILED"}).status ==
               :provisioning
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
end
