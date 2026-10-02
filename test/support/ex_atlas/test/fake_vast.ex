defmodule ExAtlas.Test.FakeVast do
  @moduledoc false
  # Vast.ai API bodies for Bypass, shaped by Vast's OpenAPI reference
  # (`https://docs.vast.ai/api-reference/openapi.yaml`) and by what
  # `vast-cli`'s `vast.py` reads, and a stateful fake server for
  # `ExAtlas.Test.ProviderConformance`. Where the two disagree, the fake
  # follows vast-cli: `ports` is Docker's map, `extra_env` a list of pairs.

  defdelegate json(conn, status, body), to: ExAtlas.Test.FakeLambda
  defdelegate read_json(conn), to: ExAtlas.Test.FakeLambda

  @doc "An on-demand offer from `POST /api/v0/bundles/`, with the fields ExAtlas reads."
  def offer(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => 50_751_794,
        "ask_contract_id" => 50_751_794,
        "machine_id" => 41_234,
        "gpu_name" => "RTX 4090",
        "gpu_ram" => 24_564,
        "num_gpus" => 1,
        "dph_total" => 0.42,
        "geolocation" => "Texas, US",
        "direct_port_count" => 98,
        "disk_space" => 1842.3,
        "verified" => true,
        "rentable" => true,
        "rented" => false
      },
      attrs
    )
  end

  @doc "A Vast instance as `GET /api/v0/instances/{id}/` returns it."
  def instance(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => 28_411_907,
        "actual_status" => "running",
        "intended_status" => "running",
        "cur_state" => "running",
        "label" => "atlas-test",
        "image_uuid" => "vllm/vllm-openai:latest",
        "image_runtype" => "args",
        "extra_env" => [
          ["HF_TOKEN", "hf-instance-secret"],
          ["ATLAS_PORTS", "8000/http,22/tcp"],
          ["-p 8000:8000", "1"],
          ["-p 22:22", "1"]
        ],
        "onstart" => "export HF_TOKEN=hf-instance-secret",
        "jupyter_token" => "53fc448d6644aa7535c6fa5498cdbedc",
        "public_ipaddr" => "203.0.113.7\n",
        "ports" => %{
          "8000/tcp" => [%{"HostIp" => "0.0.0.0", "HostPort" => "41234"}],
          "22/tcp" => [%{"HostIp" => "0.0.0.0", "HostPort" => "41022"}]
        },
        "gpu_name" => "RTX 4090",
        "num_gpus" => 1,
        "dph_total" => 0.42,
        "geolocation" => "Texas, US",
        "start_date" => 1_790_000_000.5,
        "machine_id" => 41_234
      },
      attrs
    )
  end

  @doc "A refused rent, as Vast's reference documents it."
  def refused(code, msg), do: %{"success" => false, "error" => code, "msg" => msg}
end
