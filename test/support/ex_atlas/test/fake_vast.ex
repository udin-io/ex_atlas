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

  @doc """
  One contract's row from `GET /api/v0/charges/`, as Vast's OpenAPI reference
  shows it. `items` are `{type, amount}` pairs; the row's `amount` defaults to
  their sum.
  """
  def charge_row(id, items, attrs \\ %{}) do
    amount = items |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> Float.round(3)

    Map.merge(
      %{
        "start" => 1_790_000_000,
        "end" => 1_790_086_400,
        "type" => "instance",
        "source" => "instance-#{id}",
        "description" => "Instance #{id} Charges - 1 days",
        "amount" => amount,
        "metadata" => %{"label" => "atlas-test"},
        "items" =>
          for {type, item_amount} <- items do
            %{
              "start" => 1_790_000_000,
              "end" => 1_790_086_400,
              "type" => Atom.to_string(type),
              "source" => nil,
              "description" => "#{type} charge",
              "amount" => item_amount,
              "metadata" => %{},
              "items" => []
            }
          end
      },
      attrs
    )
  end

  @doc "A refused rent, as Vast's reference documents it."
  def refused(code, msg), do: %{"success" => false, "error" => code, "msg" => msg}

  @doc """
  Start a fake Vast on Bypass that keeps rented instances in an Agent.
  Returns the opts every conformance call needs.
  """
  def start do
    bypass = Bypass.open()
    {:ok, store} = Agent.start_link(fn -> %{} end)

    Bypass.stub(bypass, "POST", "/api/v0/bundles", fn conn ->
      {query, conn} = read_json(conn)
      names = get_in(query, ["gpu_name", "in"]) || ["RTX 4090"]
      offers = Enum.map(Enum.with_index(names, 1), fn {name, i} -> offer_for(name, i) end)

      # A bid search lists `dph_total` as the bid plus 0.01 of storage
      # (`dph_base` = `min_bid`), as Vast's free search does.
      offers =
        if query["type"] == "bid",
          do: Enum.map(offers, &Map.merge(&1, %{"min_bid" => 0.2, "dph_total" => 0.21})),
          else: offers

      json(conn, 200, %{"offers" => offers})
    end)

    Bypass.stub(bypass, "PUT", "/api/v0/asks/:id", fn conn ->
      {body, conn} = read_json(conn)
      id = System.unique_integer([:positive])

      rented =
        instance(%{
          "id" => id,
          "actual_status" => nil,
          "label" => body["label"],
          "image_uuid" => body["image"],
          "extra_env" => Enum.map(body["env"] || %{}, fn {k, v} -> [k, v] end),
          "ports" => %{}
        })
        |> bid_fields(body["price"])

      Agent.update(store, &Map.put(&1, Integer.to_string(id), rented))
      json(conn, 200, %{"success" => true, "new_contract" => id})
    end)

    # Not Vast's API: the test-side switch for an outbid instance, which Vast
    # reads `exited` (docs.vast.ai, instance `actual_status`).
    Bypass.stub(bypass, "POST", "/fake/outbid/:id", fn conn ->
      id = List.last(conn.path_info)
      Agent.update(store, &update_in(&1[id], fn i -> Map.put(i, "actual_status", "exited") end))
      json(conn, 200, %{"success" => true})
    end)

    # Not Vast's API: sets what the charges route bills an instance.
    Bypass.stub(bypass, "POST", "/fake/bill/:id", fn conn ->
      id = List.last(conn.path_info)
      {%{"usd" => usd}, conn} = read_json(conn)
      Agent.update(store, &update_in(&1[id], fn i -> Map.put(i, "fake_bill_usd", usd) end))
      json(conn, 200, %{"success" => true})
    end)

    # The account's contract rows: one per instance with a bill set, all GPU.
    Bypass.stub(bypass, "GET", "/api/v0/charges", fn conn ->
      rows =
        for %{"id" => id, "fake_bill_usd" => usd} <- Agent.get(store, &Map.values/1),
            do: charge_row(id, gpu: usd)

      json(conn, 200, %{"success" => true, "results" => rows, "next_token" => nil})
    end)

    Bypass.stub(bypass, "GET", "/api/v0/instances/:id", fn conn ->
      json(conn, 200, %{"instances" => Agent.get(store, &Map.get(&1, List.last(conn.path_info)))})
    end)

    Bypass.stub(bypass, "GET", "/api/v1/instances", fn conn ->
      json(conn, 200, %{"instances" => Agent.get(store, &Map.values/1), "next_token" => nil})
    end)

    # `PUT {"state": "stopped" | "running"}`: a stopped instance reads
    # `exited`, as Vast's docs say.
    Bypass.stub(bypass, "PUT", "/api/v0/instances/:id", fn conn ->
      id = List.last(conn.path_info)
      {body, conn} = read_json(conn)

      status =
        case body["state"] do
          "stopped" -> "exited"
          "running" -> "running"
        end

      if Agent.get(store, &Map.has_key?(&1, id)) do
        Agent.update(store, &put_in(&1[id]["actual_status"], status))
        json(conn, 200, %{"success" => true})
      else
        json(conn, 404, refused("not_found", "Instance not found"))
      end
    end)

    Bypass.stub(bypass, "DELETE", "/api/v0/instances/:id", fn conn ->
      id = List.last(conn.path_info)

      if Agent.get(store, &Map.has_key?(&1, id)) do
        Agent.update(store, &Map.delete(&1, id))
        json(conn, 200, %{"success" => true})
      else
        json(conn, 404, refused("not_found", "Instance not found"))
      end
    end)

    [base_url: "http://localhost:#{bypass.port}", api_key: "vast-test-key"]
  end

  # ASSUMPTION, unverified until the :vast_live spot test prints the real
  # values: a bid instance reads `is_bid` and bills its bid plus 0.01 of
  # storage, as its offer listed.
  defp bid_fields(instance, nil), do: instance

  defp bid_fields(instance, price),
    do:
      Map.merge(instance, %{
        "is_bid" => true,
        "dph_total" => Float.round(price + 0.01, 4),
        "min_bid" => price
      })

  @doc "Make `vast`'s charges route bill instance `id` `usd` dollars of GPU time."
  def bill(vast, id, usd) do
    {:ok, %{status: 200}} =
      Req.post("#{vast[:base_url]}/fake/bill/#{id}", json: %{"usd" => usd}, retry: false)

    :ok
  end

  @doc "Outbid a rented instance of `start/0`'s fake: it reads `exited` from now on."
  def outbid(vast, id) do
    {:ok, %{status: 200}} = Req.post("#{vast[:base_url]}/fake/outbid/#{id}", retry: false)
    :ok
  end

  defp offer_for(name, i), do: offer(%{"id" => 1000 + i, "gpu_name" => name})
end
