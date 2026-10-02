defmodule ExAtlas.Test.FakeLambda do
  @moduledoc false
  # Lambda Cloud API v1 bodies for Bypass, shaped by its OpenAPI spec 1.10.0
  # (`https://cloud.lambda.ai/api/v1/openapi.json`), and a stateful fake
  # server for `ExAtlas.Test.ProviderConformance`.

  @doc "A `GET /instance-types` entry."
  def type_entry(name, cents, gpus, gpu_description, regions) do
    %{
      "instance_type" => %{
        "name" => name,
        "description" => "#{gpus}x #{gpu_description}",
        "gpu_description" => gpu_description,
        "price_cents_per_hour" => cents,
        "specs" => %{"vcpus" => 26, "memory_gib" => 200, "storage_gib" => 1024, "gpus" => gpus},
        "architecture" => "x86_64"
      },
      "regions_with_capacity_available" =>
        Enum.map(regions, &%{"name" => &1, "description" => "Region #{&1}"})
    }
  end

  @doc "The `data` of `GET /instance-types`."
  def instance_types do
    %{
      "gpu_1x_h100_pcie" =>
        type_entry("gpu_1x_h100_pcie", 249, 1, "H100 (80 GB PCIe)", ["us-west-1", "us-east-1"]),
      "gpu_8x_h100_sxm5" =>
        type_entry("gpu_8x_h100_sxm5", 2392, 8, "H100 (80 GB SXM5)", ["us-east-1"]),
      "gpu_1x_h100_sxm5" => type_entry("gpu_1x_h100_sxm5", 329, 1, "H100 (80 GB SXM5)", []),
      "gpu_1x_a10" => type_entry("gpu_1x_a10", 75, 1, "A10 (24 GB PCIe)", ["us-west-1"])
    }
  end

  @doc "A Lambda `Instance`, with every field the spec marks required."
  def instance(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "0920582c7ff041399e34823a0be62549",
        "name" => "atlas-test",
        "ip" => "198.51.100.2",
        "private_ip" => "10.0.2.100",
        "status" => "active",
        "ssh_key_names" => ["deploy"],
        "file_system_names" => [],
        "region" => %{"name" => "us-east-1", "description" => "Virginia, USA"},
        "instance_type" =>
          type_entry("gpu_1x_h100_pcie", 249, 1, "H100 (80 GB PCIe)", [])["instance_type"],
        "hostname" => "198-51-100-2",
        "jupyter_token" => "jt-0b7d30d9d3e4d8fa41657bc0d478c1b",
        "jupyter_url" =>
          "https://jupyter-x.lambdaspaces.com/?token=jt-0b7d30d9d3e4d8fa41657bc0d478c1b",
        "first_healthy" => nil,
        "actions" => %{},
        "tags" => [
          %{"key" => "atlas-ports", "value" => "8000/http,22/tcp"},
          %{"key" => "atlas-created-at", "value" => "2026-10-02T09:30:00Z"},
          %{"key" => "atlas-image", "value" => "vllm/vllm-openai:latest"}
        ]
      },
      attrs
    )
  end

  @doc "A Lambda `FirewallRuleset`, with every field the spec marks required."
  def ruleset(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "rs-0001",
        "name" => "atlas-test",
        "region" => %{"name" => "us-east-1", "description" => "Virginia, USA"},
        "rules" => [],
        "created" => "2026-10-02T09:30:00Z",
        "instance_ids" => []
      },
      attrs
    )
  end

  @doc "Lambda's refusal to delete a ruleset an instance still uses."
  def ruleset_in_use do
    %{
      "error" => %{
        "code" => "firewall-rulesets/firewall-ruleset-in-use",
        "message" => "Firewall ruleset is in use by one or more instances.",
        "suggestion" => "Terminate all instances that are using the ruleset before deleting it."
      }
    }
  end

  def json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  def read_json(conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn, length: 2_000_000)
    {Jason.decode!(raw), conn}
  end

  @doc """
  Start a fake Lambda on Bypass that keeps launched instances in an Agent.
  Returns the opts every conformance call needs.
  """
  def start do
    bypass = Bypass.open()
    {:ok, store} = Agent.start_link(fn -> %{} end)
    {:ok, rulesets} = Agent.start_link(fn -> %{} end)

    Bypass.stub(bypass, "GET", "/instance-types", &json(&1, 200, %{"data" => instance_types()}))

    Bypass.stub(bypass, "POST", "/instance-operations/launch", fn conn ->
      {body, conn} = read_json(conn)
      id = "inst#{System.unique_integer([:positive])}"
      attached = Enum.map(body["firewall_rulesets"] || [], & &1["id"])
      known = Agent.get(rulesets, &Map.keys/1)

      case attached -- known do
        [] ->
          launched =
            instance(%{
              "id" => id,
              "name" => body["name"],
              "status" => "booting",
              "tags" => body["tags"] || [],
              "firewall_ruleset_ids" => attached
            })

          Agent.update(store, &Map.put(&1, id, launched))
          json(conn, 200, %{"data" => %{"instance_ids" => [id]}})

        _missing ->
          json(conn, 404, not_found())
      end
    end)

    Bypass.stub(bypass, "GET", "/instances/:id", fn conn ->
      case Agent.get(store, &Map.get(&1, List.last(conn.path_info))) do
        nil -> json(conn, 404, not_found())
        found -> json(conn, 200, %{"data" => found})
      end
    end)

    Bypass.stub(bypass, "GET", "/instances", fn conn ->
      json(conn, 200, %{"data" => Agent.get(store, &Map.values/1), "page_token" => nil})
    end)

    Bypass.stub(bypass, "POST", "/instance-operations/terminate", fn conn ->
      {%{"instance_ids" => ids}, conn} = read_json(conn)
      Agent.update(store, &Map.drop(&1, ids))
      json(conn, 200, %{"data" => %{"terminated_instances" => []}})
    end)

    Bypass.stub(bypass, "POST", "/firewall-rulesets", fn conn ->
      {body, conn} = read_json(conn)
      id = "rs#{System.unique_integer([:positive])}"

      created =
        ruleset(%{
          "id" => id,
          "name" => body["name"],
          "region" => %{"name" => body["region"], "description" => body["region"]},
          "rules" => body["rules"],
          "created" => DateTime.to_iso8601(DateTime.utc_now())
        })

      Agent.update(rulesets, &Map.put(&1, id, created))
      json(conn, 200, %{"data" => created})
    end)

    Bypass.stub(bypass, "GET", "/firewall-rulesets", fn conn ->
      listed =
        rulesets
        |> Agent.get(&Map.values/1)
        |> Enum.map(&Map.put(&1, "instance_ids", instances_using(store, &1["id"])))

      json(conn, 200, %{"data" => listed})
    end)

    Bypass.stub(bypass, "DELETE", "/firewall-rulesets/:id", fn conn ->
      id = List.last(conn.path_info)

      cond do
        not Agent.get(rulesets, &Map.has_key?(&1, id)) -> json(conn, 404, not_found())
        instances_using(store, id) != [] -> json(conn, 400, ruleset_in_use())
        true -> Agent.update(rulesets, &Map.delete(&1, id)) && json(conn, 200, %{"data" => %{}})
      end
    end)

    [
      base_url: "http://localhost:#{bypass.port}",
      api_key: "lambda-test-key",
      provider_opts: %{ssh_key_name: "deploy"}
    ]
  end

  defp instances_using(store, ruleset_id) do
    store
    |> Agent.get(&Map.values/1)
    |> Enum.filter(&(ruleset_id in Map.get(&1, "firewall_ruleset_ids", [])))
    |> Enum.map(& &1["id"])
  end

  @doc "The rulesets the fake server holds, read through its API like a caller would."
  def rulesets(opts) do
    %{status: 200, body: %{"data" => data}} =
      Req.get!(opts[:base_url] <> "/firewall-rulesets", auth: {:bearer, opts[:api_key]})

    data
  end

  def not_found do
    %{
      "error" => %{
        "code" => "global/object-does-not-exist",
        "message" => "Specified instance does not exist."
      }
    }
  end
end
