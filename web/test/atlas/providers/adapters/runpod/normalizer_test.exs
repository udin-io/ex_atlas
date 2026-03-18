defmodule Atlas.Providers.Adapters.RunPod.NormalizerTest do
  use ExUnit.Case, async: true

  alias Atlas.Providers.Adapters.RunPod.Normalizer

  describe "normalize_pod_as_app/2" do
    test "normalizes a running pod" do
      pod = %{
        "id" => "pod123",
        "name" => "my-gpu-pod",
        "desiredStatus" => "RUNNING",
        "costPerHr" => 0.44,
        "gpuCount" => 1,
        "podType" => "GPU",
        "imageName" => "runpod/pytorch:latest"
      }

      result = Normalizer.normalize_pod_as_app(pod, nil)

      assert result.provider_id == "pod123"
      assert result.name == "my-gpu-pod"
      assert result.status == :deployed
      assert result.provider_type == :runpod
      assert result.metadata["cost_per_hr"] == 0.44
    end

    test "handles EXITED status as suspended" do
      pod = %{"id" => "x", "desiredStatus" => "EXITED"}
      result = Normalizer.normalize_pod_as_app(pod, nil)
      assert result.status == :suspended
    end

    test "handles TERMINATED status as destroyed" do
      pod = %{"id" => "x", "desiredStatus" => "TERMINATED"}
      result = Normalizer.normalize_pod_as_app(pod, nil)
      assert result.status == :destroyed
    end

    test "falls back to id for name when name is nil" do
      pod = %{"id" => "pod456", "name" => nil, "desiredStatus" => "RUNNING"}
      result = Normalizer.normalize_pod_as_app(pod, nil)
      assert result.name == "pod456"
    end
  end

  describe "normalize_pod_as_machine/2" do
    test "normalizes pod as machine with GPU info" do
      pod = %{
        "id" => "pod123",
        "name" => "my-machine",
        "desiredStatus" => "RUNNING",
        "vcpuCount" => 8,
        "memoryInGb" => 32,
        "imageName" => "runpod/pytorch:2.0",
        "gpu" => %{
          "displayName" => "RTX 4090"
        },
        "runtime" => %{
          "ports" => [
            %{"ip" => "100.64.0.1", "privatePort" => 22}
          ]
        }
      }

      result = Normalizer.normalize_pod_as_machine(pod, nil)

      assert result.provider_id == "pod123"
      assert result.name == "my-machine"
      assert result.status == :started
      assert result.cpus == 8
      assert result.memory_mb == 32768
      assert result.gpu_type == "RTX 4090"
      assert result.image == "runpod/pytorch:2.0"
      assert "100.64.0.1" in result.ip_addresses
    end

    test "handles missing runtime/ports gracefully" do
      pod = %{"id" => "x", "desiredStatus" => "CREATED"}
      result = Normalizer.normalize_pod_as_machine(pod, nil)
      assert result.ip_addresses == []
      assert result.status == :created
    end
  end

  describe "normalize_network_volume/2" do
    test "normalizes a network volume" do
      volume = %{
        "id" => "vol_abc",
        "name" => "shared-data",
        "size" => 100,
        "dataCenterId" => "US-TX-3"
      }

      result = Normalizer.normalize_network_volume(volume, nil)

      assert result.provider_id == "vol_abc"
      assert result.name == "shared-data"
      assert result.size_bytes == 100 * 1_073_741_824
      assert result.region == "US-TX-3"
    end
  end
end
