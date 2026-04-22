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
