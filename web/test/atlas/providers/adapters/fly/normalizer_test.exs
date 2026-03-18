defmodule Atlas.Providers.Adapters.Fly.NormalizerTest do
  use ExUnit.Case, async: true

  alias Atlas.Providers.Adapters.Fly.Normalizer

  describe "normalize_app/2" do
    test "normalizes a Fly app response" do
      app_data = %{
        "id" => "abc123",
        "name" => "my-app",
        "status" => "deployed",
        "machine_count" => 3,
        "network" => "default"
      }

      result = Normalizer.normalize_app(app_data, nil)

      assert result.provider_id == "abc123"
      assert result.name == "my-app"
      assert result.status == :deployed
      assert result.provider_type == :fly
      assert result.metadata["machine_count"] == 3
    end

    test "handles suspended status" do
      result =
        Normalizer.normalize_app(%{"id" => "x", "name" => "y", "status" => "suspended"}, nil)

      assert result.status == :suspended
    end

    test "defaults unknown status to pending" do
      result = Normalizer.normalize_app(%{"id" => "x", "name" => "y", "status" => "unknown"}, nil)
      assert result.status == :pending
    end
  end

  describe "normalize_machine/2" do
    test "normalizes a Fly machine response" do
      machine_data = %{
        "id" => "machine123",
        "name" => "my-machine",
        "state" => "started",
        "region" => "iad",
        "private_ip" => "fdaa::1",
        "config" => %{
          "guest" => %{
            "cpu_kind" => "shared",
            "cpus" => 2,
            "memory_mb" => 512
          }
        },
        "image_ref" => %{
          "repository" => "registry.fly.io/my-app",
          "tag" => "latest"
        }
      }

      result = Normalizer.normalize_machine(machine_data, nil)

      assert result.provider_id == "machine123"
      assert result.name == "my-machine"
      assert result.status == :started
      assert result.region == "iad"
      assert result.ip_addresses == ["fdaa::1"]
      assert result.cpu_kind == "shared"
      assert result.cpus == 2
      assert result.memory_mb == 512
      assert result.image == "registry.fly.io/my-app:latest"
    end

    test "handles missing config gracefully" do
      result = Normalizer.normalize_machine(%{"id" => "x", "state" => "stopped"}, nil)

      assert result.provider_id == "x"
      assert result.status == :stopped
      assert result.cpu_kind == nil
      assert result.ip_addresses == []
    end

    test "maps destroyed state" do
      result = Normalizer.normalize_machine(%{"id" => "x", "state" => "destroyed"}, nil)
      assert result.status == :destroyed
    end
  end

  describe "normalize_volume/2" do
    test "normalizes a Fly volume response" do
      volume_data = %{
        "id" => "vol_abc123",
        "name" => "data",
        "size_gb" => 10,
        "region" => "iad",
        "state" => "created"
      }

      result = Normalizer.normalize_volume(volume_data, nil)

      assert result.provider_id == "vol_abc123"
      assert result.name == "data"
      assert result.size_gb == 10
      assert result.region == "iad"
      assert result.status == "created"
    end
  end
end
