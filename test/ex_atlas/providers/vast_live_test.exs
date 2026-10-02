defmodule ExAtlas.Providers.VastLiveTest do
  # Runs against Vast's real API. Excluded by default; run with
  #
  #     VAST_API_KEY=... mix test --only vast_live
  #
  # Each test settles one point where Vast's API reference and vast-cli
  # disagree (issue 98), which the Bypass suite cannot: the GPU name spelling
  # the search takes; whether a rent takes `env` as a JSON object; the shape
  # of an instance's `ports` and `extra_env`; what a missing instance and a
  # refused rent answer, and whether the refusal's `msg` echoes the request.
  # Three tests spend money, each renting the cheapest on-demand RTX 4090 for a
  # few minutes: one nginx container, one `command:` container that deletes
  # its own instance (issue 105), and one interruptible (`spot: true`)
  # container (issue 112). The spot test cannot make Vast outbid the
  # instance; it prints what Vast reports for a bid, and the outbid status
  # (`exited`) stays read from Vast's docs.
  use ExUnit.Case, async: false

  @moduletag :vast_live
  @moduletag timeout: 30 * 60_000

  alias ExAtlas.Orchestrator.UpstreamStatus
  alias ExAtlas.Providers.Vast.Client

  @marker "atlas-live-marker-#{System.unique_integer([:positive])}"

  # Every key `Translate.instance_to_compute/1` reads.
  @read_keys ~w(id actual_status public_ipaddr ports gpu_name num_gpus dph_total
                geolocation image_uuid label start_date)

  setup do
    key = System.fetch_env!("VAST_API_KEY")
    opts = [provider: :vast, api_key: key]
    name = "ex-atlas-live-test-#{System.unique_integer([:positive])}"

    # By label, not by id: a spawn that errors after Vast rented never
    # returns an id.
    on_exit(fn -> delete_by_name(name, opts) end)

    {:ok, opts: opts, name: name}
  end

  test "the search takes Vast's spaced GPU names, not vast-cli's underscores", %{opts: opts} do
    ctx = ctx(opts)

    spaced = search_count(ctx, "RTX 4090")
    underscored = search_count(ctx, "RTX_4090")
    IO.puts("\nRTX 4090 offers: #{spaced}; RTX_4090 offers: #{underscored}")

    assert spaced > 0
    assert underscored == 0

    assert {:ok, types} = ExAtlas.list_gpu_types(opts)
    IO.puts("Vast GPU types: #{Enum.map_join(types, ", ", & &1.id)}")
    assert types != []
    assert Enum.all?(types, &(&1.canonical != nil and not String.contains?(&1.id, "_")))
  end

  test "a missing instance reads :not_found", %{opts: opts} do
    assert {:error, %ExAtlas.Error{kind: :not_found}} = ExAtlas.get_compute("1", opts)
  end

  test "a refused rent: what Vast answers, and whether its msg echoes the env", %{opts: opts} do
    body = %{
      "image" => "nginx:alpine",
      "runtype" => "args",
      "disk" => 20,
      "cancel_unavail" => true,
      "env" => %{"ATLAS_LIVE_MARKER" => @marker}
    }

    # Offer 1 does not exist; Vast rents nothing.
    result = Client.put(ctx(opts), "/api/v0/asks/1/", body, retry: false)
    IO.puts("\nrefused rent: #{inspect(result)}")
    IO.puts("msg echoes the env value: #{inspect(result) =~ @marker}")

    assert {:error, %ExAtlas.Error{status: status}} = result
    assert status in 400..499
  end

  test "an nginx container rents, reads running with its env and port, and terminates", %{
    opts: opts,
    name: name
  } do
    {:ok, compute} =
      ExAtlas.spawn_compute(
        [
          gpu: :rtx_4090,
          name: name,
          image: "nginx:alpine",
          ports: [{80, :http}],
          env: %{"ATLAS_LIVE_MARKER" => @marker}
        ] ++ opts
      )

    IO.puts(
      "\nrented #{compute.id}: #{compute.gpu_type} in #{compute.region} at $#{compute.cost_per_hour}/h"
    )

    {:alive, running} = wait_until(compute.id, opts, &match?({:alive, %{status: :running}}, &1))
    assert is_binary(running.public_ip)

    for key <- @read_keys do
      assert Map.has_key?(running.raw, key), "GET /instances/{id} has no #{key}"
    end

    # The docs-against-CLI questions, read from Vast's own body.
    assert {:ok, %{"instances" => instance}} =
             Client.get(ctx(opts), "/api/v0/instances/#{compute.id}/")

    IO.puts("ports: #{inspect(instance["ports"])}")
    IO.puts("extra_env names: #{inspect(Enum.map(instance["extra_env"] || [], &hd/1))}")

    assert [@marker] =
             for([key, value | _] <- instance["extra_env"], key == "ATLAS_LIVE_MARKER", do: value),
           "Vast did not take env as a JSON object"

    assert %{"80/tcp" => [%{"HostPort" => _} | _]} = instance["ports"]

    assert {:ok, [listed]} = ExAtlas.list_compute([name: name] ++ opts)
    assert listed.id == compute.id

    assert [%{internal: 80, url: "http://" <> _ = url}] = running.ports
    assert {:ok, %{status: 200}} = wait_for_http(url)

    assert :ok = ExAtlas.terminate(compute.id, opts)
    assert {:dead, :vanished, nil} = wait_until(compute.id, opts, &match?({:dead, _, _}, &1))
  end

  # What only the real API shows: that Vast puts CONTAINER_ID and
  # CONTAINER_API_KEY into a `runtype: "args"` container, that the instance
  # key may DELETE its own instance, that `args` reach the image's
  # ENTRYPOINT (curlimages/curl's runs `exec "$@"`), and that a fresh rent
  # lists a `start_date`, which keeps the Reaper off a spawn in flight.
  test "a command: container deletes its own instance when the command ends", %{
    opts: opts,
    name: name
  } do
    {:ok, compute} =
      ExAtlas.spawn_compute(
        [
          gpu: :rtx_4090,
          name: name,
          image: "curlimages/curl:latest",
          command: ["sh", "-c", "echo atlas-live-command; sleep 30"]
        ] ++ opts
      )

    IO.puts("\nrented #{compute.id} for a command at $#{compute.cost_per_hour}/h")

    {:alive, first} = wait_until(compute.id, opts, &match?({:alive, _}, &1))
    assert %DateTime{} = first.created_at, "a fresh rent lists no start_date"

    assert {:dead, :vanished, nil} =
             wait_until(compute.id, opts, &match?({:dead, _, _}, &1)),
           "the instance did not delete itself; is CONTAINER_API_KEY set in args mode?"
  end

  # What only the real API shows: that a `type: "bid"` search lists a
  # `min_bid` on its offers, that a rent with `price` = `min_bid` is taken as
  # an interruptible instance (`is_bid`), and what `dph_total` reads on it,
  # which `cost_per_hour` and the cost cap follow after the first poll.
  test "a spot: true rent bids at min_bid and reads is_bid", %{opts: opts, name: name} do
    assert {:ok, types} = ExAtlas.list_gpu_types(opts)
    spot = for %{id: "RTX 4090", spot_price_per_hour: price} <- types, do: price
    IO.puts("\nRTX 4090 spot_price_per_hour: #{inspect(spot)}")
    assert [price] = spot
    assert is_number(price) and price > 0

    # Whether a bid search orders by dph_total the way the pick's order
    # assumes: the printed min_bids should rise.
    {:ok, query} = ExAtlas.Providers.Vast.Translate.gpu_type_query(:rtx_4090, :bid)
    {:ok, %{"offers" => offers}} = Client.post(ctx(opts), "/api/v0/bundles/", query)

    IO.puts(
      "first bid offers' min_bid: #{inspect(offers |> Enum.take(8) |> Enum.map(& &1["min_bid"]))}"
    )

    assert Enum.all?(offers, &is_number(&1["min_bid"])), "a bid offer lists no min_bid"

    {:ok, compute} =
      ExAtlas.spawn_compute(
        [gpu: :rtx_4090, name: name, image: "nginx:alpine", spot: true] ++ opts
      )

    IO.puts("\nrented #{compute.id} as a bid at $#{compute.cost_per_hour}/h")
    assert compute.cost_per_hour > 0

    {:alive, read} = wait_until(compute.id, opts, &match?({:alive, _}, &1))

    assert {:ok, %{"instances" => instance}} =
             Client.get(ctx(opts), "/api/v0/instances/#{compute.id}/")

    IO.puts(
      "actual_status #{inspect(instance["actual_status"])}, intended_status " <>
        "#{inspect(instance["intended_status"])}, is_bid #{inspect(instance["is_bid"])}, " <>
        "min_bid #{inspect(instance["min_bid"])}, dph_total #{inspect(instance["dph_total"])}, " <>
        "read cost_per_hour #{inspect(read.cost_per_hour)}"
    )

    assert instance["is_bid"] == true, "Vast did not take the rent as an interruptible instance"

    assert :ok = ExAtlas.terminate(compute.id, opts)
    assert {:dead, :vanished, nil} = wait_until(compute.id, opts, &match?({:dead, _, _}, &1))
  end

  defp search_count(ctx, name) do
    query = %{
      "gpu_name" => %{"in" => [name]},
      "verified" => %{"eq" => true},
      "rentable" => %{"eq" => true},
      "rented" => %{"eq" => false},
      "type" => "ondemand",
      "limit" => 64
    }

    {:ok, %{"offers" => offers}} = Client.post(ctx, "/api/v0/bundles/", query)
    length(offers)
  end

  defp ctx(opts), do: ExAtlas.Config.build_ctx(:vast, Keyword.delete(opts, :provider))

  defp wait_until(id, opts, done?, deadline \\ System.monotonic_time(:second) + 1200) do
    observation = UpstreamStatus.observe(id, opts)

    cond do
      done?.(observation) ->
        observation

      System.monotonic_time(:second) > deadline ->
        flunk("instance #{id} never got there; last observation #{inspect(observation)}")

      true ->
        Process.sleep(15_000)
        wait_until(id, opts, done?, deadline)
    end
  end

  # nginx answers some seconds after the instance reads running.
  defp wait_for_http(url, tries \\ 40) do
    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %{status: 200}} = ok ->
        ok

      other when tries > 1 ->
        IO.puts("#{url}: #{inspect(other, limit: 3)}")
        Process.sleep(15_000)
        wait_for_http(url, tries - 1)

      other ->
        other
    end
  end

  defp delete_by_name(name, opts, attempts \\ 10)

  defp delete_by_name(name, _opts, 0),
    do: IO.warn("instances labelled #{name} may still be running; destroy them in Vast's console")

  defp delete_by_name(name, opts, attempts) do
    case ExAtlas.list_compute([name: name] ++ opts) do
      {:ok, []} ->
        :ok

      {:ok, live} ->
        Enum.each(live, &ExAtlas.terminate(&1.id, opts))
        Process.sleep(5_000)
        delete_by_name(name, opts, attempts - 1)

      {:error, _} ->
        Process.sleep(5_000)
        delete_by_name(name, opts, attempts - 1)
    end
  end
end
